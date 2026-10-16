package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import ma "vendor:miniaudio"

CHANNELS   :: 2
PEAK_LIMIT :: 0.99 // linear, about -0.09 dBFS

// All tunables, overridable from the command line as -name=value.
Options :: struct {
	// "demucs" (default): run Demucs (neural, needs uv) and repack its stems.
	// "dsp": classical separation in this program, no dependencies.
	engine:        string,
	uvx:           string, // uvx executable; empty = uvx on PATH, then ~/.local/bin/uvx
	demucs_model:  string,
	demucs_device: string,
	// Stage 1 (dsp): long window. Stationary harmonic content (sustained
	// synths, pads) is removed before looking for drums and vocals. Off by
	// default: it also removes steady vocal notes.
	stat:     bool,
	stat_fft: int,
	stat_kt:  int, // median kernel along time (frames)
	stat_kf:  int, // median kernel along frequency (bins)
	stat_lo:  f32, // H/P ratio: below -> not stationary
	stat_hi:  f32, // H/P ratio: above -> fully stationary
	// Stage 2 (dsp): short window. Drums = clearly percussive bins.
	drum_fft: int,
	drum_kt:  int,
	drum_kf:  int,
	drum_lo:  f32, // P/H ratio
	drum_hi:  f32,
	// Stage 3 (dsp): stereo centre mask on the vocal candidate. center < 0 disables.
	center:     f32,
	center_fft: int,
	vlow:       f32,
	vhigh:      f32,
	// Stage 4 (dsp): REPET foreground mask on the vocal candidate.
	repet:     bool,
	repet_k:   int, // loops on each side used for the median
	repet_min: f32, // shortest period in seconds
	repet_max: f32, // longest period in seconds
	// Bass split (dsp).
	bass: f32,
}

default_options :: proc() -> Options {
	return Options {
		engine        = "demucs",
		uvx           = "",
		demucs_model  = "htdemucs",
		demucs_device = "cpu",
		stat          = false,
		stat_fft      = 8192,
		stat_kt       = 17,
		stat_kf       = 17,
		stat_lo       = 1.2,
		stat_hi       = 3.0,
		drum_fft      = 1024,
		drum_kt       = 17,
		drum_kf       = 17,
		drum_lo       = 1.2,
		drum_hi       = 3.0,
		center        = 0.5,
		center_fft    = 2048,
		vlow          = 150,
		vhigh         = 16000,
		repet         = true,
		repet_k       = 10,
		repet_min     = 1.0,
		repet_max     = 8.0,
		bass          = 150,
	}
}

usage :: proc() {
	fmt.eprintln("usage: stems [-name=value ...] <input.(mp3|flac|wav|ogg)> [output_dir]")
	fmt.eprintln("writes drums_bass.wav, vocals.wav, other.wav into output_dir")
	fmt.eprintln("(default output_dir: <input stem>_stems in the current directory)")
	fmt.eprintln("-engine=dsp uses the built-in classical DSP instead of Demucs")
	fmt.eprintln("options and defaults:")
	fmt.eprintfln("  %#v", default_options())
}

main :: proc() {
	opts := default_options()
	positional: [dynamic]string
	for arg in os.args[1:] {
		if len(arg) > 1 && arg[0] == '-' && strings.contains(arg, "=") {
			if !set_option(&opts, arg[1:]) {
				fmt.eprintf("error: unknown or malformed option %s\n", arg)
				os.exit(1)
			}
		} else {
			append(&positional, arg)
		}
	}
	if len(positional) < 1 {
		usage()
		os.exit(1)
	}
	input := positional[0]
	out_dir: string
	if len(positional) >= 2 {
		out_dir = positional[1]
	} else {
		out_dir = fmt.aprintf("%s_stems", os.stem(input))
	}
	if !os.exists(out_dir) {
		if err := os.make_directory_all(out_dir); err != nil {
			fmt.eprintf("error: cannot create %s: %v\n", out_dir, err)
			os.exit(1)
		}
	}

	t0 := time.now()
	stems: Stems
	ok: bool
	switch opts.engine {
	case "dsp":
		stems, ok = separate_dsp(input, &opts)
	case "demucs":
		stems, ok = separate_demucs(input, out_dir, &opts)
	}
	if !ok {
		os.exit(1)
	}
	write_outputs(out_dir, &stems)
	fmt.printf("done in %.1f s\n", time.duration_seconds(time.since(t0)))
}

