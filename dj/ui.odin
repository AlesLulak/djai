package main

import "core:fmt"
import "core:math"
import "core:strings"
import rl "vendor:raylib"

// Immediate-mode widgets on top of raylib. One widget may own the mouse
// (ui.active) while it is being dragged.

UI :: struct {
	mouse:    rl.Vector2,
	pressed:  bool, // left button went down this frame
	down:     bool,
	released: bool,
	active:   rawptr, // widget currently dragged
	drag_y0:  f32,
	drag_x0:  f32,
	drag_v0:  f32,
}

ui: UI

// Embedded font (DejaVu Sans, see assets/DejaVuSans-LICENSE), two atlases so
// small labels and the big deck numbers both stay sharp.
FONT_DATA := #load("assets/DejaVuSans.ttf")
font_small: rl.Font // for sizes up to 18
font_large: rl.Font // for larger sizes
FONT_SMALL_SIZE :: 18
FONT_LARGE_SIZE :: 40

ui_init_fonts :: proc() {
	// ASCII, Latin-1 and Latin Extended-A/B cover Czech and most European names.
	codepoints := make([]rune, 592 - 32, context.temp_allocator)
	for &c, i in codepoints {
		c = rune(32 + i)
	}
	font_small = rl.LoadFontFromMemory(".ttf", raw_data(FONT_DATA), i32(len(FONT_DATA)), FONT_SMALL_SIZE, raw_data(codepoints), i32(len(codepoints)))
	font_large = rl.LoadFontFromMemory(".ttf", raw_data(FONT_DATA), i32(len(FONT_DATA)), FONT_LARGE_SIZE, raw_data(codepoints), i32(len(codepoints)))
	rl.SetTextureFilter(font_small.texture, .BILINEAR)
	rl.SetTextureFilter(font_large.texture, .BILINEAR)
}

ui_font :: proc(size: i32) -> rl.Font {
	return size > FONT_SMALL_SIZE ? font_large : font_small
}

text_width :: proc(text: cstring, size: i32) -> f32 {
	return rl.MeasureTextEx(ui_font(size), text, f32(size), 0).x
}

COL_BG      :: rl.Color{18, 18, 22, 255}
COL_PANEL   :: rl.Color{30, 30, 36, 255}
COL_PANEL2  :: rl.Color{42, 42, 50, 255}
COL_LINE    :: rl.Color{70, 70, 80, 255}
COL_TEXT    :: rl.Color{220, 220, 225, 255}
COL_DIM     :: rl.Color{130, 130, 140, 255}
COL_ACCENT  :: rl.Color{255, 140, 40, 255}
COL_GREEN   :: rl.Color{90, 200, 120, 255}
COL_LOW     :: rl.Color{230, 80, 60, 255}
COL_MID     :: rl.Color{90, 200, 120, 255}
COL_HIGH    :: rl.Color{90, 150, 240, 255}
COL_PLAYHEAD :: rl.Color{255, 255, 255, 255}
COL_CUE     :: rl.Color{255, 220, 60, 255}

ui_begin_frame :: proc() {
	ui.mouse = rl.GetMousePosition()
	ui.pressed = rl.IsMouseButtonPressed(.LEFT)
	ui.down = rl.IsMouseButtonDown(.LEFT)
	ui.released = rl.IsMouseButtonReleased(.LEFT)
	if ui.released {
		ui.active = nil
	}
}

// While a dialog is open the widgets under it must not see the mouse: the
// pointer is moved off screen and the buttons read as idle. ui_block(false)
// gives the real input back for the dialog itself.
ui_block :: proc(blocked: bool) {
	if blocked {
		ui.mouse = {-10000, -10000}
		ui.pressed = false
		ui.down = false
		ui.released = false
		ui.active = nil
	} else {
		ui.mouse = rl.GetMousePosition()
		ui.pressed = rl.IsMouseButtonPressed(.LEFT)
		ui.down = rl.IsMouseButtonDown(.LEFT)
		ui.released = rl.IsMouseButtonReleased(.LEFT)
	}
}

