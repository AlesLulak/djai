package main

import "core:math"
import "core:slice"

// ---------------------------------------------------------------------------
// Biquad filters (RBJ Audio EQ Cookbook), transposed direct form II.
// ---------------------------------------------------------------------------

Biquad :: struct {
	b0, b1, b2, a1, a2: f32,
	z1, z2:             f32,
}

BUTTERWORTH_Q :: 0.70710678

biquad_lowpass :: proc(fc, fs: f32, q: f32 = BUTTERWORTH_Q) -> Biquad {
	w0 := 2 * math.PI * fc / fs
	c := math.cos(w0)
	alpha := math.sin(w0) / (2 * q)
	a0 := 1 + alpha
	return Biquad {
		b0 = (1 - c) / 2 / a0,
		b1 = (1 - c) / a0,
		b2 = (1 - c) / 2 / a0,
		a1 = -2 * c / a0,
		a2 = (1 - alpha) / a0,
	}
}

// Filters x in place.
biquad_process :: proc(bq: ^Biquad, x: []f32) #no_bounds_check {
	for i in 0 ..< len(x) {
		in_ := x[i]
		out := bq.b0 * in_ + bq.z1
		bq.z1 = bq.b1 * in_ - bq.a1 * out + bq.z2
		bq.z2 = bq.b2 * in_ - bq.a2 * out
		x[i] = out
	}
}

// Zero-phase low-pass: one Butterworth stage forward, one backward.
// Magnitude response is the stage squared (24 dB/oct), phase is zero, so
// band = filter(x) and rest = x - band split cleanly without phase smear.
lowpass_24db :: proc(x: []f32, fc, fs: f32) {
	bq := biquad_lowpass(fc, fs)
	biquad_process(&bq, x)
	slice.reverse(x)
	bq = biquad_lowpass(fc, fs)
	biquad_process(&bq, x)
	slice.reverse(x)
}

// ---------------------------------------------------------------------------
// STFT with Hann window, hop = size / 4, centred frames.
// ---------------------------------------------------------------------------

Spec :: struct {
	n:      int, // original sample count
	size:   int, // FFT size
	hop:    int,
	bins:   int, // size / 2 + 1
	frames: int,
	re, im: []f32, // frames * bins, row-major by frame
}

spec_destroy :: proc(s: ^Spec) {
	delete(s.re)
	delete(s.im)
}

hann_window :: proc(n: int) -> []f32 {
	w := make([]f32, n)
	for i in 0 ..< n {
		w[i] = f32(0.5 - 0.5 * math.cos(2 * math.PI * f64(i) / f64(n)))
	}
	return w
}

stft :: proc(x: []f32, size: int) -> Spec {
	n := len(x)
	hop := size / 4
	pad := size / 2
	s := Spec {
		n      = n,
		size   = size,
		hop    = hop,
		bins   = size / 2 + 1,
		frames = n / hop + 1,
	}
	s.re = make([]f32, s.frames * s.bins)
	s.im = make([]f32, s.frames * s.bins)

	fft := fft_make(size)
	defer fft_destroy(&fft)
	window := hann_window(size)
	defer delete(window)
	fr := make([]f32, size)
	fi := make([]f32, size)
	defer delete(fr)
	defer delete(fi)

	#no_bounds_check for t in 0 ..< s.frames {
		start := t * hop - pad
		for i in 0 ..< size {
			idx := start + i
			v: f32 = (idx >= 0 && idx < n) ? x[idx] : 0
			fr[i] = v * window[i]
			fi[i] = 0
		}
		fft_forward(&fft, fr, fi)
		copy(s.re[t * s.bins:][:s.bins], fr[:s.bins])
		copy(s.im[t * s.bins:][:s.bins], fi[:s.bins])
	}
	return s
}

// Inverse STFT of (spec * mask). A nil mask means no masking. Overlap-add
// with window-squared normalisation, so stft -> istft reproduces the input to
// float precision.
istft :: proc(s: ^Spec, mask: []f32) -> []f32 {
	size, hop, bins := s.size, s.hop, s.bins
	pad := size / 2
	padded_len := s.n + size
	out := make([]f32, padded_len)
	norm := make([]f32, padded_len)
	defer delete(out)
	defer delete(norm)

	fft := fft_make(size)
	defer fft_destroy(&fft)
	window := hann_window(size)
	defer delete(window)
	fr := make([]f32, size)
	fi := make([]f32, size)
	defer delete(fr)
	defer delete(fi)

	#no_bounds_check for t in 0 ..< s.frames {
		base := t * bins
		for k in 0 ..< bins {
			m: f32 = mask != nil ? mask[base + k] : 1
			fr[k] = s.re[base + k] * m
			fi[k] = s.im[base + k] * m
		}
		for k in 1 ..< size / 2 {
			fr[size - k] = fr[k]
			fi[size - k] = -fi[k]
		}
		fft_inverse(&fft, fr, fi)
		start := t * hop
		for i in 0 ..< size {
			w := window[i]
			out[start + i] += fr[i] * w
			norm[start + i] += w * w
		}
	}

	result := make([]f32, s.n)
	#no_bounds_check for i in 0 ..< s.n {
		j := i + pad
		result[i] = norm[j] > 1e-8 ? out[j] / norm[j] : 0
	}
	return result
}