Stems :: struct {
	sr:                 u32,
	beat_l, beat_r:     []f32, // drums + bass
	vocals_l, vocals_r: []f32,
	other_l, other_r:   []f32,
}

// ---------------------------------------------------------------------------
// Engine "dsp": classical separation.
// ---------------------------------------------------------------------------

separate_dsp :: proc(input: string, opts: ^Options) -> (stems: Stems, ok: bool) {
	fmt.printf("decoding %s\n", input)
	left, right, sr, dok := decode_file(input)
	if !dok {
		fmt.eprintf("error: cannot decode %s\n", input)
		return
	}
	n := len(left)
	fmt.printf("  %d frames, %d Hz, %.1f s\n", n, sr, f64(n) / f64(sr))

	// Stages 1 and 2 per channel.
	fmt.println("left: stationary + drums")
	stat_l, drums_l, cand_l := split_channel(left, opts)
	fmt.println("right: stationary + drums")
	stat_r, drums_r, cand_r := split_channel(right, opts)

	// Stages 3 and 4: vocals = centred, phase-coherent, non-repeating part of
	// the candidate.
	vocals_l, vocals_r: []f32
	if opts.center >= 0 || opts.repet {
		spec_l := stft(cand_l, opts.center_fft)
		spec_r := stft(cand_r, opts.center_fft)
		mask: []f32
		if opts.center >= 0 {
			fmt.println("centre mask")
			mask = center_mask(&spec_l, &spec_r, sr, opts.vlow, opts.vhigh, opts.center)
		}
		if opts.repet {
			fg := repet_foreground(left, right, &spec_l, &spec_r, sr, opts)
			if fg != nil {
				if mask == nil {
					mask = fg
				} else {
					for i in 0 ..< len(mask) {
						mask[i] *= fg[i]
					}
					delete(fg)
				}
			}
		}
		vocals_l = istft(&spec_l, mask)
		vocals_r = istft(&spec_r, mask)
		delete(mask)
		spec_destroy(&spec_l)
		spec_destroy(&spec_r)
	} else {
		vocals_l = cand_l
		vocals_r = cand_r
	}

	// rest = stationary + non-vocal candidate; bass = low band of rest.
	fmt.println("splitting stems")
	fs := f32(sr)
	rest_l := make([]f32, n)
	rest_r := make([]f32, n)
	for i in 0 ..< n {
		rest_l[i] = stat_l[i] + cand_l[i] - vocals_l[i]
		rest_r[i] = stat_r[i] + cand_r[i] - vocals_r[i]
	}
	bass_l := make([]f32, n)
	bass_r := make([]f32, n)
	copy(bass_l, rest_l)
	copy(bass_r, rest_r)
	lowpass_24db(bass_l, opts.bass, fs)
	lowpass_24db(bass_r, opts.bass, fs)

	stems.sr = sr
	stems.beat_l = make([]f32, n)
	stems.beat_r = make([]f32, n)
	stems.other_l = make([]f32, n)
	stems.other_r = make([]f32, n)
	stems.vocals_l = vocals_l
	stems.vocals_r = vocals_r
	for i in 0 ..< n {
		stems.beat_l[i] = drums_l[i] + bass_l[i]
		stems.beat_r[i] = drums_r[i] + bass_r[i]
		stems.other_l[i] = rest_l[i] - bass_l[i]
		stems.other_r[i] = rest_r[i] - bass_r[i]
	}
	ok = true
	return
}

