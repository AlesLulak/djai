package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import rl "vendor:raylib"

WINDOW_W :: 1400
WINDOW_H :: 960

// ---------------------------------------------------------------------------
// Track browser and background separation jobs.
// ---------------------------------------------------------------------------

Track :: struct {
	path:      string,
	name:      cstring,
	is_dir:    bool,
	has_stems: bool,
}

Browser :: struct {
	folder:     string, // absolute
	tracks:     [dynamic]Track, // ".." and directories first, then audio files
	selected:   int,
	scroll:     int,
	shown:      int, // selection the list last scrolled to; the view follows a new one only
	last_click: f64,
	last_row:   int,
}

AUDIO_EXTS := []string{".mp3", ".wav", ".flac", ".ogg"}

is_audio_file :: proc(name: string) -> bool {
	lower := strings.to_lower(name, context.temp_allocator)
	for ext in AUDIO_EXTS {
		if strings.has_suffix(lower, ext) {
			return true
		}
	}
	return false
}

// Lists `folder`: ".." first, then directories, then audio files. Stem
// folders made by the stems tool are hidden; they show as a flag on their
// track instead. Returns false and keeps the old listing when the folder
// cannot be read.
browser_scan :: proc(b: ^Browser, folder: string) -> bool {
	abs, aerr := os.get_absolute_path(folder, context.allocator)
	if aerr != nil {
		return false
	}
	infos, err := os.read_all_directory_by_path(abs, context.temp_allocator)
	if err != nil {
		delete(abs)
		return false
	}
	for t in b.tracks {
		delete(t.path)
		delete(t.name)
	}
	clear(&b.tracks)
	delete(b.folder)
	b.folder = abs
	parent := os.dir(abs)
	if parent != "" && parent != abs {
		append(&b.tracks, Track{path = strings.clone(parent), name = strings.clone_to_cstring(".."), is_dir = true})
	}
	for fi in infos {
		if len(fi.name) > 0 && fi.name[0] == '.' {
			continue
		}
		if fi.type == .Directory {
			if strings.has_suffix(fi.name, "_stems") {
				continue
			}
			append(&b.tracks, Track {
				path   = strings.clone(fi.fullpath),
				name   = strings.clone_to_cstring(fi.name),
				is_dir = true,
			})
			continue
		}
		if !is_audio_file(fi.name) {
			continue
		}
		append(&b.tracks, Track {
			path      = strings.clone(fi.fullpath),
			name      = strings.clone_to_cstring(fi.name),
			has_stems = has_stems_for(fi.fullpath),
		})
	}
	slice.sort_by(b.tracks[:], proc(a, b: Track) -> bool {
		if a.is_dir != b.is_dir {
			return a.is_dir
		}
		if a.is_dir && string(a.name) == ".." {
			return true
		}
		if b.is_dir && string(b.name) == ".." {
			return false
		}
		return a.path < b.path
	})
	b.selected = clamp(b.selected, 0, max(len(b.tracks) - 1, 0))
	return true
}

// Enters the selected directory, or the parent with up = true.
browser_navigate :: proc(b: ^Browser, up: bool) {
	target: string
	if up {
		if len(b.tracks) > 0 && b.tracks[0].is_dir && string(b.tracks[0].name) == ".." {
			target = b.tracks[0].path
		} else {
			return
		}
	} else {
		if len(b.tracks) == 0 || !b.tracks[b.selected].is_dir {
			return
		}
		target = b.tracks[b.selected].path
	}
	came_from := strings.clone(b.folder, context.temp_allocator)
	target = strings.clone(target, context.temp_allocator)
	if browser_scan(b, target) {
		b.selected = 0
		b.scroll = 0
		// going up: select the folder we came from
		for t, i in b.tracks {
			if t.is_dir && t.path == came_from {
				b.selected = i
				break
			}
		}
	}
}

// One separation runs at a time; further requests wait in the queue.
Jobs :: struct {
	running: bool,
	process: os.Process,
	track:   string, // track being separated
	queue:   [dynamic]string,
	status:  cstring,
}

job_request :: proc(j: ^Jobs, track: string) {
	if j.running && j.track == track {
		return
	}
	for q in j.queue {
		if q == track {
			return
		}
	}
	if j.running {
		append(&j.queue, strings.clone(track))
		j.status = fmt.caprintf("queued %s (%d waiting)", os.base(track), len(j.queue))
		return
	}
	job_start(j, track)
}

job_start :: proc(j: ^Jobs, track: string) {
	exe := stems_executable()
	out := stems_dir_for(track, context.temp_allocator)
	cmd := []string{exe, track, out}
	p, err := os.process_start({command = cmd})
	if err != nil {
		j.status = fmt.caprintf("cannot start %s: %v", exe, err)
		return
	}
	j.running = true
	j.process = p
	j.track = strings.clone(track)
	j.status = fmt.caprintf("separating %s ...", os.base(track))
}

job_queued :: proc(j: ^Jobs, track: string) -> bool {
	for q in j.queue {
		if q == track {
			return true
		}
	}
	return false
}

// Non-blocking check. Returns true once when a job has just finished.
job_poll :: proc(j: ^Jobs) -> bool {
	if !j.running {
		return false
	}
	state, err := os.process_wait(j.process, 0)
	if err != nil || !state.exited {
		return false
	}
	j.running = false
	if state.exit_code == 0 {
		j.status = fmt.caprintf("stems ready: %s (load again to use them)", os.base(j.track))
	} else {
		j.status = fmt.caprintf("separation failed (exit %d): %s", state.exit_code, os.base(j.track))
	}
	delete(j.track)
	j.track = ""
	if len(j.queue) > 0 {
		next := j.queue[0]
		ordered_remove(&j.queue, 0)
		job_start(j, next)
		delete(next)
	}
	return true
}

// The stems CLI next to this executable, else "stems" on PATH.
stems_executable :: proc() -> string {
	dir := os.dir(os.args[0])
	if dir != "" {
		local := strings.concatenate({dir, "/stems"}, context.temp_allocator)
		if os.exists(local) {
			return local
		}
	}
	return "stems"
}

// ---------------------------------------------------------------------------
// Keys and layout
// ---------------------------------------------------------------------------