WHEEL_STEP      :: 0.02 // of the full range per notch at slow speed
WHEEL_ACCEL_MAX :: 8.0  // fastest multiplier
WHEEL_BURST_S   :: 0.25 // notches closer than this count as fast scrolling

wheel_last_time: f64
wheel_speed:     f32 = 1

// Wheel acceleration: notches arriving in quick succession grow the step,
// a pause resets it. Returns the multiplier for the current notch.
wheel_accel :: proc() -> f32 {
	now := rl.GetTime()
	if now - wheel_last_time < WHEEL_BURST_S {
		wheel_speed = min(wheel_speed * 1.3, WHEEL_ACCEL_MAX)
	} else {
		wheel_speed = 1
	}
	wheel_last_time = now
	return wheel_speed
}

// Mouse wheel over a control nudges its 0..1 value. Returns true on change.
wheel_step :: proc(value: ^f32) -> bool {
	wheel := rl.GetMouseWheelMove()
	if wheel == 0 {
		return false
	}
	v := clamp(value^ + wheel * WHEEL_STEP * wheel_accel(), 0, 1)
	if v == value^ {
		return false
	}
	value^ = v
	return true
}

tcs :: proc(s: string) -> cstring {
	return strings.clone_to_cstring(s, context.temp_allocator)
}

label :: proc(text: cstring, x, y: f32, size: i32 = 16, color := COL_TEXT) {
	rl.DrawTextEx(ui_font(size), text, {x, y}, f32(size), 0, color)
}

label_centered :: proc(text: cstring, cx, y: f32, size: i32 = 16, color := COL_TEXT) {
	w := text_width(text, size)
	rl.DrawTextEx(ui_font(size), text, {cx - w / 2, y}, f32(size), 0, color)
}

panel :: proc(r: rl.Rectangle, color := COL_PANEL) {
	rl.DrawRectangleRec(r, color)
	rl.DrawRectangleLinesEx(r, 1, COL_LINE)
}

// Returns true when clicked this frame.
button :: proc(r: rl.Rectangle, text: cstring, lit := false, hint: cstring = nil) -> bool {
	hover := rl.CheckCollisionPointRec(ui.mouse, r)
	color := lit ? COL_ACCENT : (hover ? COL_PANEL2 : COL_PANEL)
	rl.DrawRectangleRec(r, color)
	rl.DrawRectangleLinesEx(r, 1, hover ? COL_TEXT : COL_LINE)
	fg := lit ? COL_BG : COL_TEXT
	label_centered(text, r.x + r.width / 2, r.y + r.height / 2 - 8, 16, fg)
	if hint != nil {
		label_centered(hint, r.x + r.width / 2, r.y + r.height - 12, 10, lit ? COL_BG : COL_DIM)
	}
	return hover && ui.pressed
}

// Rotary knob, vertical drag. Returns true when the value changed.
knob :: proc(id: rawptr, cx, cy, radius: f32, value: ^f32, text: cstring, readout: cstring = nil) -> bool {
	changed := false
	center := rl.Vector2{cx, cy}
	hover := rl.Vector2Distance(ui.mouse, center) <= radius + 4
	if hover && ui.pressed && ui.active == nil {
		ui.active = id
		ui.drag_y0 = ui.mouse.y
		ui.drag_v0 = value^
	}
	if ui.active == id && ui.down {
		v := clamp(ui.drag_v0 + (ui.drag_y0 - ui.mouse.y) / 150, 0, 1)
		if v != value^ {
			value^ = v
			changed = true
		}
	}
	if hover && wheel_step(value) {
		changed = true
	}
	// 270 degree sweep, 135 degrees from the bottom on each side.
	start: f32 = 135
	sweep: f32 = 270
	rl.DrawRing(center, radius - 6, radius, start, start + sweep, 32, COL_PANEL2)
	rl.DrawRing(center, radius - 6, radius, start, start + sweep * value^, 32, COL_ACCENT)
	a := (start + sweep * value^) * math.PI / 180
	tip := rl.Vector2{cx + math.cos(a) * (radius - 9), cy + math.sin(a) * (radius - 9)}
	rl.DrawLineEx(center, tip, 3, hover || ui.active == id ? COL_TEXT : COL_DIM)
	label_centered(text, cx, cy + radius + 4, 12, COL_DIM)
	if readout != nil {
		label_centered(readout, cx, cy - 6, 12, COL_TEXT)
	}
	return changed
}