spec_magnitude :: proc(s: ^Spec) -> []f32 {
	total := s.frames * s.bins
	mag := make([]f32, total)
	#no_bounds_check for i in 0 ..< total {
		mag[i] = math.sqrt(s.re[i] * s.re[i] + s.im[i] * s.im[i])
	}
	return mag
}

// ---------------------------------------------------------------------------
// HPSS building blocks (Fitzgerald 2010): median filtering of the magnitude
// along time gives the harmonic estimate H, along frequency the percussive
// estimate P. ratio_mask turns num/den into a soft weight with a separation
// margin (Driedger 2014): 0 below lo, 1 above hi, linear in between.
// ---------------------------------------------------------------------------

median_along_time :: proc(mag, out: []f32, frames, bins, k: int) #no_bounds_check {
	half := k / 2
	buf := make([]f32, k)
	defer delete(buf)
	for t in 0 ..< frames {
		for b in 0 ..< bins {
			for j in 0 ..< k {
				tt := clamp(t + j - half, 0, frames - 1)
				buf[j] = mag[tt * bins + b]
			}
			out[t * bins + b] = median_small(buf)
		}
	}
}

// In place.
median_along_freq :: proc(mag: []f32, frames, bins, k: int) #no_bounds_check {
	half := k / 2
	buf := make([]f32, k)
	row := make([]f32, bins)
	defer delete(buf)
	defer delete(row)
	for t in 0 ..< frames {
		base := t * bins
		copy(row, mag[base:][:bins])
		for b in 0 ..< bins {
			for j in 0 ..< k {
				bb := clamp(b + j - half, 0, bins - 1)
				buf[j] = row[bb]
			}
			mag[base + b] = median_small(buf)
		}
	}
}

// Writes the mask into num.
ratio_mask :: proc(num, den: []f32, lo, hi: f32) #no_bounds_check {
	for i in 0 ..< len(num) {
		a := num[i]
		b := den[i]
		w: f32
		if a <= 1e-9 {
			w = 0
		} else if b <= 1e-9 {
			w = 1
		} else {
			w = clamp((a / b - lo) / (hi - lo), 0, 1)
		}
		num[i] = w
	}
}

// Returns the weight of the component whose estimate is median-filtered
// along `axis_time` (true: harmonic, i.e. stationary; false: percussive).
hpss_weight :: proc(s: ^Spec, kt, kf: int, lo, hi: f32, want_harmonic: bool) -> []f32 {
	mag := spec_magnitude(s)
	h := make([]f32, len(mag))
	median_along_time(mag, h, s.frames, s.bins, kt)
	median_along_freq(mag, s.frames, s.bins, kf) // mag is now P
	if want_harmonic {
		ratio_mask(h, mag, lo, hi)
		delete(mag)
		return h
	}
	ratio_mask(mag, h, lo, hi)
	delete(h)
	return mag
}

// ---------------------------------------------------------------------------
// Centre mask: per-bin stereo coherence.
// A mono source panned to the centre gives L == R in every bin, so
// Re(L * conj(R)) * 2 / (|L|^2 + |R|^2) is 1. Stereo-widened synths, pads
// and reverb tails have decorrelated L/R and score lower. Linear ramp from
// `threshold` to 1. Bins outside [low_hz, high_hz] are excluded. Smoothed
// over three frames to reduce musical noise.
// ---------------------------------------------------------------------------

center_mask :: proc(l, r: ^Spec, sample_rate: u32, low_hz, high_hz, threshold: f32) -> []f32 {
	assert(l.frames == r.frames && l.bins == r.bins)
	frames, bins := l.frames, l.bins
	mask := make([]f32, frames * bins)

	bin_hz := f32(sample_rate) / f32(l.size)
	k_lo := int(low_hz / bin_hz)
	k_hi := min(int(high_hz / bin_hz), bins - 1)

	#no_bounds_check for t in 0 ..< frames {
		base := t * bins
		for k in k_lo ..= k_hi {
			i := base + k
			lr, li := l.re[i], l.im[i]
			rr, ri := r.re[i], r.im[i]
			energy := lr * lr + li * li + rr * rr + ri * ri
			if energy < 1e-12 {
				continue
			}
			coh := 2 * (lr * rr + li * ri) / energy
			if coh <= threshold {
				continue
			}
			mask[i] = (coh - threshold) / (1 - threshold)
		}
	}

	smooth_along_time(mask, frames, bins)
	return mask
}