Deck_Keys :: struct {
	play, cue, load:                 rl.KeyboardKey,
	back, fwd:                       rl.KeyboardKey, // skip one bar
	vol_down, vol_up:                rl.KeyboardKey, // fader by VOLUME_STEP
	vol_toggle:                      rl.KeyboardKey, // fader to 0, or to full from 0
	hot:                             [4]rl.KeyboardKey,
	play_hint, cue_hint:             cstring,
	back_hint, fwd_hint, vol_hint:   cstring,
}

DECK_KEYS := [NUM_DECKS]Deck_Keys {
	{.Q, .W, .LEFT, .Z, .X, .A, .S, .D, {.ONE, .TWO, .THREE, .FOUR}, "Q", "W", "Z", "X", "A / S, D"},
	{.P, .O, .RIGHT, .N, .M, .K, .L, .J, {.SEVEN, .EIGHT, .NINE, .ZERO}, "P", "O", "N", "M", "K / L, J"},
}

MAKE_STEMS_KEY :: rl.KeyboardKey.F2

// A key press, or the repeat while it is held down.
key_hit :: proc(k: rl.KeyboardKey) -> bool {
	return rl.IsKeyPressed(k) || rl.IsKeyPressedRepeat(k)
}

// ---------------------------------------------------------------------------
// Drag and drop: a browser row dragged onto a deck, or a file dropped from
// the desktop. Deck zones (wave row and controller panel) and the browser
// panel are recorded while drawing, drops are resolved against them.
// ---------------------------------------------------------------------------

DRAG_THRESHOLD :: 6 // pixels before a press on a row becomes a drag

Drag :: struct {
	active: bool, // a row is held down
	moved:  bool, // and has travelled past the threshold
	path:   string, // owned copy, the browser may rescan meanwhile
	name:   cstring,
	x0, y0: f32,
}

drag: Drag
deck_zones: [NUM_DECKS][2]rl.Rectangle // [deck][wave row, controller]
browser_zone: rl.Rectangle

drag_begin :: proc(t: Track) {
	drag_end()
	drag = {active = true, path = strings.clone(t.path), name = strings.clone_to_cstring(string(t.name)), x0 = ui.mouse.x, y0 = ui.mouse.y}
}

drag_end :: proc() {
	delete(drag.path)
	if drag.name != nil {
		delete(drag.name)
	}
	drag = {}
}

// The deck whose zone contains p, else -1.
deck_at :: proc(p: rl.Vector2) -> int {
	for zones, i in deck_zones {
		for z in zones {
			if rl.CheckCollisionPointRec(p, z) {
				return i
			}
		}
	}
	return -1
}

// A file landed at p: on a deck it loads there (asking first when the deck
// plays), on the browser the browser opens its folder. Folders open in the
// browser wherever they land. strict = only an exact deck hit loads (in-app
// drags); otherwise the nearer half of the window decides (desktop drops).
drop_at :: proc(p: rl.Vector2, path: string, strict: bool, b: ^Browser, jobs: ^Jobs) {
	if os.is_dir(path) {
		if browser_scan(b, path) {
			b.selected = 0
			b.scroll = 0
		}
		return
	}
	if !is_audio_file(path) {
		jobs.status = fmt.caprintf("not an audio file: %s", os.base(path))
		return
	}
	if !strict && rl.CheckCollisionPointRec(p, browser_zone) {
		if browser_scan(b, os.dir(path)) {
			b.selected = 0
			b.scroll = 0
			for t, i in b.tracks {
				if t.path == path {
					b.selected = i
				}
			}
		}
		return
	}
	deck := deck_at(p)
	if deck < 0 {
		if strict {
			return
		}
		deck = p.x < f32(rl.GetScreenWidth()) / 2 ? 0 : 1
	}
	request_load(&engine.decks[deck], path, jobs)
}

// Call once per frame after everything else is drawn: advances a row drag,
// draws its ghost and the lit target, and drops it on release.
update_drag :: proc(b: ^Browser, jobs: ^Jobs) {
	if !drag.active {
		return
	}
	if !drag.moved && (abs(ui.mouse.x - drag.x0) > DRAG_THRESHOLD || abs(ui.mouse.y - drag.y0) > DRAG_THRESHOLD) {
		drag.moved = true
	}
	if drag.moved {
		ui.active = &drag // keep the mouse away from the widgets underneath
		if deck := deck_at(ui.mouse); deck >= 0 {
			for z in deck_zones[deck] {
				rl.DrawRectangleLinesEx(z, 2, COL_ACCENT)
			}
		}
		w := text_width(drag.name, 14) + 16
		rl.DrawRectangleRec({ui.mouse.x + 12, ui.mouse.y + 8, w, 24}, COL_PANEL2)
		rl.DrawRectangleLinesEx({ui.mouse.x + 12, ui.mouse.y + 8, w, 24}, 1, COL_ACCENT)
		label(drag.name, ui.mouse.x + 20, ui.mouse.y + 11, 14)
	}
	if !ui.down {
		if drag.moved {
			drop_at(ui.mouse, drag.path, true, b, jobs)
			ui.active = nil
		}
		drag_end()
	}
}

// Files dropped from the desktop land where the pointer is.
poll_dropped_files :: proc(b: ^Browser, jobs: ^Jobs) {
	if !rl.IsFileDropped() {
		return
	}
	files := rl.LoadDroppedFiles()
	defer rl.UnloadDroppedFiles(files)
	if files.count == 0 {
		return
	}
	path := strings.clone_from_cstring(files.paths[0], context.temp_allocator)
	drop_at(rl.GetMousePosition(), path, false, b, jobs)
}

// ---------------------------------------------------------------------------
// Confirmation dialog: loading over a playing deck, quitting while one plays
// ---------------------------------------------------------------------------

Modal_Kind :: enum {
	None,
	Load,
	Quit,
}

Modal :: struct {
	kind: Modal_Kind,
	deck: ^Deck, // Load: target deck
	path: string, // Load: track to load, owned
}

modal: Modal

modal_open_load :: proc(d: ^Deck, path: string) {
	modal_close()
	modal = {kind = .Load, deck = d, path = strings.clone(path)}
}

modal_open_quit :: proc() {
	modal_close()
	modal.kind = .Quit
}

