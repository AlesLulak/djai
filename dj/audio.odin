package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import rl "vendor:raylib"

SAMPLE_RATE :: 44100
NUM_DECKS   :: 2 // raise to 4 when the layout has room
MAX_LAYERS  :: 3

LAYER_NAMES := [MAX_LAYERS]cstring{"DRUMS+BASS", "VOCALS", "OTHER"}
LAYER_FILES := [MAX_LAYERS]string{"drums_bass.wav", "vocals.wav", "other.wav"}

EQ_LOW_HZ  :: 250.0
EQ_MID_HZ  :: 1200.0
EQ_MID_Q   :: 0.8
EQ_HIGH_HZ :: 6000.0
EQ_MIN_DB  :: -40.0 // knob fully left: practically a kill
EQ_MAX_DB  :: 8.0

// ---------------------------------------------------------------------------
// Biquads (RBJ Audio EQ Cookbook), transposed direct form II.
// ---------------------------------------------------------------------------

Biquad :: struct {
	b0, b1, b2, a1, a2: f32,
	z1, z2:             f32,
}

biquad_tick :: #force_inline proc "contextless" (bq: ^Biquad, x: f32) -> f32 {
	y := bq.b0 * x + bq.z1
	bq.z1 = bq.b1 * x - bq.a1 * y + bq.z2
	bq.z2 = bq.b2 * x - bq.a2 * y
	return y
}

// Replaces coefficients, keeps the filter state.
biquad_set :: proc(bq: ^Biquad, b0, b1, b2, a0, a1, a2: f32) {
	bq.b0 = b0 / a0
	bq.b1 = b1 / a0
	bq.b2 = b2 / a0
	bq.a1 = a1 / a0
	bq.a2 = a2 / a0
}

biquad_lowshelf :: proc(bq: ^Biquad, fc, fs, gain_db: f32) {
	a := math.pow(f32(10), gain_db / 40)
	w0 := 2 * math.PI * fc / fs
	cs := math.cos(w0)
	alpha := math.sin(w0) / 2 * math.sqrt(f32(2))
	sa := 2 * math.sqrt(a) * alpha
	biquad_set(bq,
		a * ((a + 1) - (a - 1) * cs + sa),
		2 * a * ((a - 1) - (a + 1) * cs),
		a * ((a + 1) - (a - 1) * cs - sa),
		(a + 1) + (a - 1) * cs + sa,
		-2 * ((a - 1) + (a + 1) * cs),
		(a + 1) + (a - 1) * cs - sa)
}

biquad_highshelf :: proc(bq: ^Biquad, fc, fs, gain_db: f32) {
	a := math.pow(f32(10), gain_db / 40)
	w0 := 2 * math.PI * fc / fs
	cs := math.cos(w0)
	alpha := math.sin(w0) / 2 * math.sqrt(f32(2))
	sa := 2 * math.sqrt(a) * alpha
	biquad_set(bq,
		a * ((a + 1) + (a - 1) * cs + sa),
		-2 * a * ((a - 1) + (a + 1) * cs),
		a * ((a + 1) + (a - 1) * cs - sa),
		(a + 1) - (a - 1) * cs + sa,
		2 * ((a - 1) - (a + 1) * cs),
		(a + 1) - (a - 1) * cs - sa)
}

biquad_peak :: proc(bq: ^Biquad, fc, fs, q, gain_db: f32) {
	a := math.pow(f32(10), gain_db / 40)
	w0 := 2 * math.PI * fc / fs
	cs := math.cos(w0)
	alpha := math.sin(w0) / (2 * q)
	biquad_set(bq,
		1 + alpha * a,
		-2 * cs,
		1 - alpha * a,
		1 + alpha / a,
		-2 * cs,
		1 - alpha / a)
}

biquad_lowpass :: proc(bq: ^Biquad, fc, fs: f32) {
	w0 := 2 * math.PI * fc / fs
	cs := math.cos(w0)
	alpha := math.sin(w0) / 2 * math.sqrt(f32(2))
	biquad_set(bq, (1 - cs) / 2, 1 - cs, (1 - cs) / 2, 1 + alpha, -2 * cs, 1 - alpha)
}

biquad_highpass :: proc(bq: ^Biquad, fc, fs: f32) {
	w0 := 2 * math.PI * fc / fs
	cs := math.cos(w0)
	alpha := math.sin(w0) / 2 * math.sqrt(f32(2))
	biquad_set(bq, (1 + cs) / 2, -(1 + cs), (1 + cs) / 2, 1 + alpha, -2 * cs, 1 - alpha)
}

// ---------------------------------------------------------------------------
// Decks and the mixer.
// ---------------------------------------------------------------------------

Wave_Pixel :: struct {
	low, mid, high: f32, // 0..1: bass / other / vocals, or frequency bands
	beat:           f32, // 0..1: drum hits (stem above 150 Hz, or low-band transients)
}

