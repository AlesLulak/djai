package main

import "core:math"

// Iterative radix-2 complex FFT. Size must be a power of two.
FFT :: struct {
	n:     int,
	cos_t: []f32, // cos(2*pi*j/n), j in [0, n/2)
	sin_t: []f32, // sin(2*pi*j/n)
	rev:   []int, // bit-reversal permutation
}

fft_make :: proc(n: int) -> FFT {
	assert(n > 0 && (n & (n - 1)) == 0, "FFT size must be a power of two")
	f := FFT{n = n}
	f.cos_t = make([]f32, n / 2)
	f.sin_t = make([]f32, n / 2)
	f.rev = make([]int, n)
	for j in 0 ..< n / 2 {
		a := 2 * math.PI * f64(j) / f64(n)
		f.cos_t[j] = f32(math.cos(a))
		f.sin_t[j] = f32(math.sin(a))
	}
	bits := 0
	for (1 << uint(bits)) < n {
		bits += 1
	}
	for i in 0 ..< n {
		r := 0
		v := i
		for _ in 0 ..< bits {
			r = (r << 1) | (v & 1)
			v >>= 1
		}
		f.rev[i] = r
	}
	return f
}

fft_destroy :: proc(f: ^FFT) {
	delete(f.cos_t)
	delete(f.sin_t)
	delete(f.rev)
}

// In-place forward transform. re/im must have length f.n.
fft_forward :: proc(f: ^FFT, re, im: []f32) {
	fft_core(f, re, im, false)
}

// In-place inverse transform, scaled by 1/n.
fft_inverse :: proc(f: ^FFT, re, im: []f32) {
	fft_core(f, re, im, true)
	scale := 1.0 / f32(f.n)
	for i in 0 ..< f.n {
		re[i] *= scale
		im[i] *= scale
	}
}

@(private = "file")
fft_core :: proc(f: ^FFT, re, im: []f32, inverse: bool) #no_bounds_check {
	n := f.n
	for i in 0 ..< n {
		j := f.rev[i]
		if j > i {
			re[i], re[j] = re[j], re[i]
			im[i], im[j] = im[j], im[i]
		}
	}
	sign: f32 = inverse ? 1 : -1
	for size := 2; size <= n; size *= 2 {
		half := size / 2
		step := n / size
		for start := 0; start < n; start += size {
			for k in 0 ..< half {
				wr := f.cos_t[k * step]
				wi := sign * f.sin_t[k * step]
				a := start + k
				b := a + half
				xr := re[b]
				xi := im[b]
				tr := xr * wr - xi * wi
				ti := xr * wi + xi * wr
				re[b] = re[a] - tr
				im[b] = im[a] - ti
				re[a] += tr
				im[a] += ti
			}
		}
	}
}