// Vertical fader. Returns true when the value changed.
vslider :: proc(id: rawptr, r: rl.Rectangle, value: ^f32, text: cstring, color := COL_ACCENT) -> bool {
	changed := false
	hover := rl.CheckCollisionPointRec(ui.mouse, r)
	if hover && ui.pressed && ui.active == nil {
		ui.active = id
	}
	if ui.active == id && ui.down {
		v := clamp(1 - (ui.mouse.y - r.y) / r.height, 0, 1)
		if v != value^ {
			value^ = v
			changed = true
		}
	}
	if hover && wheel_step(value) {
		changed = true
	}
	track := rl.Rectangle{r.x + r.width / 2 - 3, r.y, 6, r.height}
	rl.DrawRectangleRec(track, COL_PANEL2)
	fill := rl.Rectangle{track.x, r.y + r.height * (1 - value^), 6, r.height * value^}
	rl.DrawRectangleRec(fill, color)
	ky := r.y + r.height * (1 - value^)
	rl.DrawRectangleRec({r.x + 2, ky - 6, r.width - 4, 12}, hover || ui.active == id ? COL_TEXT : COL_DIM)
	label_centered(text, r.x + r.width / 2, r.y + r.height + 4, 12, COL_DIM)
	return changed
}

// Horizontal fader. Returns true when the value changed.
hslider :: proc(id: rawptr, r: rl.Rectangle, value: ^f32, text: cstring, center_mark := false) -> bool {
	changed := false
	hover := rl.CheckCollisionPointRec(ui.mouse, r)
	if hover && ui.pressed && ui.active == nil {
		ui.active = id
	}
	if ui.active == id && ui.down {
		v := clamp((ui.mouse.x - r.x) / r.width, 0, 1)
		if v != value^ {
			value^ = v
			changed = true
		}
	}
	if hover && wheel_step(value) {
		changed = true
	}
	track := rl.Rectangle{r.x, r.y + r.height / 2 - 3, r.width, 6}
	rl.DrawRectangleRec(track, COL_PANEL2)
	if center_mark {
		rl.DrawRectangleRec({r.x + r.width / 2 - 1, r.y, 2, r.height}, COL_LINE)
	}
	kx := r.x + r.width * value^
	rl.DrawRectangleRec({kx - 6, r.y + 2, 12, r.height - 4}, hover || ui.active == id ? COL_TEXT : COL_ACCENT)
	label_centered(text, r.x + r.width / 2, r.y + r.height + 4, 12, COL_DIM)
	return changed
}

// Overview waveform. Returns true and the clicked fraction when clicked.
waveform :: proc(r: rl.Rectangle, px: []Wave_Pixel, position: f32, cue: f32) -> (clicked: bool, at: f32) {
	rl.DrawRectangleRec(r, rl.Color{10, 10, 12, 255})
	if len(px) > 0 {
		mid := r.y + r.height / 2
		half := r.height / 2 - 2
		for i in 0 ..< int(r.width) {
			p := px[i * len(px) / int(r.width)]
			x := r.x + f32(i)
			hl := p.low * half
			hm := p.mid * half
			hh := p.high * half
			// stacked: low at the centre, mid on top of it, high outermost
			rl.DrawLineV({x, mid - hl - hm - hh}, {x, mid + hl + hm + hh}, COL_HIGH)
			rl.DrawLineV({x, mid - hl - hm}, {x, mid + hl + hm}, COL_MID)
			rl.DrawLineV({x, mid - hl}, {x, mid + hl}, COL_LOW)
		}
		cx := r.x + r.width * cue
		rl.DrawLineEx({cx, r.y}, {cx, r.y + r.height}, 2, COL_CUE)
		hx := r.x + r.width * position
		rl.DrawLineEx({hx, r.y}, {hx, r.y + r.height}, 2, COL_PLAYHEAD)
	}
	rl.DrawRectangleLinesEx(r, 1, COL_LINE)
	if rl.CheckCollisionPointRec(ui.mouse, r) && ui.pressed && ui.active == nil {
		return true, clamp((ui.mouse.x - r.x) / r.width, 0, 1)
	}
	return false, 0
}