modal_close :: proc() {
	delete(modal.path)
	modal = {}
}

// Draws the open dialog over everything and handles its keys. Returns true
// when the user confirmed; the caller acts and closes the dialog.
draw_modal :: proc() -> (confirmed: bool) {
	if modal.kind == .None {
		return false
	}
	w := f32(rl.GetScreenWidth())
	h := f32(rl.GetScreenHeight())
	rl.DrawRectangle(0, 0, i32(w), i32(h), rl.Color{0, 0, 0, 170})
	box := rl.Rectangle{w / 2 - 230, h / 2 - 84, 460, 168}
	panel(box)
	rl.DrawRectangleLinesEx(box, 1, COL_ACCENT)
	title, text, ok_text: cstring
	switch modal.kind {
	case .Load:
		name := os.base(modal.path)
		if len(name) > 44 {
			name = strings.concatenate({name[:41], "..."}, context.temp_allocator)
		}
		title = fmt.ctprintf("Deck %s is playing", DECK_LABELS[modal.deck.index])
		text = fmt.ctprintf("Load %s into it anyway?", name)
		ok_text = "LOAD"
	case .Quit:
		title = "A deck is playing"
		text = "Quit djai anyway?"
		ok_text = "QUIT"
	case .None:
	}
	label_centered(title, box.x + box.width / 2, box.y + 20, 18)
	label_centered(text, box.x + box.width / 2, box.y + 56, 14, COL_DIM)
	ok := button({box.x + 60, box.y + 104, 150, 40}, ok_text, false, "ENTER")
	cancel := button({box.x + box.width - 210, box.y + 104, 150, 40}, "CANCEL", false, "ESC")
	if ok || rl.IsKeyPressed(.ENTER) || rl.IsKeyPressed(.KP_ENTER) {
		return true
	}
	if cancel || rl.IsKeyPressed(.ESCAPE) {
		modal_close()
	}
	return false
}

DECK_LABELS := [NUM_DECKS]cstring{"1", "2"}
DECK_COLORS := [NUM_DECKS]rl.Color{{70, 160, 255, 255}, {255, 90, 70, 255}}
HOT_NAMES   := [4]cstring{"HOT 1", "HOT 2", "HOT 3", "HOT 4"}
STEM_PADS   := [MAX_LAYERS]cstring{"DRUMS+BASS", "VOCALS", "OTHER"}
HOT_KEYS    := [NUM_DECKS]cstring{"keys 1 2 3 4", "keys 7 8 9 0"}

ZOOM_MIN :: 1.5
ZOOM_MAX :: 30.0

zoom_seconds: f32 = 6 // width of the scrolling waves, shared by all decks