// Stage 1 + 2 for one channel. Returns stationary, drums and the remaining
// candidate; the three sum to x.
split_channel :: proc(x: []f32, opts: ^Options) -> (stationary, drums, cand: []f32) {
	n := len(x)
	work := make([]f32, n)
	copy(work, x)

	stationary = make([]f32, n)
	if opts.stat {
		s1 := stft(work, opts.stat_fft)
		w := hpss_weight(&s1, opts.stat_kt, opts.stat_kf, opts.stat_lo, opts.stat_hi, true)
		delete(stationary)
		stationary = istft(&s1, w)
		delete(w)
		spec_destroy(&s1)
		for i in 0 ..< n {
			work[i] -= stationary[i]
		}
	}

	s2 := stft(work, opts.drum_fft)
	d := hpss_weight(&s2, opts.drum_kt, opts.drum_kf, opts.drum_lo, opts.drum_hi, false)
	drums = istft(&s2, d)
	delete(d)
	spec_destroy(&s2)

	cand = work
	for i in 0 ..< n {
		cand[i] -= drums[i]
	}
	return
}

// REPET foreground weight for the candidate spectra. The loop period comes
// from the full mix, the repeating model from the candidate itself. Returns
// nil when no period is found.
repet_foreground :: proc(left, right: []f32, spec_l, spec_r: ^Spec, sr: u32, opts: ^Options) -> []f32 {
	n := len(left)
	mono := make([]f32, n)
	defer delete(mono)
	for i in 0 ..< n {
		mono[i] = 0.5 * (left[i] + right[i])
	}
	mix := stft(mono, opts.center_fft)
	mix_mag := spec_magnitude(&mix)
	spec_destroy(&mix)

	frames, bins, hop := spec_l.frames, spec_l.bins, spec_l.hop
	fps := f64(sr) / f64(hop)
	lag_min := int(f64(opts.repet_min) * fps)
	lag_max := int(f64(opts.repet_max) * fps)
	max_lag := min(frames / 2, lag_max * 4 + 2)
	if lag_min < 2 || lag_max + 2 > max_lag {
		delete(mix_mag)
		fmt.println("repet: track too short, skipped")
		return nil
	}
	b := beat_spectrum(mix_mag, frames, bins, max_lag)
	delete(mix_mag)
	period := repet_period(b, lag_min, lag_max)
	delete(b)
	if period == 0 {
		fmt.println("repet: no period found, skipped")
		return nil
	}
	fmt.printf("repet: period %.3f s (%.1f frames)\n", period / fps, period)

	// Model from the mean of both channel magnitudes.
	mag_l := spec_magnitude(spec_l)
	mag_r := spec_magnitude(spec_r)
	defer delete(mag_l)
	for i in 0 ..< len(mag_l) {
		mag_l[i] = 0.5 * (mag_l[i] + mag_r[i])
	}
	delete(mag_r)
	weight := repet_background_weight(mag_l, frames, bins, period, opts.repet_k)
	for i in 0 ..< len(weight) {
		weight[i] = 1 - weight[i]
	}
	smooth_along_time(weight, frames, bins)
	return weight
}

// ---------------------------------------------------------------------------
// Engine "demucs": run Demucs through uvx, repack drums+bass / vocals / other.
// ---------------------------------------------------------------------------