Deck :: struct {
	index:       int, // position in engine.decks
	sync_on:     bool, // follow the other deck: tempo always, beat phase on play
	path:        string,
	title:       cstring,
	has_stems:   bool,
	layers:      [MAX_LAYERS][]f32, // interleaved stereo at SAMPLE_RATE
	layer_count: int,
	frames:      int,
	// transport (audio thread owns pos while playing)
	pos:     f64,
	playing: bool,
	rate:    f32, // 1 = original speed
	cue:     f64,
	// mixer parameters (UI writes, audio reads)
	volume:    f32,
	// keyboard volume glide: volume moves from vol_from to vol_target over
	// vol_len seconds starting at vol_t0; vol_len 0 = no glide running
	vol_target: f32,
	vol_from:   f32,
	vol_t0:     f64,
	vol_len:    f64,
	trim_db:   f32, // gain knob, -12 .. +12 dB
	trim_gain: f32, // linear, derived from trim_db
	loudness_db: f32, // 90th percentile of per-second RMS, dBFS; LOUDNESS_UNKNOWN until loaded
	stem_gain: [MAX_LAYERS]f32,
	eq_knob:   [3]f32, // 0..1, 0.5 = flat
	eq:        [2][3]Biquad, // [channel][band]
	hot_cues:  [4]f64, // < 0 = unset
	// analysis (UI reads)
	overview:    []Wave_Pixel, // OVERVIEW_COLUMNS over the whole track
	fine:        []Wave_Pixel, // one per FINE_HOP frames, for the scrolling view
	bpm:         f32, // 0 = unknown
	beat_offset: f32, // seconds of the first beat
	bpm_detected:    f32, // analysis result, restored by a grid reset
	offset_detected: f32,
	grid_manual:     bool, // bpm / beat_offset set by hand, kept in the sidecar
}

Engine :: struct {
	decks:      [NUM_DECKS]Deck,
	crossfader: f32, // 0 = deck A only, 1 = deck B only
	master:     f32,
	mutex:      sync.Mutex,
	stream:     rl.AudioStream,
}

engine: ^Engine

engine_init :: proc() {
	engine = new(Engine)
	engine.crossfader = 0.5
	engine.master = 1
	for &d, i in engine.decks {
		d.index = i
		d.rate = 1
		d.volume = 1
		d.trim_gain = 1
		d.loudness_db = LOUDNESS_UNKNOWN
		d.stem_gain = {1, 1, 1}
		d.eq_knob = {0.5, 0.5, 0.5}
		d.hot_cues = {-1, -1, -1, -1}
		for band in 0 ..< 3 {
			deck_update_eq(&d, band)
		}
	}
	rl.InitAudioDevice()
	rl.SetAudioStreamBufferSizeDefault(1024)
	engine.stream = rl.LoadAudioStream(SAMPLE_RATE, 32, 2)
	rl.SetAudioStreamCallback(engine.stream, audio_callback)
	rl.PlayAudioStream(engine.stream)
}

engine_shutdown :: proc() {
	rl.StopAudioStream(engine.stream)
	rl.UnloadAudioStream(engine.stream)
	rl.CloseAudioDevice()
}

knob_to_db :: proc(v: f32) -> f32 {
	if v < 0.5 {
		return EQ_MIN_DB * (0.5 - v) / 0.5
	}
	return EQ_MAX_DB * (v - 0.5) / 0.5
}

deck_update_eq :: proc(d: ^Deck, band: int) {
	db := knob_to_db(d.eq_knob[band])
	for ch in 0 ..< 2 {
		switch band {
		case 0: biquad_lowshelf(&d.eq[ch][0], EQ_LOW_HZ, SAMPLE_RATE, db)
		case 1: biquad_peak(&d.eq[ch][1], EQ_MID_HZ, SAMPLE_RATE, EQ_MID_Q, db)
		case 2: biquad_highshelf(&d.eq[ch][2], EQ_HIGH_HZ, SAMPLE_RATE, db)
		}
	}
}

crossfader_gain :: proc(deck_index: int, x: f32) -> f32 {
	switch deck_index {
	case 0: return math.cos(x * math.PI / 2)
	case 1: return math.sin(x * math.PI / 2)
	}
	return 1
}

audio_callback :: proc "c" (buffer: rawptr, frames: c.uint) {
	context = runtime.default_context()
	out := ([^]f32)(buffer)
	e := engine
	sync.mutex_lock(&e.mutex)
	defer sync.mutex_unlock(&e.mutex)

	#no_bounds_check for f in 0 ..< int(frames) {
		l, r: f32
		for &d, di in e.decks {
			if !d.playing || d.frames < 2 {
				continue
			}
			i := int(d.pos)
			if i + 1 >= d.frames {
				d.playing = false
				d.pos = f64(d.frames - 1)
				continue
			}
			frac := f32(d.pos - f64(i))
			sl, sr: f32
			for k in 0 ..< d.layer_count {
				g: f32 = d.has_stems ? d.stem_gain[k] : 1
				if g == 0 {
					continue
				}
				s := d.layers[k]
				sl += g * (s[2 * i] * (1 - frac) + s[2 * i + 2] * frac)
				sr += g * (s[2 * i + 1] * (1 - frac) + s[2 * i + 3] * frac)
			}
			for b in 0 ..< 3 {
				sl = biquad_tick(&d.eq[0][b], sl)
				sr = biquad_tick(&d.eq[1][b], sr)
			}
			g := d.volume * d.trim_gain * crossfader_gain(di, e.crossfader)
			l += sl * g
			r += sr * g
			d.pos += f64(d.rate)
		}
		out[2 * f] = clamp(l * e.master, -1, 1)
		out[2 * f + 1] = clamp(r * e.master, -1, 1)
	}
}