main :: proc() {
	// Debug flags: --screenshot=file.png renders a few frames, saves, exits;
	// --autoload loads the first two tracks, --autoplay also starts them,
	// --separate=N separates browser entry N, --nav-up goes to the parent.
	folder := "."
	screenshot := ""
	autoload := false
	autoplay := false
	separate := -1
	nav_up := false
	bpm_only := false // print BPM of every file in the folder and exit
	sync_test := false // after autoplay: sync deck 2 to deck 1, print phases
	cue_test := false // set cues on deck 1, reload into deck 2, print them
	load_test := false // load asynchronously while rendering, print the longest frame
	step_test := false // skip a bar and glide the volume on deck 1, print what happened
	modal_test := false // with --autoplay: load over the playing deck 1 to show the dialog
	scroll_test := false // scroll the browser list by hand, check that it stays and follows the selection
	drop_test := false // drop the first browser file on the deck 2 panel, print what deck 2 holds
	for arg in os.args[1:] {
		if strings.has_prefix(arg, "--screenshot=") {
			screenshot = arg[len("--screenshot="):]
		} else if arg == "--autoload" {
			autoload = true
		} else if arg == "--autoplay" {
			autoload = true
			autoplay = true
		} else if arg == "--nav-up" {
			nav_up = true
		} else if arg == "--bpm" {
			bpm_only = true
		} else if arg == "--sync" {
			sync_test = true
		} else if arg == "--cuetest" {
			cue_test = true
		} else if arg == "--loadtest" {
			load_test = true
		} else if arg == "--steptest" {
			step_test = true
		} else if arg == "--modaltest" {
			modal_test = true
		} else if arg == "--scrolltest" {
			scroll_test = true
		} else if arg == "--droptest" {
			drop_test = true
		} else if strings.has_prefix(arg, "--separate=") {
			separate, _ = strconv.parse_int(arg[len("--separate="):])
		} else {
			folder = arg
		}
	}

	rl.SetConfigFlags({.WINDOW_RESIZABLE, .MSAA_4X_HINT})
	rl.InitWindow(WINDOW_W, WINDOW_H, "djai")
	defer rl.CloseWindow()
	rl.SetTargetFPS(60)
	rl.SetExitKey(.KEY_NULL)
	ui_init_fonts()

	engine_init()
	defer engine_shutdown()

	browser: Browser
	if !browser_scan(&browser, folder) {
		browser_scan(&browser, ".")
	}
	jobs: Jobs
	if bpm_only {
		debug_beats = true
		for t in browser.tracks {
			if t.is_dir {
				continue
			}
			t0 := rl.GetTime()
			d := &engine.decks[0]
			if deck_load(d, t.path) {
				fmt.printf("BPM %7.2f  offset %.3f s  stems=%v  load %.1f s  %s\n", d.bpm, d.beat_offset, d.has_stems, rl.GetTime() - t0, t.name)
			} else {
				fmt.printf("cannot decode %s\n", t.name)
			}
		}
		return
	}
	jobs.status = "UP/DOWN select, LEFT/RIGHT load deck 1/2, ENTER opens, BACKSPACE up, F2 makes stems"
	if autoload {
		deck := 0
		for t, i in browser.tracks {
			if t.is_dir || deck >= NUM_DECKS {
				continue
			}
			browser.selected = i
			load_selected(&browser, &engine.decks[deck], &jobs)
			deck += 1
		}
		browser.selected = 0
		wait_for_loads()
		if autoplay {
			for &d in engine.decks {
				deck_toggle_play(&d)
			}
		}
	}
	if separate >= 0 && separate < len(browser.tracks) {
		browser.selected = separate
		job_request(&jobs, browser.tracks[separate].path)
	}
	if nav_up {
		browser_navigate(&browser, true)
	}
	if cue_test && engine.decks[0].frames > 0 {
		a := &engine.decks[0]
		deck_seek_seconds(a, 5)
		deck_cue(a) // stopped: sets the cue point
		deck_seek_seconds(a, 10)
		deck_hot_cue(a, 0)
		deck_seek_seconds(a, 20)
		deck_hot_cue(a, 2)
		deck_seek_seconds(a, 12.5)
		deck_set_grid(a)
		b := &engine.decks[1]
		deck_load(b, a.path)
		fmt.printf("cuetest: cue %.2f s hot %.2f %.2f %.2f %.2f s\n", b.cue / SAMPLE_RATE, b.hot_cues[0] / SAMPLE_RATE, b.hot_cues[1] / SAMPLE_RATE, b.hot_cues[2] / SAMPLE_RATE, b.hot_cues[3] / SAMPLE_RATE)
		fmt.printf("cuetest: grid %.3f s (set 12.500) bpm %.2f (deck 1 %.2f) manual %v\n", b.beat_offset, b.bpm, a.bpm, b.grid_manual)
		deck_reset_grid(a) // leave the detected grid in the sidecar
		deck_load(b, a.path)
		fmt.printf("cuetest: after reset grid %.3f s bpm %.2f manual %v\n", b.beat_offset, b.bpm, b.grid_manual)
	}
	if sync_test {
		a, b := &engine.decks[0], &engine.decks[1]
		deck_seek(b, 0.3)
		fmt.printf("before: bpm %.2f/%.2f rate %.3f phase %.3f/%.3f\n", a.bpm, b.bpm, b.rate, deck_beat_phase(a), deck_beat_phase(b))
		ok := deck_sync(b, a)
		fmt.printf("after:  ok %v rate %.4f phase %.3f/%.3f\n", ok, b.rate, deck_beat_phase(a), deck_beat_phase(b))
		// Toggle mode: stop deck 2, move it off-beat, press play: it must start in phase.
		deck_toggle_play(b)
		deck_seek(b, 0.4)
		b.sync_on = true
		deck_toggle_play(b)
		fmt.printf("toggle: playing %v phase %.3f/%.3f\n", b.playing, deck_beat_phase(a), deck_beat_phase(b))
		matched := deck_match_volume(b, a)
		fmt.printf("match:  ok %v loudness %.1f/%.1f dBFS trim %+.2f dB gain %.3f\n", matched, a.loudness_db, b.loudness_db, b.trim_db, b.trim_gain)
		// Wrong-multiple case: halve the BPM of deck 2, sync must still land near rate 1.
		deck_scale_bpm(b, 0.5)
		ok2 := deck_sync(b, a)
		fmt.printf("half:   ok %v rate %.4f bpm %.2f\n", ok2, b.rate, b.bpm)
		deck_scale_bpm(b, 2)
		deck_reset_grid(b) // the halving above must not stick in the sidecar
	}
	frame := 0
	shot_frame := separate >= 0 ? -1 : (step_test ? 200 : 120) // the glide needs more than 120 frames
	worst_frame: f32
	step_t0: f64
	step_done := false
	quit := false

	for !quit {
		// The window close button asks first while music is playing.
		if rl.WindowShouldClose() {
			if any_deck_playing() {
				modal_open_quit()
			} else {
				break
			}
		}
		free_all(context.temp_allocator)
		ui_begin_frame()
		ui_block(modal.kind != .None)
		if step_test && engine.decks[0].frames > 0 {
			d := &engine.decks[0]
			if frame == 5 {
				deck_seek_seconds(d, 30)
				_, s0 := deck_position(d)
				p0 := deck_beat_phase(d)
				deck_skip_bars(d, 1)
				_, s1 := deck_position(d)
				deck_skip_bars(d, -2)
				_, s2 := deck_position(d)
				fmt.printf("steptest: bpm %.2f bar %.3f s  fwd %+.3f s  back %+.3f s  phase %.3f -> %.3f\n", d.bpm, deck_bar_seconds(d), s1 - s0, s2 - s1, p0, deck_beat_phase(d))
				d.volume = 0.2
				for _ in 0 ..< 4 {
					deck_volume_step(d, VOLUME_STEP)
				}
				step_t0 = rl.GetTime()
				fmt.printf("steptest: volume %.2f target %.2f glide %.3f s\n", d.volume, d.vol_target, d.vol_len)
			}
			if frame > 5 && !step_done && d.vol_len == 0 {
				step_done = true
				fmt.printf("steptest: reached %.2f after %.3f s\n", d.volume, rl.GetTime() - step_t0)
				v0 := d.volume
				deck_volume_toggle(d)
				v1 := d.volume
				deck_volume_toggle(d)
				fmt.printf("steptest: toggle %.2f -> %.2f -> %.2f\n", v0, v1, d.volume)
			}
		}
		if scroll_test {
			switch frame {
			case 3:
				browser.scroll = 5 // as the wheel would
			case 5:
				fmt.printf("scrolltest: wheel scroll %d selected %d (expect 5, 0)\n", browser.scroll, browser.selected)
				browser.selected = 1 // as the DOWN key would
			case 7:
				fmt.printf("scrolltest: after select scroll %d selected %d (expect 1, 1)\n", browser.scroll, browser.selected)
			}
		}
		if drop_test {
			switch frame {
			case 3:
				for t in browser.tracks {
					if !t.is_dir {
						z := deck_zones[1][1]
						drop_at({z.x + z.width / 2, z.y + z.height / 2}, t.path, true, &browser, &jobs)
						fmt.printf("droptest: dropped %s on deck 2 panel\n", t.name)
						break
					}
				}
			case 100:
				d := &engine.decks[1]
				fmt.printf("droptest: deck 2 holds %s, loading %v, deck 1 empty %v\n", os.base(d.path), deck_is_loading(d), engine.decks[0].frames == 0)
			}
		}
		if modal_test && frame == 3 {
			for t, i in browser.tracks {
				if !t.is_dir {
					browser.selected = i
					break
				}
			}
			load_selected(&browser, &engine.decks[0], &jobs)
			fmt.printf("modaltest: kind %v deck %s path %s\n", modal.kind, modal.deck != nil ? DECK_LABELS[modal.deck.index] : "-", os.base(modal.path))
		}
		if load_test {
			if frame == 5 {
				for t in browser.tracks {
					if !t.is_dir {
						deck_load_async(&engine.decks[1], t.path)
						break
					}
				}
			}
			if frame > 5 {
				worst_frame = max(worst_frame, rl.GetFrameTime())
			}
			if frame == 119 {
				fmt.printf("loadtest: worst frame %.1f ms, deck 2 loaded %v, still loading %v\n", worst_frame * 1000, engine.decks[1].frames > 0, deck_is_loading(&engine.decks[1]))
			}
		}
		for &d in engine.decks {
			deck_follow_tempo(&d)
			deck_volume_tick(&d)
		}
		if ld, lpath, lok := poll_load_jobs(); ld != nil {
			if lok {
				jobs.status = fmt.caprintf("loaded %s%s, %.1f BPM", os.base(lpath), ld.has_stems ? " with stems" : " (no stems)", ld.bpm)
			} else {
				jobs.status = fmt.caprintf("cannot decode %s", os.base(lpath))
			}
		}
		if job_poll(&jobs) {
			browser_scan(&browser, browser.folder)
			if shot_frame < 0 {
				shot_frame = frame + 10
			}
		}

		// Keyboard and desktop drops; a dialog takes all input while it is open
		if modal.kind == .None {
			poll_dropped_files(&browser, &jobs)
			if len(browser.tracks) > 0 {
				if key_hit(.DOWN) {
					browser.selected = min(browser.selected + 1, len(browser.tracks) - 1)
				}
				if key_hit(.UP) {
					browser.selected = max(browser.selected - 1, 0)
				}
				if rl.IsKeyPressed(.ENTER) {
					browser_navigate(&browser, false)
				}
				if rl.IsKeyPressed(MAKE_STEMS_KEY) {
					if t := browser.tracks[browser.selected]; !t.is_dir && !t.has_stems {
						job_request(&jobs, t.path)
					}
				}
			}
			if rl.IsKeyPressed(.BACKSPACE) {
				browser_navigate(&browser, true)
			}
			if rl.IsKeyPressed(.EQUAL) || rl.IsKeyPressed(.KP_ADD) {
				zoom_seconds = clamp(zoom_seconds * 0.8, ZOOM_MIN, ZOOM_MAX)
			}
			if rl.IsKeyPressed(.MINUS) || rl.IsKeyPressed(.KP_SUBTRACT) {
				zoom_seconds = clamp(zoom_seconds * 1.25, ZOOM_MIN, ZOOM_MAX)
			}
			for keys, i in DECK_KEYS {
				d := &engine.decks[i]
				if rl.IsKeyPressed(keys.play) {
					deck_toggle_play(d)
				}
				if rl.IsKeyPressed(keys.cue) {
					deck_cue(d)
				}
				if rl.IsKeyPressed(keys.load) && len(browser.tracks) > 0 {
					load_selected(&browser, d, &jobs)
				}
				if key_hit(keys.back) {
					deck_skip_bars(d, -1)
				}
				if key_hit(keys.fwd) {
					deck_skip_bars(d, 1)
				}
				if key_hit(keys.vol_down) {
					deck_volume_step(d, -VOLUME_STEP)
				}
				if key_hit(keys.vol_up) {
					deck_volume_step(d, VOLUME_STEP)
				}
				if rl.IsKeyPressed(keys.vol_toggle) {
					deck_volume_toggle(d)
				}
				for k, h in keys.hot {
					if rl.IsKeyPressed(k) {
						deck_hot_cue(d, h)
					}
				}
			}
		}

		rl.BeginDrawing()
		rl.ClearBackground(COL_BG)

		w := f32(rl.GetScreenWidth())
		h := f32(rl.GetScreenHeight())
		gap: f32 = 10

		// Scrolling waves, one row per deck, playhead in the centre
		row_h: f32 = 88
		y := gap
		waves_r := rl.Rectangle{gap, y, w - 2 * gap, NUM_DECKS * (row_h + 4)}
		for i in 0 ..< NUM_DECKS {
			r := rl.Rectangle{gap, y, w - 2 * gap, row_h}
			deck_zones[i][0] = r
			if dragged, delta := scroll_wave(r, &engine.decks[i], zoom_seconds, DECK_COLORS[i]); dragged {
				_, secs := deck_position(&engine.decks[i])
				deck_seek_seconds(&engine.decks[i], secs - delta)
			}
			label(DECK_LABELS[i], r.x + 6, r.y + 4, 20, DECK_COLORS[i])
			y += row_h + 4
		}
		label_centered(fmt.ctprintf("%.1f s   wheel or + / - to zoom", zoom_seconds), w / 2, y - 2, 10, COL_DIM)
		if rl.CheckCollisionPointRec(ui.mouse, waves_r) {
			if wheel := rl.GetMouseWheelMove(); wheel != 0 {
				zoom_seconds = clamp(zoom_seconds * (wheel > 0 ? 0.8 : 1.25), ZOOM_MIN, ZOOM_MAX)
			}
		}
		y += 10

		// Controller: deck 1 | mixer | deck 2
		ctrl_h: f32 = 500
		mixer_w: f32 = 260
		deck_w := (w - 2 * gap - mixer_w - 2 * gap) / 2
		deck_zones[0][1] = {gap, y, deck_w, ctrl_h}
		deck_zones[1][1] = {gap + deck_w + gap + mixer_w + gap, y, deck_w, ctrl_h}
		draw_deck_controller(&engine.decks[0], 0, deck_zones[0][1], &jobs)
		draw_mixer({gap + deck_w + gap, y, mixer_w, ctrl_h}, &jobs)
		draw_deck_controller(&engine.decks[1], 1, deck_zones[1][1], &jobs)
		y += ctrl_h + gap

		// Browser
		browser_zone = {gap, y, w - 2 * gap, h - y - gap}
		draw_browser(&browser, &jobs, browser_zone)
		update_drag(&browser, &jobs)

		// Dialog on top, with the real mouse
		if modal.kind != .None {
			ui_block(false)
			if draw_modal() {
				switch modal.kind {
				case .Load:
					start_load(modal.deck, modal.path, &jobs)
				case .Quit:
					quit = true
				case .None:
				}
				modal_close()
			}
		}

		rl.EndDrawing()

		frame += 1
		if screenshot != "" && frame == shot_frame {
			img := rl.LoadImageFromScreen()
			rl.ExportImage(img, tcs(screenshot))
			rl.UnloadImage(img)
			break
		}
	}
}