separate_demucs :: proc(input, out_dir: string, opts: ^Options) -> (stems: Stems, ok: bool) {
	tmp := strings.concatenate({out_dir, "/.demucs"})
	defer delete(tmp)

	// Candidates for uvx: the explicit option, else uvx on PATH, else the
	// standalone installer location. An asdf shim on PATH fails with exit 126
	// when no python version is set for the directory; fall through on that.
	candidates: [dynamic]string
	defer delete(candidates)
	if opts.uvx != "" {
		append(&candidates, opts.uvx)
	} else {
		append(&candidates, "uvx")
		when ODIN_OS != .Windows {
			if home := os.get_env("HOME", context.temp_allocator); home != "" {
				append(&candidates, strings.concatenate({home, "/.local/bin/uvx"}, context.temp_allocator))
			}
		}
	}

	ran := false
	for uvx in candidates {
		cmd := []string {
			uvx, "--python", "3.12", "--with", "numpy", "--with", "soundfile",
			"demucs", "-n", opts.demucs_model, "-d", opts.demucs_device, "-o", tmp, input,
		}
		fmt.printf("running: %s\n", strings.join(cmd, " ", context.temp_allocator))
		process, serr := os.process_start({command = cmd})
		if serr != nil {
			fmt.printf("  cannot start %s: %v\n", uvx, serr)
			continue
		}
		state, werr := os.process_wait(process)
		if werr == nil && state.success && state.exit_code == 0 {
			ran = true
			break
		}
		if state.exit_code == 126 {
			fmt.printf("  %s is not runnable here (exit 126, asdf shim?), trying next\n", uvx)
			continue
		}
		fmt.eprintf("error: demucs failed (exit code %d)\n", state.exit_code)
		return
	}
	if !ran {
		fmt.eprintln("error: no working uvx found; install uv (https://docs.astral.sh/uv/) or pass -uvx=/path/to/uvx")
		return
	}

	dir := fmt.aprintf("%s/%s/%s", tmp, opts.demucs_model, os.stem(input))
	defer delete(dir)
	drums_l, drums_r, sr, ok1 := decode_file(stem_path(dir, "drums.wav"))
	bass_l, bass_r, _, ok2 := decode_file(stem_path(dir, "bass.wav"))
	vocals_l, vocals_r, _, ok3 := decode_file(stem_path(dir, "vocals.wav"))
	other_l, other_r, _, ok4 := decode_file(stem_path(dir, "other.wav"))
	if !(ok1 && ok2 && ok3 && ok4) {
		fmt.eprintf("error: cannot read demucs output in %s\n", dir)
		return
	}
	n := len(drums_l)
	for i in 0 ..< n {
		drums_l[i] += bass_l[i]
		drums_r[i] += bass_r[i]
	}
	delete(bass_l)
	delete(bass_r)
	_ = os.remove_all(tmp)

	stems = Stems {
		sr       = sr,
		beat_l   = drums_l,
		beat_r   = drums_r,
		vocals_l = vocals_l,
		vocals_r = vocals_r,
		other_l  = other_l,
		other_r  = other_r,
	}
	ok = true
	return
}

stem_path :: proc(dir, name: string) -> string {
	return strings.concatenate({dir, "/", name}, context.temp_allocator)
}

// ---------------------------------------------------------------------------
// Output
// ---------------------------------------------------------------------------

write_outputs :: proc(out_dir: string, s: ^Stems) {
	// One common gain for all stems so nothing clips in 16-bit and the stems
	// still sum to (gain * input). Loud masters decode above 0 dBFS.
	peak: f32 = 0
	for a in ([][]f32{s.beat_l, s.beat_r, s.vocals_l, s.vocals_r, s.other_l, s.other_r}) {
		for v in a {
			peak = max(peak, abs(v))
		}
	}
	gain: f32 = peak > PEAK_LIMIT ? PEAK_LIMIT / peak : 1
	if gain < 1 {
		fmt.printf("  peak %.2f dBFS, applying %.2f dB to all stems\n", db(peak), db(gain))
	}
	write_stem(out_dir, "drums_bass.wav", s.beat_l, s.beat_r, s.sr, gain)
	write_stem(out_dir, "vocals.wav", s.vocals_l, s.vocals_r, s.sr, gain)
	write_stem(out_dir, "other.wav", s.other_l, s.other_r, s.sr, gain)
}