// ---------------------------------------------------------------------------
// Transport, called from the UI thread.
// ---------------------------------------------------------------------------

deck_toggle_play :: proc(d: ^Deck) {
	if d.frames == 0 {
		return
	}
	sync.mutex_lock(&engine.mutex)
	defer sync.mutex_unlock(&engine.mutex)
	if d.playing {
		d.playing = false
	} else {
		if int(d.pos) + 1 >= d.frames {
			d.pos = d.cue
		}
		// Sync on: start in time with the other deck when it is playing.
		if d.sync_on {
			other := &engine.decks[(d.index + 1) % NUM_DECKS]
			if other.playing {
				if rate, ok := sync_rate(d, other); ok {
					deck_sync_locked(d, other, rate)
				}
			}
		}
		d.playing = true
	}
}

// Playing: jump back to the cue point and stop. Stopped: set the cue point here.
deck_cue :: proc(d: ^Deck) {
	if d.frames == 0 {
		return
	}
	sync.mutex_lock(&engine.mutex)
	defer sync.mutex_unlock(&engine.mutex)
	if d.playing {
		d.playing = false
		d.pos = d.cue
	} else {
		d.cue = d.pos
		deck_save_cues(d)
	}
}

// Empty pad: set the hot cue here. Set pad: jump there, keep play state.
deck_hot_cue :: proc(d: ^Deck, i: int) {
	if d.frames == 0 {
		return
	}
	sync.mutex_lock(&engine.mutex)
	defer sync.mutex_unlock(&engine.mutex)
	if d.hot_cues[i] < 0 {
		d.hot_cues[i] = d.pos
		deck_save_cues(d)
	} else {
		d.pos = d.hot_cues[i]
	}
}

deck_clear_hot_cue :: proc(d: ^Deck, i: int) {
	d.hot_cues[i] = -1
	deck_save_cues(d)
}

deck_seek :: proc(d: ^Deck, fraction: f32) {
	if d.frames == 0 {
		return
	}
	sync.mutex_lock(&engine.mutex)
	defer sync.mutex_unlock(&engine.mutex)
	d.pos = clamp(f64(fraction), 0, 1) * f64(d.frames - 1)
}

deck_position :: proc(d: ^Deck) -> (fraction: f32, seconds: f32) {
	if d.frames == 0 {
		return 0, 0
	}
	p := d.pos
	return f32(p / f64(d.frames)), f32(p / SAMPLE_RATE)
}

deck_length_seconds :: proc(d: ^Deck) -> f32 {
	return f32(d.frames) / SAMPLE_RATE
}

// ---------------------------------------------------------------------------
// Loading.
// ---------------------------------------------------------------------------

// Decodes any format raylib understands (WAV, MP3, OGG, FLAC) to interleaved
// stereo f32 at SAMPLE_RATE.
decode_audio :: proc(path: string) -> (samples: []f32, frames: int, ok: bool) {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	wave := rl.LoadWave(cpath)
	if wave.data == nil || wave.frameCount == 0 {
		return
	}
	defer rl.UnloadWave(wave)
	rl.WaveFormat(&wave, SAMPLE_RATE, 32, 2)
	frames = int(wave.frameCount)
	samples = make([]f32, frames * 2)
	copy(samples, ([^]f32)(wave.data)[:frames * 2])
	ok = true
	return
}

stems_dir_for :: proc(path: string, allocator := context.allocator) -> string {
	dir := os.dir(path)
	stem := os.stem(path)
	if dir == "" || dir == "." {
		return strings.concatenate({stem, "_stems"}, allocator)
	}
	return strings.concatenate({dir, "/", stem, "_stems"}, allocator)
}

has_stems_for :: proc(path: string) -> bool {
	dir := stems_dir_for(path, context.temp_allocator)
	for f in LAYER_FILES {
		p := strings.concatenate({dir, "/", f}, context.temp_allocator)
		if !os.exists(p) {
			return false
		}
	}
	return true
}

// Loads the track (its stems when present) into the deck. Decoding happens
// outside the audio lock; only the swap is locked.
// Everything a deck needs for a track, produced without touching the deck so
// it can run on a worker thread.
Loaded_Track :: struct {
	layers:      [MAX_LAYERS][]f32,
	count:       int,
	frames:      int,
	with_stems:  bool,
	fine:        []Wave_Pixel,
	overview:    []Wave_Pixel,
	bpm:         f32,
	beat_offset: f32,
	loudness:    f32,
}