load_selected :: proc(b: ^Browser, d: ^Deck, jobs: ^Jobs) {
	if len(b.tracks) == 0 {
		return
	}
	t := b.tracks[b.selected]
	if t.is_dir {
		browser_navigate(b, false)
		return
	}
	request_load(d, t.path, jobs)
}

// Loads path into the deck, asking first when the deck is playing so a
// wrong key or drop never cuts the music.
request_load :: proc(d: ^Deck, path: string, jobs: ^Jobs) {
	if d.playing {
		modal_open_load(d, path)
		return
	}
	start_load(d, path, jobs)
}

start_load :: proc(d: ^Deck, path: string, jobs: ^Jobs) {
	if deck_load_async(d, path) {
		jobs.status = fmt.caprintf("loading %s ...", os.base(path))
	} else {
		jobs.status = fmt.caprintf("deck %s is still loading", DECK_LABELS[d.index])
	}
}

// Deck section of the controller: header, overview, jog, tempo, sync, CUE,
// PLAY, pads.
draw_deck_controller :: proc(d: ^Deck, index: int, r: rl.Rectangle, jobs: ^Jobs) {
	panel(r)
	keys := DECK_KEYS[index]
	color := DECK_COLORS[index]
	x := r.x + 10

	// Header: number, title, time, BPM
	label(DECK_LABELS[index], x, r.y + 6, 32, d.playing ? COL_GREEN : color)
	title: cstring = d.title != nil ? d.title : "empty"
	if deck_is_loading(d) {
		title = "loading ..."
	}
	label(title, x + 36, r.y + 6, 16, deck_is_loading(d) ? COL_ACCENT : COL_TEXT)
	frac, secs := deck_position(d)
	label(format_time(secs), x + 36, r.y + 26, 18)
	label(fmt.ctprintf("/ %s", format_time(deck_length_seconds(d))), x + 92, r.y + 30, 13, COL_DIM)
	label(fmt.ctprintf("%+.1f %%", (d.rate - 1) * 100), x + 150, r.y + 30, 13, COL_DIM)
	if d.bpm > 0 {
		label(fmt.ctprintf("%.1f BPM", d.bpm * d.rate), x + 210, r.y + 28, 15, COL_TEXT)
		if button({x + 300, r.y + 27, 26, 18}, "/2") {
			deck_scale_bpm(d, 0.5)
		}
		if button({x + 330, r.y + 27, 26, 18}, "x2") {
			deck_scale_bpm(d, 2)
		}
		// SET GRID: beat 1 here; right click goes back to the detected grid
		grid_r := rl.Rectangle{x + 362, r.y + 27, 66, 18}
		if button(grid_r, "SET GRID", d.grid_manual) {
			deck_set_grid(d)
			jobs.status = fmt.caprintf("deck %s grid: beat 1 at %s, right click SET GRID = detected grid", DECK_LABELS[index], format_time(secs))
		}
		if rl.CheckCollisionPointRec(ui.mouse, grid_r) && rl.IsMouseButtonPressed(.RIGHT) {
			deck_reset_grid(d)
			jobs.status = fmt.caprintf("deck %s grid: back to detected %.1f BPM", DECK_LABELS[index], d.bpm)
		}
	}
	if d.has_stems {
		label("STEMS", x + 438, r.y + 30, 13, COL_GREEN)
	}

	// Overview strip with cue and hot cue markers
	ov := rl.Rectangle{x, r.y + 50, r.width - 20, 34}
	if clicked, at := waveform(ov, d.overview, frac, f32(d.cue / f64(max(d.frames, 1)))); clicked {
		deck_seek(d, at)
	}
	draw_hot_cues(d, ov, overview_frame_to_x, nil)

	// Jog wheel with one-bar skip buttons under it
	jog_r: f32 = 100
	jog_cx := r.x + r.width / 2 - 30
	jog(jog_cx, r.y + 96 + jog_r, jog_r, secs, d.playing)
	if button({jog_cx - 82, r.y + 302, 76, 34}, "<< BAR", false, keys.back_hint) {
		deck_skip_bars(d, -1)
	}
	if button({jog_cx + 6, r.y + 302, 76, 34}, "BAR >>", false, keys.fwd_hint) {
		deck_skip_bars(d, 1)
	}

	// Tempo fader, reset and sync at the right edge
	if button({r.x + r.width - 100, r.y + 94, 82, 22}, "RESET") {
		d.rate = 1
	}
	other := &engine.decks[(index + 1) % NUM_DECKS]
	can_sync := d.bpm > 0 && other.bpm > 0 && other.frames > 0
	if button({r.x + r.width - 100, r.y + 120, 82, 38}, "BEAT SYNC", d.sync_on, d.sync_on ? "on: follows the other deck" : (can_sync ? "off, click to lock" : "needs BPM on both")) && can_sync {
		if d.sync_on {
			d.sync_on = false
		} else if deck_sync(d, other) {
			d.sync_on = true
		} else {
			jobs.status = fmt.caprintf("cannot sync: %.1f vs %.1f BPM is outside the tempo range, try the x2 / /2 buttons", d.bpm, other.bpm * other.rate)
		}
	}
	tempo_r := rl.Rectangle{r.x + r.width - 48, r.y + 182, 30, r.height - 300}
	pitch := clamp((d.rate - 1) / TEMPO_RANGE * 0.5 + 0.5, 0, 1)
	if vslider(&d.rate, tempo_r, &pitch, "TEMPO", COL_DIM) {
		d.rate = 1 + (pitch - 0.5) * 2 * TEMPO_RANGE
	}
	label("-", tempo_r.x + 10, tempo_r.y - 16, 14, COL_DIM)
	label("+", tempo_r.x + 10, tempo_r.y + tempo_r.height + 16, 14, COL_DIM)

	// CUE and PLAY on the left, bottom
	bottom := r.y + r.height
	if round_button(r.x + 46, bottom - 120, 26, "CUE", COL_ACCENT, false) {
		deck_cue(d)
	}
	label_centered(keys.cue_hint, r.x + 46, bottom - 86, 10, COL_DIM)
	if round_button(r.x + 46, bottom - 46, 26, d.playing ? "||" : ">", COL_GREEN, d.playing) {
		deck_toggle_play(d)
	}
	label_centered(keys.play_hint, r.x + 46, bottom - 12, 10, COL_DIM)

	// Performance pads: row 1 hot cues, row 2 stem kills
	pad_w: f32 = 72
	pad_h: f32 = 44
	pads_x := r.x + 90
	row1_y := bottom - 2 * pad_h - 36
	row2_y := bottom - pad_h - 10
	label("HOT CUES  (right click = clear)", pads_x, row1_y - 14, 10, COL_DIM)
	for i in 0 ..< 4 {
		pr := rl.Rectangle{pads_x + f32(i) * (pad_w + 6), row1_y, pad_w, pad_h}
		clicked, right := pad(pr, HOT_NAMES[i], HOT_COLORS[i], d.hot_cues[i] >= 0)
		if clicked {
			deck_hot_cue(d, i)
		}
		if right {
			deck_clear_hot_cue(d, i)
		}
	}
	label(HOT_KEYS[index], pads_x + 4 * (pad_w + 6) + 6, row1_y + 16, 10, COL_DIM)
	label("STEMS  (click = kill, right click = solo)", pads_x, row2_y - 14, 10, COL_DIM)
	for k in 0 ..< MAX_LAYERS {
		pr := rl.Rectangle{pads_x + f32(k) * (pad_w + 6), row2_y, pad_w, pad_h}
		on := d.stem_gain[k] > 0
		clicked, right := pad(pr, STEM_PADS[k], COL_GREEN, on && d.has_stems, !d.has_stems)
		if clicked && d.has_stems {
			d.stem_gain[k] = on ? 0 : 1
		}
		if right && d.has_stems {
			for j in 0 ..< MAX_LAYERS {
				d.stem_gain[j] = j == k ? 1 : 0
			}
		}
	}
	pr := rl.Rectangle{pads_x + 3 * (pad_w + 6), row2_y, pad_w, pad_h}
	if clicked, _ := pad(pr, "ALL ON", COL_GREEN, false, !d.has_stems); clicked {
		d.stem_gain = {1, 1, 1}
	}
}