format_time :: proc(seconds: f32) -> cstring {
	s := max(seconds, 0)
	m := int(s) / 60
	return fmt.ctprintf("%d:%02d", m, int(s) - m * 60)
}

// Round transport button (CUE, PLAY). Returns true when clicked.
round_button :: proc(cx, cy, radius: f32, text: cstring, color: rl.Color, lit: bool) -> bool {
	center := rl.Vector2{cx, cy}
	hover := rl.Vector2Distance(ui.mouse, center) <= radius
	rl.DrawCircleV(center, radius, lit ? color : COL_PANEL2)
	rl.DrawRing(center, radius - 3, radius, 0, 360, 48, hover ? COL_TEXT : color)
	label_centered(text, cx, cy - 8, 16, lit ? COL_BG : COL_TEXT)
	return hover && ui.pressed
}

// Performance pad. Returns (clicked, right_clicked).
pad :: proc(r: rl.Rectangle, text: cstring, color: rl.Color, lit: bool, dim := false) -> (clicked, right_clicked: bool) {
	hover := rl.CheckCollisionPointRec(ui.mouse, r)
	fill := lit ? color : (dim ? rl.Color{24, 24, 28, 255} : COL_PANEL2)
	rl.DrawRectangleRounded(r, 0.15, 4, fill)
	rl.DrawRectangleRoundedLinesEx(r, 0.15, 4, 1, hover ? COL_TEXT : (dim ? COL_LINE : color))
	label_centered(text, r.x + r.width / 2, r.y + r.height / 2 - 5, 10, lit ? COL_BG : (dim ? COL_DIM : COL_TEXT))
	return hover && ui.pressed, hover && rl.IsMouseButtonPressed(.RIGHT)
}

// Jog wheel: platter with a position marker that turns like a record.
jog :: proc(cx, cy, radius: f32, seconds: f32, playing: bool) {
	center := rl.Vector2{cx, cy}
	rl.DrawCircleV(center, radius, rl.Color{26, 26, 30, 255})
	rl.DrawRing(center, radius - 2, radius, 0, 360, 96, COL_LINE)
	rl.DrawRing(center, radius * 0.55 - 1, radius * 0.55 + 1, 0, 360, 64, COL_LINE)
	rl.DrawCircleV(center, radius * 0.1, COL_PANEL2)
	// 33 1/3 rpm
	a := seconds * (100.0 / 3 / 60) * 2 * math.PI
	tip := rl.Vector2{cx + math.cos(a) * radius * 0.55, cy + math.sin(a) * radius * 0.55}
	rl.DrawCircleV(tip, 5, playing ? COL_ACCENT : COL_DIM)
}

// Scrolling wave: playhead fixed in the centre, `zoom` seconds across the
// width. Layers drawn from the same baseline: vocals transparent at the
// back, other lighter, bass opaque in the deck colour, drum hits as bright
// spikes in front. Beat ticks at the top and bottom edge, bars taller.
// The wave bodies are drawn into an off-screen texture at WAVE_SS times the
// screen resolution and scaled down with bilinear filtering, which smooths
// the edges that one-pixel columns on the screen cannot.
WAVE_SS :: 2
WAVE_BG :: rl.Color{10, 10, 12, 255}

wave_targets: [NUM_DECKS]rl.RenderTexture2D

wave_target :: proc(index: int, w, h: i32) -> rl.RenderTexture2D {
	rt := &wave_targets[index]
	if rt.id == 0 || rt.texture.width != w || rt.texture.height != h {
		if rt.id != 0 {
			rl.UnloadRenderTexture(rt^)
		}
		rt^ = rl.LoadRenderTexture(w, h)
		rl.SetTextureFilter(rt.texture, .BILINEAR)
	}
	return rt^
}