load_track :: proc(path: string) -> (lt: Loaded_Track, ok: bool) {
	layers: [MAX_LAYERS][]f32
	count := 0
	frames := 0
	with_stems := has_stems_for(path)
	if with_stems {
		dir := stems_dir_for(path, context.temp_allocator)
		for f, k in LAYER_FILES {
			p := strings.concatenate({dir, "/", f}, context.temp_allocator)
			s, n, dok := decode_audio(p)
			if !dok {
				for j in 0 ..< k {
					delete(layers[j])
				}
				return
			}
			layers[k] = s
			frames = k == 0 ? n : min(frames, n)
			count += 1
		}
	} else {
		s, n, dok := decode_audio(path)
		if !dok {
			return
		}
		layers[0] = s
		frames = n
		count = 1
	}
	lt = Loaded_Track {
		layers     = layers,
		count      = count,
		frames     = frames,
		with_stems = with_stems,
	}
	lt.fine = build_fine(layers, count, frames, with_stems)
	lt.overview = pool_overview(lt.fine, OVERVIEW_COLUMNS)
	lt.bpm, lt.beat_offset = detect_beats(layers, count, frames)
	lt.loudness = measure_loudness(layers, count, frames)
	ok = true
	return
}

// Puts a loaded track into the deck. Only the swap holds the audio lock.
deck_install :: proc(d: ^Deck, path: string, lt: Loaded_Track) {
	sync.mutex_lock(&engine.mutex)
	for k in 0 ..< d.layer_count {
		delete(d.layers[k])
	}
	delete(d.overview)
	delete(d.fine)
	delete(d.path)
	if d.title != nil {
		delete(d.title)
	}
	d.path = strings.clone(path)
	d.title = strings.clone_to_cstring(os.base(path))
	d.has_stems = lt.with_stems
	d.layers = lt.layers
	d.layer_count = lt.count
	d.frames = lt.frames
	d.overview = lt.overview
	d.fine = lt.fine
	d.bpm = lt.bpm
	d.beat_offset = lt.beat_offset
	d.bpm_detected = lt.bpm
	d.offset_detected = lt.beat_offset
	d.grid_manual = false
	d.loudness_db = lt.loudness
	d.pos = 0
	d.cue = 0
	d.hot_cues = {-1, -1, -1, -1}
	d.playing = false
	for ch in 0 ..< 2 {
		for b in 0 ..< 3 {
			d.eq[ch][b].z1 = 0
			d.eq[ch][b].z2 = 0
		}
	}
	deck_load_cues(d)
	sync.mutex_unlock(&engine.mutex)
}

// Synchronous load, used by the debug flags.
deck_load :: proc(d: ^Deck, path: string) -> bool {
	lt, ok := load_track(path)
	if !ok {
		return false
	}
	deck_install(d, path, lt)
	return true
}

// ---------------------------------------------------------------------------
// Background loading: decode and analysis on a worker thread, the swap on the
// main thread. One load per deck at a time.
// ---------------------------------------------------------------------------

Load_Job :: struct {
	deck:   ^Deck,
	path:   string,
	thread: ^thread.Thread,
	result: Loaded_Track,
	ok:     bool,
	done:   bool, // written by the worker last, read by the main thread
}

load_jobs: [dynamic]^Load_Job

deck_is_loading :: proc(d: ^Deck) -> bool {
	for j in load_jobs {
		if j.deck == d {
			return true
		}
	}
	return false
}

deck_load_async :: proc(d: ^Deck, path: string) -> bool {
	if deck_is_loading(d) {
		return false
	}
	job := new(Load_Job)
	job.deck = d
	job.path = strings.clone(path)
	job.thread = thread.create_and_start_with_poly_data(job, proc(job: ^Load_Job) {
		job.result, job.ok = load_track(job.path)
		free_all(context.temp_allocator)
		sync.atomic_store(&job.done, true)
	})
	append(&load_jobs, job)
	return true
}

// Installs finished loads. Returns the deck and outcome of one finished job
// per call so the caller can report it; deck is nil when nothing finished.
poll_load_jobs :: proc() -> (d: ^Deck, path: string, ok: bool) {
	for job, i in load_jobs {
		if !sync.atomic_load(&job.done) {
			continue
		}
		thread.join(job.thread)
		thread.destroy(job.thread)
		if job.ok {
			deck_install(job.deck, job.path, job.result)
		}
		d, ok = job.deck, job.ok
		path = strings.clone(job.path, context.temp_allocator)
		delete(job.path)
		free(job)
		ordered_remove(&load_jobs, i)
		return
	}
	return nil, "", false
}

OVERVIEW_COLUMNS :: 640
FINE_HOP         :: 256 // frames per fine bin, 5.8 ms at 44.1 kHz