// Centre mixer: per channel HI / MID / LOW knobs and fader, master, crossfader.
draw_mixer :: proc(r: rl.Rectangle, jobs: ^Jobs) {
	panel(r)
	names := [3]cstring{"HI", "MID", "LOW"}
	knob_y0 := r.y + 128
	knob_dy: f32 = 64
	for i in 0 ..< NUM_DECKS {
		d := &engine.decks[i]
		other := &engine.decks[(i + 1) % NUM_DECKS]
		cx := i == 0 ? r.x + 60 : r.x + r.width - 60
		// Gain (trim) knob with MATCH button
		gain_v := (d.trim_db + TRIM_RANGE_DB) / (2 * TRIM_RANGE_DB)
		if knob(&d.trim_db, cx, r.y + 44, 22, &gain_v, "GAIN", fmt.ctprintf("%+.0f", d.trim_db)) {
			deck_set_trim(d, gain_v * 2 * TRIM_RANGE_DB - TRIM_RANGE_DB)
		}
		if rl.Vector2Distance(ui.mouse, {cx, r.y + 44}) <= 26 && rl.IsMouseButtonPressed(.RIGHT) {
			deck_set_trim(d, 0)
		}
		can_match := d.loudness_db > LOUDNESS_UNKNOWN && other.loudness_db > LOUDNESS_UNKNOWN
		if button({cx - 30, r.y + 80, 60, 18}, "MATCH") && can_match {
			deck_match_volume(d, other)
			jobs.status = fmt.caprintf("deck %s gain %+.1f dB: %.1f dBFS matched to %.1f dBFS", DECK_LABELS[i], d.trim_db, d.loudness_db, other.loudness_db)
		}
		for b in 0 ..< 3 {
			band := 2 - b // HI on top
			cy := knob_y0 + f32(b) * knob_dy
			db := knob_to_db(d.eq_knob[band])
			if knob(&d.eq_knob[band], cx, cy, 24, &d.eq_knob[band], names[b], fmt.ctprintf("%+.0f", db)) {
				deck_update_eq(d, band)
			}
			if rl.Vector2Distance(ui.mouse, {cx, cy}) <= 28 && rl.IsMouseButtonPressed(.RIGHT) {
				d.eq_knob[band] = 0.5
				deck_update_eq(d, band)
			}
		}
		fader_r := rl.Rectangle{cx - 15, knob_y0 + 3 * knob_dy - 14, 30, 130}
		if vslider(&d.volume, fader_r, &d.volume, fmt.ctprintf("%s  %.0f %%", DECK_LABELS[i], d.volume * 100)) {
			deck_volume_hold(d) // hand on the fader wins over a key glide
		}
		if d.vol_len > 0 {
			ty := fader_r.y + fader_r.height * (1 - d.vol_target)
			rl.DrawRectangleRec({fader_r.x, ty - 1, fader_r.width, 2}, COL_ACCENT)
		}
	}
	label("EQ", r.x + r.width / 2 - 10, knob_y0 + knob_dy - 8, 14, COL_DIM)
	label_centered("right click = reset", r.x + r.width / 2, knob_y0 + knob_dy + 8, 10, COL_DIM)
	label_centered("MATCH = same loudness", r.x + r.width / 2, r.y + 108, 10, COL_DIM)
	hint_y := knob_y0 + 3 * knob_dy + 10
	label_centered("VOLUME KEYS", r.x + r.width / 2, hint_y, 10, COL_DIM)
	for i in 0 ..< NUM_DECKS {
		label_centered(fmt.ctprintf("deck %s:  %s", DECK_LABELS[i], DECK_KEYS[i].vol_hint), r.x + r.width / 2, hint_y + 16 + f32(i) * 14, 10, COL_DIM)
	}
	label_centered(fmt.ctprintf("-/+ %.0f %%, glides 1 bar", VOLUME_STEP * 100), r.x + r.width / 2, hint_y + 50, 10, COL_DIM)
	label_centered("D / J = cut, or full from 0", r.x + r.width / 2, hint_y + 64, 10, COL_DIM)
	knob(&engine.master, r.x + r.width / 2, r.y + 44, 22, &engine.master, "MASTER")

	xf := rl.Rectangle{r.x + 30, r.y + r.height - 50, r.width - 60, 28}
	hslider(&engine.crossfader, xf, &engine.crossfader, "CROSSFADER", true)
}