smooth_along_time :: proc(mask: []f32, frames, bins: int) #no_bounds_check {
	if frames < 2 {
		return
	}
	prev := make([]f32, bins)
	cur := make([]f32, bins)
	defer delete(prev)
	defer delete(cur)
	copy(prev, mask[:bins])
	for t in 0 ..< frames {
		base := t * bins
		copy(cur, mask[base:][:bins])
		next := t + 1 < frames ? mask[base + bins:][:bins] : cur
		for k in 0 ..< bins {
			mask[base + k] = (prev[k] + cur[k] + next[k]) / 3
		}
		copy(prev, cur)
	}
}

// Insertion sort; fine for kernels of ~20 values.
median_small :: proc(v: []f32) -> f32 #no_bounds_check {
	for i in 1 ..< len(v) {
		x := v[i]
		j := i - 1
		for j >= 0 && v[j] > x {
			v[j + 1] = v[j]
			j -= 1
		}
		v[j + 1] = x
	}
	return v[len(v) / 2]
}

// ---------------------------------------------------------------------------
// REPET (Rafii & Pardo 2013), adaptive variant with a fractional period.
// Loop-based music repeats bar after bar; the lead vocal does not. The
// repeating background model is, per bin, the median of the magnitude over
// the same beat phase in the 2k+1 nearest loops. Background weight
// M = min(model / mix, 1); foreground (vocal candidate) weight is 1 - M.
// ---------------------------------------------------------------------------

// Beat spectrum: sum over bins of the autocorrelation of the squared
// magnitude along time, normalised by overlap length. FFT based.
beat_spectrum :: proc(mag: []f32, frames, bins, max_lag: int) -> []f64 {
	size := 1
	for size < 2 * frames {
		size *= 2
	}
	fft := fft_make(size)
	defer fft_destroy(&fft)
	re := make([]f32, size)
	im := make([]f32, size)
	defer delete(re)
	defer delete(im)
	b := make([]f64, max_lag)

	// Scale so squared magnitudes stay in float range.
	peak: f32 = 1e-12
	for v in mag {
		peak = max(peak, v)
	}
	inv := 1 / (peak * peak)

	#no_bounds_check for k in 0 ..< bins {
		for i in 0 ..< size {
			re[i] = 0
			im[i] = 0
		}
		for t in 0 ..< frames {
			v := mag[t * bins + k]
			re[t] = v * v * inv
		}
		fft_forward(&fft, re, im)
		for i in 0 ..< size {
			re[i] = re[i] * re[i] + im[i] * im[i]
			im[i] = 0
		}
		fft_inverse(&fft, re, im)
		for l in 0 ..< max_lag {
			b[l] += f64(re[l])
		}
	}
	for l in 0 ..< max_lag {
		b[l] /= f64(frames - l)
	}
	return b
}

// Picks the period (in frames, fractional) in [lag_min, lag_max] whose
// multiples score highest on the beat spectrum, then refines it with a
// parabolic fit. Returns 0 when nothing usable is found.
repet_period :: proc(b: []f64, lag_min, lag_max: int) -> f64 {
	max_lag := len(b)
	best_l := 0
	best_score := -1.0
	for l in lag_min ..= min(lag_max, max_lag - 2) {
		// Local maximum only.
		if !(b[l] >= b[l - 1] && b[l] >= b[l + 1]) {
			continue
		}
		score := 0.0
		count := 0
		for m := l; m < max_lag; m += l {
			score += b[m]
			count += 1
			if count == 4 {
				break
			}
		}
		score /= f64(count)
		if score > best_score {
			best_score = score
			best_l = l
		}
	}
	if best_l == 0 {
		return 0
	}
	// Parabolic refinement around the peak.
	y0, y1, y2 := b[best_l - 1], b[best_l], b[best_l + 1]
	denom := y0 - 2 * y1 + y2
	offset := denom != 0 ? 0.5 * (y0 - y2) / denom : 0
	return f64(best_l) + clamp(offset, -0.5, 0.5)
}

// Background weight per bin from the local repeating model. `k` loops on
// each side of the current one take part in the median.
repet_background_weight :: proc(mag: []f32, frames, bins: int, period: f64, k: int) -> []f32 {
	weight := make([]f32, frames * bins)
	buf := make([]f32, 2 * k + 1)
	rows := make([]int, 2 * k + 1)
	defer delete(buf)
	defer delete(rows)

	#no_bounds_check for t in 0 ..< frames {
		seg := math.floor(f64(t) / period)
		phase := f64(t) - seg * period
		count := 0
		for d in -k ..= k {
			tt := int(math.round((seg + f64(d)) * period + phase))
			if tt >= 0 && tt < frames {
				rows[count] = tt * bins
				count += 1
			}
		}
		base := t * bins
		for b in 0 ..< bins {
			for j in 0 ..< count {
				buf[j] = mag[rows[j] + b]
			}
			model := median_small(buf[:count])
			v := mag[base + b]
			weight[base + b] = v > 1e-9 ? min(model / v, 1) : 1
		}
	}
	return weight
}