// One Wave_Pixel per FINE_HOP frames. With stems: low = drums+bass,
// mid = other, high = vocals (RMS of each stem). Without: three frequency
// bands of the mix. Everything normalised to the loudest low value so the
// layers keep their real proportions.
build_fine :: proc(layers: [MAX_LAYERS][]f32, count, frames: int, with_stems: bool) -> []Wave_Pixel {
	bins := (frames + FINE_HOP - 1) / FINE_HOP
	px := make([]Wave_Pixel, bins)
	if frames == 0 {
		return px
	}
	lo, hp, hi, mid_lp, drum_hp: Biquad
	biquad_lowpass(&lo, EQ_LOW_HZ, SAMPLE_RATE)
	biquad_highpass(&hp, EQ_LOW_HZ, SAMPLE_RATE)
	biquad_highpass(&hi, EQ_HIGH_HZ, SAMPLE_RATE)
	biquad_lowpass(&mid_lp, EQ_HIGH_HZ, SAMPLE_RATE)
	biquad_highpass(&drum_hp, 150, SAMPLE_RATE)

	acc: [4]f64
	n_acc := 0
	b := 0
	#no_bounds_check for i in 0 ..< frames {
		if with_stems && count == MAX_LAYERS {
			for k in 0 ..< MAX_LAYERS {
				v := 0.5 * (layers[k][2 * i] + layers[k][2 * i + 1])
				acc[k] += f64(v * v)
				if k == 0 {
					d := biquad_tick(&drum_hp, v)
					acc[3] += f64(d * d)
				}
			}
		} else {
			m: f32
			for k in 0 ..< count {
				m += 0.5 * (layers[k][2 * i] + layers[k][2 * i + 1])
			}
			l := biquad_tick(&lo, m)
			rest := biquad_tick(&hp, m)
			h := biquad_tick(&hi, rest)
			md := biquad_tick(&mid_lp, rest)
			acc[0] += f64(l * l)
			acc[1] += f64(md * md)
			acc[2] += f64(h * h)
		}
		n_acc += 1
		if n_acc == FINE_HOP || i == frames - 1 {
			inv := 1 / f64(n_acc)
			px[b] = {
				low  = f32(math.sqrt(acc[0] * inv)),
				mid  = f32(math.sqrt(acc[1] * inv)),
				high = f32(math.sqrt(acc[2] * inv)),
				beat = f32(math.sqrt(acc[3] * inv)),
			}
			acc = {0, 0, 0, 0}
			n_acc = 0
			b += 1
		}
	}
	// Without stems the drum hits are transients: positive change of the low
	// band plus half of the mid band, bin to bin.
	if !(with_stems && count == MAX_LAYERS) {
		for j in 1 ..< bins {
			px[j].beat = max(px[j].low - px[j - 1].low, 0) + 0.5 * max(px[j].mid - px[j - 1].mid, 0)
		}
	}
	peak: f32 = 1e-9
	beat_peak: f32 = 1e-9
	for p in px {
		peak = max(peak, p.low, p.mid, p.high)
		beat_peak = max(beat_peak, p.beat)
	}
	for &p in px {
		p.low = min(p.low / peak, 1)
		p.mid = min(p.mid / peak, 1)
		p.high = min(p.high / peak, 1)
		p.beat = min(p.beat / beat_peak, 1)
	}
	return px
}

// Max-pools the fine bins into `columns` for the whole-track overview.
pool_overview :: proc(fine: []Wave_Pixel, columns: int) -> []Wave_Pixel {
	px := make([]Wave_Pixel, columns)
	if len(fine) == 0 {
		return px
	}
	for c in 0 ..< columns {
		b0 := c * len(fine) / columns
		b1 := max((c + 1) * len(fine) / columns, b0 + 1)
		acc: Wave_Pixel
		for b in b0 ..< min(b1, len(fine)) {
			acc.low = max(acc.low, fine[b].low)
			acc.mid = max(acc.mid, fine[b].mid)
			acc.high = max(acc.high, fine[b].high)
			acc.beat = max(acc.beat, fine[b].beat)
		}
		px[c] = acc
	}
	return px
}

// ---------------------------------------------------------------------------
// Beat grid. Electronic music has a constant tempo, so one BPM and one offset
// describe the grid. Onset envelope from log-energy flux in two bands,
// autocorrelation for the coarse period, then a comb search refines period
// and phase to a fraction of a frame.
// ---------------------------------------------------------------------------

BEAT_HOP :: 256

debug_beats := false
BPM_MIN  :: 70.0
BPM_MAX  :: 200.0