draw_browser :: proc(b: ^Browser, jobs: ^Jobs, r: rl.Rectangle) {
	panel(r)
	x, y := r.x + 10, r.y + 8
	folder := b.folder
	if len(folder) > 60 {
		folder = strings.concatenate({"...", folder[len(folder) - 57:]}, context.temp_allocator)
	}
	label(fmt.ctprintf("FOLDER  %s", folder), x, y, 14, COL_DIM)
	label(jobs.status, r.x + r.width - 220 - text_width(jobs.status, 14), y, 14, jobs.running ? COL_ACCENT : COL_TEXT)
	y += 24

	row_h: f32 = 22
	list_r := rl.Rectangle{x, y, r.width - 220, r.y + r.height - y - 8}
	rl.DrawRectangleRec(list_r, rl.Color{12, 12, 15, 255})
	visible := max(int(list_r.height / row_h), 1)
	if rl.CheckCollisionPointRec(ui.mouse, list_r) {
		wheel := rl.GetMouseWheelMove()
		if wheel != 0 {
			b.scroll = clamp(b.scroll - int(wheel * 3 * wheel_accel()), 0, max(len(b.tracks) - visible, 0))
		}
	}
	// Keep a changed selection in view; a wheel-scrolled view stays put.
	if b.selected != b.shown {
		b.shown = b.selected
		if b.selected < b.scroll {
			b.scroll = b.selected
		}
		if b.selected >= b.scroll + visible {
			b.scroll = b.selected - visible + 1
		}
	}
	b.scroll = clamp(b.scroll, 0, max(len(b.tracks) - visible, 0))
	if len(b.tracks) == 0 {
		label("empty folder, BACKSPACE goes up", x + 8, y + 8, 16, COL_DIM)
	}
	enter := -1
	for i := b.scroll; i < len(b.tracks) && i < b.scroll + visible; i += 1 {
		t := b.tracks[i]
		row := rl.Rectangle{list_r.x, list_r.y + f32(i - b.scroll) * row_h, list_r.width, row_h}
		if i == b.selected {
			rl.DrawRectangleRec(row, COL_PANEL2)
		}
		stems_r := rl.Rectangle{row.x + row.width - 120, row.y, 118, row_h}
		over_stems := !t.is_dir && rl.CheckCollisionPointRec(ui.mouse, stems_r)
		if rl.CheckCollisionPointRec(ui.mouse, row) && ui.pressed && !over_stems {
			now := rl.GetTime()
			if t.is_dir && b.last_row == i && now - b.last_click < 0.4 {
				enter = i
			}
			b.selected = i
			b.last_row = i
			b.last_click = now
			if !t.is_dir {
				drag_begin(t) // becomes a drag once the mouse moves
			}
		}
		if t.is_dir {
			label(fmt.ctprintf("%s/", t.name), row.x + 8, row.y + 3, 16, COL_ACCENT)
			continue
		}
		label(t.name, row.x + 8, row.y + 3, 16)
		// Stems status, clickable when they can be made
		switch {
		case t.has_stems:
			label("stems", stems_r.x + 60, row.y + 4, 14, COL_GREEN)
		case jobs.running && jobs.track == t.path:
			label("working...", stems_r.x + 40, row.y + 4, 14, COL_ACCENT)
		case job_queued(jobs, t.path):
			label("queued", stems_r.x + 56, row.y + 4, 14, COL_DIM)
		case:
			if over_stems {
				rl.DrawRectangleRec(stems_r, COL_PANEL2)
			}
			label("make stems", stems_r.x + 30, row.y + 4, 14, over_stems ? COL_TEXT : COL_ACCENT)
			if over_stems && ui.pressed {
				job_request(jobs, t.path)
			}
		}
	}
	if enter >= 0 {
		b.selected = enter
		browser_navigate(b, false)
	}

	// Actions
	bx := list_r.x + list_r.width + 10
	by := y
	if len(b.tracks) > 0 && !b.tracks[b.selected].is_dir {
		for i in 0 ..< NUM_DECKS {
			if button({bx, by, 190, 36}, fmt.ctprintf("LOAD DECK %s", DECK_LABELS[i]), false, i == 0 ? "key LEFT" : "key RIGHT") {
				load_selected(b, &engine.decks[i], jobs)
			}
			by += 44
		}
	}
	if button({bx, by, 92, 28}, "UP") {
		browser_navigate(b, true)
	}
	if button({bx + 98, by, 92, 28}, "HOME") {
		if home, err := os.user_home_dir(context.temp_allocator); err == nil {
			if browser_scan(b, home) {
				b.selected = 0
				b.scroll = 0
			}
		}
	}
	by += 34
	if button({bx, by, 190, 28}, "RESCAN") {
		browser_scan(b, b.folder)
	}
	label_centered("ENTER opens, BACKSPACE up", bx + 95, by + 34, 10, COL_DIM)
	label_centered("LEFT / RIGHT load deck 1 / 2", bx + 95, by + 48, 10, COL_DIM)
	label_centered("F2 or click 'make stems' = Demucs", bx + 95, by + 62, 10, COL_DIM)
	label_centered("drag a row or a file onto a deck", bx + 95, by + 76, 10, COL_DIM)
}

// Debug flows need the tracks in place before they continue.
wait_for_loads :: proc() {
	for len(load_jobs) > 0 {
		poll_load_jobs()
		time.sleep(5 * time.Millisecond)
	}
}