pixel_max :: proc(a, b: Wave_Pixel) -> Wave_Pixel {
	return {max(a.low, b.low), max(a.mid, b.mid), max(a.high, b.high), max(a.beat, b.beat)}
}

// Envelope at a fractional bin index, linear between bin centres and zero
// outside the track.
fine_at :: proc(fine: []Wave_Pixel, f: f32) -> Wave_Pixel {
	k := int(math.floor(f))
	t := f - f32(k)
	a, b: Wave_Pixel
	if k >= 0 && k < len(fine) {
		a = fine[k]
	}
	if k + 1 >= 0 && k + 1 < len(fine) {
		b = fine[k + 1]
	}
	return {
		a.low + (b.low - a.low) * t,
		a.mid + (b.mid - a.mid) * t,
		a.high + (b.high - a.high) * t,
		a.beat + (b.beat - a.beat) * t,
	}
}

// Envelope over the column t0..t1 seconds: the interpolated value at both
// ends plus every bin centre in between. Zoomed in, columns follow a smooth
// curve instead of repeating one bin; zoomed out, they keep their peaks.
fine_column :: proc(fine: []Wave_Pixel, t0, t1: f32) -> (p: Wave_Pixel, ok: bool) {
	bins_per_sec := f32(SAMPLE_RATE) / FINE_HOP
	f0 := t0 * bins_per_sec - 0.5
	f1 := t1 * bins_per_sec - 0.5
	if f1 < -1 || f0 >= f32(len(fine)) {
		return
	}
	p = pixel_max(fine_at(fine, f0), fine_at(fine, f1))
	for b in max(int(math.ceil(f0)), 0) ..< min(int(math.ceil(f1)), len(fine)) {
		p = pixel_max(p, fine[b])
	}
	return p, true
}

scroll_wave :: proc(r: rl.Rectangle, d: ^Deck, zoom: f32, base: rl.Color) -> (dragged: bool, delta_seconds: f32) {
	rl.DrawRectangleRec(r, WAVE_BG)
	// Horizontal drag scrubs the deck: the wave follows the mouse.
	if rl.CheckCollisionPointRec(ui.mouse, r) && ui.pressed && ui.active == nil && len(d.fine) > 0 {
		ui.active = d
		ui.drag_x0 = ui.mouse.x
	}
	if ui.active == d && ui.down {
		dragged = true
		delta_seconds = (ui.mouse.x - ui.drag_x0) * zoom / r.width
		ui.drag_x0 = ui.mouse.x
	}
	if len(d.fine) > 0 {
		_, pos_sec := deck_position(d)
		sec_per_px := zoom / r.width
		// Bodies: supersampled off screen, then scaled onto r
		tw := i32(r.width) * WAVE_SS
		th := i32(r.height) * WAVE_SS
		rt := wave_target(d.index, tw, th)
		mid := f32(th) / 2
		half := mid - 3 * WAVE_SS
		sec_per_col := sec_per_px / WAVE_SS
		vocals_c := rl.Color{255, 255, 255, 60}
		beat_c := rl.Color{255, 255, 255, 210}
		other_c := rl.Color{u8((u16(base.r) + 255) / 2), u8((u16(base.g) + 255) / 2), u8((u16(base.b) + 255) / 2), 140}
		rl.BeginTextureMode(rt)
		rl.ClearBackground(WAVE_BG)
		for i in 0 ..< int(tw) {
			t0 := pos_sec + (f32(i) - f32(tw) / 2) * sec_per_col
			p, ok := fine_column(d.fine, t0, t0 + sec_per_col)
			if !ok {
				continue
			}
			x := f32(i)
			rl.DrawRectangleRec({x, mid - p.high * half, 1, 2 * p.high * half}, vocals_c)
			rl.DrawRectangleRec({x, mid - p.mid * half, 1, 2 * p.mid * half}, other_c)
			rl.DrawRectangleRec({x, mid - p.low * half, 1, 2 * p.low * half}, base)
			if p.beat > 0.08 {
				rl.DrawRectangleRec({x, mid - p.beat * half, 1, 2 * p.beat * half}, beat_c)
			}
		}
		rl.EndTextureMode()
		rl.DrawTexturePro(rt.texture, {0, 0, f32(tw), -f32(th)}, {r.x, r.y, f32(tw) / WAVE_SS, f32(th) / WAVE_SS}, {0, 0}, 0, rl.WHITE)
		if d.bpm > 0 {
			period := 60 / d.bpm
			t_left := pos_sec - zoom / 2
			t_right := pos_sec + zoom / 2
			k := int(math.floor((t_left - d.beat_offset) / period))
			for ; ; k += 1 {
				tb := d.beat_offset + f32(k) * period
				if tb > t_right {
					break
				}
				if tb < t_left || tb < 0 {
					continue
				}
				x := r.x + r.width / 2 + (tb - pos_sec) / sec_per_px
				bar := ((k % 4) + 4) % 4 == 0
				h: f32 = bar ? r.height * 0.3 : r.height * 0.14
				c := bar ? COL_TEXT : COL_DIM
				rl.DrawLineV({x, r.y + 1}, {x, r.y + 1 + h}, c)
				rl.DrawLineV({x, r.y + r.height - 1 - h}, {x, r.y + r.height - 1}, c)
			}
		}
		// Cue point and hot cues inside the view
		view := Scroll_View{pos_sec = pos_sec, sec_per_px = sec_per_px}
		if cx, visible := scroll_frame_to_x(d, r, d.cue, &view); visible && d.cue > 0 {
			rl.DrawLineEx({cx, r.y}, {cx, r.y + r.height}, 2, COL_CUE)
		}
		draw_hot_cues(d, r, scroll_frame_to_x, &view)
		cx := r.x + r.width / 2
		rl.DrawLineEx({cx, r.y}, {cx, r.y + r.height}, 2, COL_PLAYHEAD)
	}
	rl.DrawRectangleLinesEx(r, 1, COL_LINE)
	return
}