detect_beats :: proc(layers: [MAX_LAYERS][]f32, count, frames: int) -> (bpm, offset_seconds: f32) {
	if frames < SAMPLE_RATE * 10 {
		return 0, 0
	}
	fps := f64(SAMPLE_RATE) / BEAT_HOP
	n := frames / BEAT_HOP
	e_low := make([]f32, n)
	e_mid := make([]f32, n)
	defer delete(e_low)
	defer delete(e_mid)
	lo, hp, lp: Biquad
	biquad_lowpass(&lo, 150, SAMPLE_RATE)
	biquad_highpass(&hp, 150, SAMPLE_RATE)
	biquad_lowpass(&lp, 4000, SAMPLE_RATE)
	#no_bounds_check for t in 0 ..< n {
		al, am: f32
		for j in 0 ..< BEAT_HOP {
			i := t * BEAT_HOP + j
			m: f32
			for k in 0 ..< count {
				m += 0.5 * (layers[k][2 * i] + layers[k][2 * i + 1])
			}
			l := biquad_tick(&lo, m)
			md := biquad_tick(&lp, biquad_tick(&hp, m))
			al += l * l
			am += md * md
		}
		e_low[t] = math.ln(al / BEAT_HOP + 1e-7)
		e_mid[t] = math.ln(am / BEAT_HOP + 1e-7)
	}

	// Onset envelope: positive log-energy flux, low band weighted double.
	onset := make([]f32, n)
	defer delete(onset)
	for t in 1 ..< n {
		onset[t] = 2 * max(e_low[t] - e_low[t - 1], 0) + max(e_mid[t] - e_mid[t - 1], 0)
	}

	// Coarse candidates: local maxima of the autocorrelation in the lag range,
	// plus their halves and doubles. The 3:2 and 2:1 confusions of plain
	// autocorrelation are sorted out by the comb score below.
	lag_min := int(60 / BPM_MAX * fps)
	lag_max := int(60 / BPM_MIN * fps)
	ac := make([]f64, lag_max + 2)
	defer delete(ac)
	for lag in lag_min ..= lag_max {
		s: f64
		for t in 0 ..< n - lag {
			s += f64(onset[t] * onset[t + lag])
		}
		ac[lag] = s / f64(n - lag)
	}
	Candidate :: struct {
		lag:   int,
		ac:    f64,
	}
	cands: [dynamic]Candidate
	defer delete(cands)
	for lag in lag_min + 1 ..< lag_max {
		if ac[lag] >= ac[lag - 1] && ac[lag] >= ac[lag + 1] {
			append(&cands, Candidate{lag, ac[lag]})
		}
	}
	if len(cands) == 0 {
		return 0, 0
	}
	slice.sort_by(cands[:], proc(a, b: Candidate) -> bool {return a.ac > b.ac})
	top := min(len(cands), 5)
	lags: [dynamic]int
	defer delete(lags)
	for c in cands[:top] {
		for l in ([]int{c.lag, c.lag / 2, c.lag * 2}) {
			if l >= lag_min && l <= lag_max && !slice.contains(lags[:], l) {
				append(&lags, l)
			}
		}
	}

	// Fine period and phase per candidate: comb of beats, score = mean onset
	// strength at the beat positions. Doubled tempo lands half its beats on
	// weak off-beats, 3:2 tempo lands half of them between beats, so the
	// true tempo scores highest; half tempo can tie, hence the range
	// preference at the end.
	best_p := 0.0
	best_phase := 0.0
	best_score := -1.0
	in_p, in_phase := 0.0, 0.0
	in_score := -1.0
	for lag in lags {
		c_p, c_phase, c_score := f64(lag), 0.0, -1.0
		for dp := -1.0; dp <= 1.0; dp += 0.01 {
			p := f64(lag) + dp
			for phase := 0.0; phase < p; phase += 0.5 {
				s: f64
				hits := 0
				for x := phase; x < f64(n) - 1; x += p {
					s += f64(onset[int(x + 0.5)])
					hits += 1
				}
				if hits > 0 && s / f64(hits) > c_score {
					c_score = s / f64(hits)
					c_p = p
					c_phase = phase
				}
			}
		}
		if debug_beats {
			fmt.printf("  candidate lag %3d  bpm %7.2f  ac %.4f  comb %.4f\n", lag, 60 * fps / c_p, ac[lag], c_score)
		}
		if c_score > best_score {
			best_score, best_p, best_phase = c_score, c_p, c_phase
		}
		b := 60 * fps / c_p
		if b >= 110 && b <= 190 && c_score > in_score {
			in_score, in_p, in_phase = c_score, c_p, c_phase
		}
	}
	if in_score > 0.75 * best_score {
		best_p, best_phase = in_p, in_phase
	}
	return f32(60 * fps / best_p), f32(best_phase / fps)
}

// Beat phase of the deck at its current position, 0..1 (fraction of a beat).
deck_beat_phase :: proc(d: ^Deck) -> f64 {
	if d.bpm <= 0 {
		return 0
	}
	period := 60 / f64(d.bpm)
	t := d.pos / SAMPLE_RATE - f64(d.beat_offset)
	return t / period - math.floor(t / period)
}

TEMPO_RANGE :: 0.08 // tempo fader: -8 % .. +8 %