set_option :: proc(opts: ^Options, kv: string) -> bool {
	eq := strings.index_byte(kv, '=')
	key := kv[:eq]
	val := kv[eq + 1:]
	ok: bool
	switch key {
	case "engine":
		opts.engine = val
		ok = val == "dsp" || val == "demucs"
	case "uvx":
		opts.uvx = val
		ok = true
	case "demucs-model":
		opts.demucs_model = val
		ok = len(val) > 0
	case "demucs-device":
		opts.demucs_device = val
		ok = len(val) > 0
	case "stat":       opts.stat, ok = strconv.parse_bool(val)
	case "stat-fft":   opts.stat_fft, ok = strconv.parse_int(val)
	case "stat-kt":    opts.stat_kt, ok = strconv.parse_int(val)
	case "stat-kf":    opts.stat_kf, ok = strconv.parse_int(val)
	case "stat-lo":    opts.stat_lo, ok = strconv.parse_f32(val)
	case "stat-hi":    opts.stat_hi, ok = strconv.parse_f32(val)
	case "drum-fft":   opts.drum_fft, ok = strconv.parse_int(val)
	case "drum-kt":    opts.drum_kt, ok = strconv.parse_int(val)
	case "drum-kf":    opts.drum_kf, ok = strconv.parse_int(val)
	case "drum-lo":    opts.drum_lo, ok = strconv.parse_f32(val)
	case "drum-hi":    opts.drum_hi, ok = strconv.parse_f32(val)
	case "center":     opts.center, ok = strconv.parse_f32(val)
	case "center-fft": opts.center_fft, ok = strconv.parse_int(val)
	case "vlow":       opts.vlow, ok = strconv.parse_f32(val)
	case "vhigh":      opts.vhigh, ok = strconv.parse_f32(val)
	case "repet":      opts.repet, ok = strconv.parse_bool(val)
	case "repet-k":    opts.repet_k, ok = strconv.parse_int(val)
	case "repet-min":  opts.repet_min, ok = strconv.parse_f32(val)
	case "repet-max":  opts.repet_max, ok = strconv.parse_f32(val)
	case "bass":       opts.bass, ok = strconv.parse_f32(val)
	case:              return false
	}
	return ok
}

db :: proc(x: f32) -> f32 {
	return 20 * math.log10(x)
}

write_stem :: proc(dir, name: string, l, r: []f32, sr: u32, gain: f32) {
	path := strings.concatenate({dir, "/", name})
	defer delete(path)
	fmt.printf("  writing %s\n", path)
	if !write_wav(path, l, r, sr, gain) {
		fmt.eprintf("error: cannot write %s\n", path)
		os.exit(1)
	}
}

// Decodes any format miniaudio understands to stereo f32 at the file's native rate.
decode_file :: proc(path: string) -> (left, right: []f32, sample_rate: u32, ok: bool) {
	cpath := strings.clone_to_cstring(path)
	defer delete(cpath)

	cfg := ma.decoder_config_init(.f32, CHANNELS, 0)
	dec: ma.decoder
	if ma.decoder_init_file(cpath, &cfg, &dec) != .SUCCESS {
		return
	}
	defer ma.decoder_uninit(&dec)
	sample_rate = dec.outputSampleRate

	CHUNK :: 4096
	buf: [CHUNK * CHANNELS]f32
	interleaved := make([dynamic]f32)
	defer delete(interleaved)
	for {
		read: u64
		res := ma.decoder_read_pcm_frames(&dec, &buf[0], CHUNK, &read)
		if read > 0 {
			append(&interleaved, ..buf[:int(read) * CHANNELS])
		}
		if res != .SUCCESS || read == 0 {
			break
		}
	}

	n := len(interleaved) / CHANNELS
	if n == 0 {
		return
	}
	left = make([]f32, n)
	right = make([]f32, n)
	for i in 0 ..< n {
		left[i] = interleaved[2 * i]
		right[i] = interleaved[2 * i + 1]
	}
	ok = true
	return
}

write_wav :: proc(path: string, left, right: []f32, sr: u32, gain: f32) -> bool {
	cpath := strings.clone_to_cstring(path)
	defer delete(cpath)

	cfg := ma.encoder_config_init(.wav, .s16, CHANNELS, sr)
	enc: ma.encoder
	if ma.encoder_init_file(cpath, &cfg, &enc) != .SUCCESS {
		return false
	}
	defer ma.encoder_uninit(&enc)

	CHUNK :: 4096
	buf: [CHUNK * CHANNELS]i16
	n := len(left)
	i := 0
	for i < n {
		cnt := min(CHUNK, n - i)
		for j in 0 ..< cnt {
			buf[2 * j] = to_s16(left[i + j] * gain)
			buf[2 * j + 1] = to_s16(right[i + j] * gain)
		}
		written: u64
		if ma.encoder_write_pcm_frames(&enc, &buf[0], u64(cnt), &written) != .SUCCESS {
			return false
		}
		i += cnt
	}
	return true
}

to_s16 :: #force_inline proc(x: f32) -> i16 {
	return i16(clamp(x, -1, 1) * 32767)
}