Scroll_View :: struct {
	pos_sec:    f32,
	sec_per_px: f32,
}

scroll_frame_to_x :: proc(d: ^Deck, r: rl.Rectangle, frames: f64, ctx: rawptr) -> (x: f32, visible: bool) {
	v := (^Scroll_View)(ctx)
	t := f32(frames / SAMPLE_RATE)
	x = r.x + r.width / 2 + (t - v.pos_sec) / v.sec_per_px
	return x, x >= r.x && x <= r.x + r.width
}

overview_frame_to_x :: proc(d: ^Deck, r: rl.Rectangle, frames: f64, ctx: rawptr) -> (x: f32, visible: bool) {
	if d.frames == 0 {
		return 0, false
	}
	return r.x + r.width * f32(frames / f64(d.frames)), true
}

HOT_COLORS := [4]rl.Color{{230, 60, 50, 255}, {255, 150, 40, 255}, {70, 150, 255, 255}, {220, 80, 255, 255}}

// Vertical hot cue marker with its number in a small box at the top.
hot_cue_marker :: proc(x, top, height: f32, index: int) {
	c := HOT_COLORS[index]
	rl.DrawLineEx({x, top}, {x, top + height}, 2, c)
	rl.DrawRectangleRec({x - 7, top, 14, 14}, c)
	label_centered(fmt.ctprintf("%d", index + 1), x, top + 1, 12, COL_BG)
}

// Markers for every set hot cue of the deck, given a mapping from frames to x.
draw_hot_cues :: proc(d: ^Deck, r: rl.Rectangle, frame_to_x: proc(d: ^Deck, r: rl.Rectangle, frames: f64, ctx: rawptr) -> (x: f32, visible: bool), ctx: rawptr) {
	for hc, i in d.hot_cues {
		if hc < 0 {
			continue
		}
		if x, visible := frame_to_x(d, r, hc, ctx); visible {
			hot_cue_marker(x, r.y, r.height, i)
		}
	}
}