// Playback rate that brings d to the tempo of master. BPM detection can land
// on a half, double or 3:2 tempo, so the tempo multiple closest to the fader
// centre is used. ok is false when even that is outside the fader range.
sync_rate :: proc(d, master: ^Deck) -> (rate: f32, ok: bool) {
	if d.bpm <= 0 || master.bpm <= 0 || d.frames == 0 {
		return 1, false
	}
	ratio := f64(master.bpm * master.rate / d.bpm)
	best := ratio
	for m in ([]f64{0.5, 2, 2.0 / 3, 1.5, 0.75, 4.0 / 3, 0.25, 4}) {
		c := ratio * m
		if abs(c - 1) < abs(best - 1) {
			best = c
		}
	}
	if abs(best - 1) > TEMPO_RANGE {
		return 1, false
	}
	return f32(best), true
}

// Matches tempo and beat phase of d to master. Returns false, changing
// nothing, when the tempo is out of range.
deck_sync :: proc(d, master: ^Deck) -> bool {
	rate, ok := sync_rate(d, master)
	if !ok {
		return false
	}
	sync.mutex_lock(&engine.mutex)
	defer sync.mutex_unlock(&engine.mutex)
	deck_sync_locked(d, master, rate)
	return true
}

// Caller holds the engine mutex.
deck_sync_locked :: proc(d, master: ^Deck, rate: f32) {
	d.rate = rate
	diff := deck_beat_phase(master) - deck_beat_phase(d)
	if diff > 0.5 {
		diff -= 1
	} else if diff < -0.5 {
		diff += 1
	}
	shift := diff * 60 / f64(d.bpm) * SAMPLE_RATE
	d.pos = clamp(d.pos + shift, 0, f64(d.frames - 1))
}

// Sync on: keep the tempo locked to the other deck while it plays. Phase is
// only corrected when playback starts, so the music never jumps mid-play.
deck_follow_tempo :: proc(d: ^Deck) {
	if !d.sync_on {
		return
	}
	other := &engine.decks[(d.index + 1) % NUM_DECKS]
	if !other.playing || other.sync_on && !d.playing {
		return
	}
	if rate, ok := sync_rate(d, other); ok {
		d.rate = rate
	}
}

// Manual correction when detection picked the wrong tempo multiple.
deck_scale_bpm :: proc(d: ^Deck, factor: f32) {
	if d.bpm > 0 {
		d.bpm *= factor
		d.grid_manual = true
		deck_save_cues(d)
	}
}

// SET GRID: the current position becomes beat 1 of a bar, tempo unchanged.
deck_set_grid :: proc(d: ^Deck) {
	if d.frames == 0 || d.bpm <= 0 {
		return
	}
	d.beat_offset = f32(d.pos / SAMPLE_RATE)
	d.grid_manual = true
	deck_save_cues(d)
}

// Back to the detected tempo and grid.
deck_reset_grid :: proc(d: ^Deck) {
	if d.frames == 0 {
		return
	}
	d.bpm = d.bpm_detected
	d.beat_offset = d.offset_detected
	d.grid_manual = false
	deck_save_cues(d)
}

deck_seek_seconds :: proc(d: ^Deck, seconds: f32) {
	if d.frames == 0 {
		return
	}
	sync.mutex_lock(&engine.mutex)
	defer sync.mutex_unlock(&engine.mutex)
	d.pos = clamp(f64(seconds) * SAMPLE_RATE, 0, f64(d.frames - 1))
}

BAR_BEATS       :: 4
SKIP_FALLBACK_S :: 2.0 // bar length assumed when the BPM is unknown
VOLUME_STEP     :: 0.1 // fader change per key press

// Length of one bar in seconds at the current playback tempo.
deck_bar_seconds :: proc(d: ^Deck) -> f64 {
	if d.bpm <= 0 {
		return SKIP_FALLBACK_S
	}
	return BAR_BEATS * 60 / f64(d.bpm * d.rate)
}

// Jumps by whole bars of the track, so the beat phase is kept and a synced
// deck stays in time.
deck_skip_bars :: proc(d: ^Deck, bars: int) {
	if d.frames == 0 {
		return
	}
	step := f64(bars) * SKIP_FALLBACK_S * SAMPLE_RATE
	if d.bpm > 0 {
		step = f64(bars) * BAR_BEATS * 60 / f64(d.bpm) * SAMPLE_RATE
	}
	sync.mutex_lock(&engine.mutex)
	defer sync.mutex_unlock(&engine.mutex)
	d.pos = clamp(d.pos + step, 0, f64(d.frames - 1))
}

// Moves the fader target by step. The fader then glides there over one bar,
// counted from this press: a further press restarts the glide from the
// current level to the new target.
deck_volume_step :: proc(d: ^Deck, step: f32) {
	target := d.vol_len > 0 ? d.vol_target : d.volume
	d.vol_target = clamp(target + step, 0, 1)
	d.vol_from = d.volume
	d.vol_t0 = rl.GetTime()
	d.vol_len = deck_bar_seconds(d)
}

// Once per frame on the UI thread: advances a running volume glide.
deck_volume_tick :: proc(d: ^Deck) {
	if d.vol_len <= 0 {
		return
	}
	t := (rl.GetTime() - d.vol_t0) / d.vol_len
	if t >= 1 {
		d.volume = d.vol_target
		d.vol_len = 0
	} else {
		d.volume = d.vol_from + (d.vol_target - d.vol_from) * f32(t)
	}
}

// Stops a volume glide, for example when the fader is dragged.
deck_volume_hold :: proc(d: ^Deck) {
	d.vol_len = 0
}

// Volume toggle: any level drops to 0 at once, 0 jumps to full. A running
// glide is dropped too, so a double press always ends at full.
deck_volume_toggle :: proc(d: ^Deck) {
	d.vol_len = 0
	d.volume = d.volume > 0 ? 0 : 1
}

any_deck_playing :: proc() -> bool {
	for &d in engine.decks {
		if d.playing {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// Cue persistence: "<track>.cues" next to the track, one "key value" per
// line, positions in frames at SAMPLE_RATE. A hand-set beat grid is kept
// as "bpm" and "grid" (first beat in frames); without them the detected
// grid is used.
// ---------------------------------------------------------------------------

cues_path :: proc(d: ^Deck) -> string {
	return strings.concatenate({d.path, ".cues"}, context.temp_allocator)
}

deck_save_cues :: proc(d: ^Deck) {
	if d.path == "" {
		return
	}
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, "cue %.0f\n", d.cue)
	for hc, i in d.hot_cues {
		if hc >= 0 {
			fmt.sbprintf(&sb, "hot%d %.0f\n", i, hc)
		}
	}
	if d.grid_manual {
		fmt.sbprintf(&sb, "bpm %.3f\ngrid %.0f\n", d.bpm, f64(d.beat_offset) * SAMPLE_RATE)
	}
	if err := os.write_entire_file(cues_path(d), strings.to_string(sb)); err != nil {
		fmt.eprintf("cannot save cues for %s: %v\n", d.path, err)
	}
}

deck_load_cues :: proc(d: ^Deck) {
	data, err := os.read_entire_file(cues_path(d), context.temp_allocator)
	if err != nil {
		return
	}
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		key, _, value := strings.partition(line, " ")
		v, ok := strconv.parse_f64(strings.trim_space(value))
		if !ok {
			continue
		}
		frames := clamp(v, 0, f64(max(d.frames - 1, 0)))
		switch key {
		case "cue":
			d.cue = frames
		case "hot0", "hot1", "hot2", "hot3":
			d.hot_cues[int(key[3] - '0')] = frames
		case "bpm":
			if v > 0 {
				d.bpm = f32(v)
				d.grid_manual = true
			}
		case "grid":
			d.beat_offset = f32(frames / SAMPLE_RATE)
			d.grid_manual = true
		}
	}
}

// ---------------------------------------------------------------------------
// Loudness and gain matching.
// ---------------------------------------------------------------------------

LOUDNESS_UNKNOWN :: -200.0
TRIM_RANGE_DB    :: 12.0

// Loudness of the loud parts: 90th percentile of the per-second RMS of the
// mix, in dBFS. Breakdowns and intros do not pull it down, so two tracks
// matched on it sit at the same level in their drops.
measure_loudness :: proc(layers: [MAX_LAYERS][]f32, count, frames: int) -> f32 {
	blocks := frames / SAMPLE_RATE
	if blocks < 1 {
		return LOUDNESS_UNKNOWN
	}
	rms := make([]f32, blocks, context.temp_allocator)
	#no_bounds_check for b in 0 ..< blocks {
		acc: f64
		for i in b * SAMPLE_RATE ..< (b + 1) * SAMPLE_RATE {
			m: f32
			for k in 0 ..< count {
				m += 0.5 * (layers[k][2 * i] + layers[k][2 * i + 1])
			}
			acc += f64(m * m)
		}
		rms[b] = f32(math.sqrt(acc / SAMPLE_RATE))
	}
	slice.sort(rms)
	v := rms[min(int(f32(blocks) * 0.9), blocks - 1)]
	if v <= 1e-6 {
		return LOUDNESS_UNKNOWN
	}
	return 20 * math.log10(v)
}

deck_set_trim :: proc(d: ^Deck, db: f32) {
	d.trim_db = clamp(db, -TRIM_RANGE_DB, TRIM_RANGE_DB)
	d.trim_gain = math.pow(f32(10), d.trim_db / 20)
}

// Sets the trim of d so that its loud parts play as loud as master's.
deck_match_volume :: proc(d, master: ^Deck) -> bool {
	if d.loudness_db <= LOUDNESS_UNKNOWN || master.loudness_db <= LOUDNESS_UNKNOWN {
		return false
	}
	deck_set_trim(d, master.trim_db + master.loudness_db - d.loudness_db)
	return true
}
