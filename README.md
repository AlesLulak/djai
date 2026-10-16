# stems

Command-line stem separator written in Odin. Splits a track into three
stereo WAV stems: `drums_bass.wav`, `vocals.wav`, `other.wav`. Two engines:

| Engine             | What it is                                                     | Vocal quality                     | Speed (3 to 4 min track, 14-core CPU) |
|--------------------|----------------------------------------------------------------|-----------------------------------|---------------------------------------|
| `demucs` (default) | Runs Meta's Demucs (neural) through `uvx`, repacks its 4 stems | Good                              | 1.5 to 2 min on CPU, seconds on a GPU |
| `dsp`              | Classical DSP inside this program, no dependencies             | Poor: vocal SDR about -5 to -7 dB | 30 to 40 s                            |

The classical engine separates drums and bass well. Vocals are its weak
point: measured against Demucs output as reference on two DNB tracks, the
vocal stem carried less vocal than leakage (SIR 0.5 and 5 dB) and only 28 to
36 percent of the vocal energy. That is the ceiling of spectral masking
without a learned model. Use `-engine=dsp` only when uv is unavailable or
speed matters more than vocals.

## Requirements

- Odin (pinned in `.tool-versions`, install with `asdf install`)
- A C compiler (`cc`) to build miniaudio once
- For the default engine: [uv](https://docs.astral.sh/uv/). `uvx` is tried on
  PATH, then `~/.local/bin/uvx` (an asdf shim fails with exit 126 and is
  skipped); `-uvx=/path/to/uvx` overrides. First run downloads PyTorch and
  the model (several GB) into the uv cache.

## Build

```sh
asdf install                                                 # Odin dev-2026-10
sh "$(odin root)/vendor/miniaudio/src/build_miniaudio.sh"   # once per Odin install
odin build . -o:speed -out:stems
```

On Windows the miniaudio library ships with the compiler, skip the second
step and build with `odin build . -o:speed -out:stems.exe`.

## Run

```sh
./stems track.mp3                        # Demucs, writes ./track_stems/
./stems -engine=dsp track.flac out/      # classical engine, same three files
./stems -engine=dsp -center=0.3 x.wav    # tune the classical engine
./stems                                  # prints usage and every option with its default
```

Input: anything miniaudio decodes (MP3, FLAC, WAV, Ogg Vorbis). Output: 16-bit
stereo WAV at the input sample rate. All three stems get one common gain so
that nothing clips and they still sum to the input (times that gain). The
`demucs` engine writes Demucs' temporary files under `<out>/.demucs` and
removes them afterwards.

## How the dsp engine works

Everything is STFT masking; each stage splits a signal into two parts that
sum exactly, so the final stems sum to the input.

1. **Drums** (`dsp.odin`, `hpss_weight`): HPSS on a 1024-point STFT. Median
   filter along time gives the harmonic estimate H, along frequency the
   percussive estimate P. A bin is drums with weight 0 below P/H = 1.2 and
   1 above 3.0 (Driedger 2014 margin). Without the margin every frame that
   holds a drum hit also drags the vocal bins into the drums; in DNB that is
   most frames.
2. **Stationary** (optional, `-stat=true`): same HPSS with an 8192-point
   window to pull out pads and sustained synths first. Off by default: it
   also removes held vocal notes, and measured no gain.
3. **Centre mask** (`center_mask`): on the non-drum part, per bin coherence
   `2 Re(L conj R) / (|L|^2 + |R|^2)`. A mono centred source scores 1,
   decorrelated stereo scores low. Linear ramp from `-center` (0.5) to 1,
   limited to `-vlow`..`-vhigh` (150 Hz to 16 kHz).
4. **REPET** (`beat_spectrum`, `repet_period`, `repet_background_weight`):
   loop-based music repeats bar after bar, the lead vocal does not. The loop
   period comes from the beat spectrum of the full mix (sum over bins of the
   autocorrelation of the squared magnitude), chosen between `-repet-min` and
   `-repet-max` seconds (1 to 8) by the best mean over its multiples, refined
   to a fraction of a frame. The repeating model is the per-bin median over
   the same beat phase in the `-repet-k` (10) nearest loops on each side.
   Background weight `min(model / mix, 1)`, foreground is the rest.
   Vocal mask = centre mask times foreground weight.
5. **Bass**: zero-phase Butterworth low-pass below `-bass` Hz (150) on the
   non-vocal remainder, added to the drums. `other` is what is left.

`fft.odin` is a plain radix-2 FFT; the Odin core library has none.

## Evaluating

`stems` was tuned against Demucs output used as reference. To repeat:

```sh
uvx --python 3.12 --with numpy --with soundfile demucs -n htdemucs -d cpu -o ref track.wav
./stems track.wav out
uv run --with numpy,scipy python eval_stems.py ref/htdemucs/track out
```

where `eval_stems.py` projects each estimated stem onto the three reference
stems and prints SDR, SIR and SAR plus the share of reference vocal energy
each stem carries. Results on two DNB tracks (Koven - In The Echo, ATC -
Around The World bootleg), vocal stem of the dsp engine:

| Variant                                     | SDR (dB)    | SIR (dB)    | vocal energy in vocals stem |
|---------------------------------------------|-------------|-------------|-----------------------------|
| centre mask only                            | -7.6 / -7.9 | -1.6 / -1.0 | 60 % / 51 %                 |
| centre mask + REPET (default)               | -7.0 / -4.7 |  0.5 / 5.0  | 36 % / 28 %                 |
| + stationary stage                          | -7.2 / -5.6 |  1.4 / 5.3  | 33 % / 23 %                 |
| REPET only                                  | -12.9 / -6.1| -11.6 / -1.8| 48 % / 53 %                 |

Synthetic sanity test (55 Hz sine, centred 440 Hz tone, 660 Hz tone with a
2-radian L/R phase offset, 2 kHz clicks):

```sh
L='0.4*sin(2*PI*55*t) + 0.3*sin(2*PI*440*t) + 0.3*sin(2*PI*660*t) + 0.8*lt(mod(t,0.35),0.004)*sin(2*PI*2000*t)'
R='0.4*sin(2*PI*55*t) + 0.3*sin(2*PI*440*t) + 0.3*sin(2*PI*660*t+2.0) + 0.8*lt(mod(t,0.35),0.004)*sin(2*PI*2000*t)'
ffmpeg -f lavfi -i "aevalsrc=exprs='$L|$R':s=44100:d=8" test.wav
./stems test.wav out
```

Expected: 440 Hz in `vocals` about 19 dB above its level in `other`, 660 Hz
in `other` about 23 dB above its level in `vocals`, 55 Hz and clicks in
`drums_bass`, reconstruction residual below -80 dB RMS.

## djai: the player

`dj/` holds a two-deck player with a layout modelled on a DDJ-FLX2. On top,
one scrolling wave per deck in the Virtual DJ style: the playhead stays in
the centre, the wave moves, bass opaque in the deck colour, drum hits as
bright white spikes on top (the drums+bass stem above 150 Hz, or low-band
transients when a track has no stems), other lighter, vocals transparent,
beat ticks at the edges with bars taller. The wave bodies are drawn into an
off-screen texture at twice the screen resolution and scaled down with
bilinear filtering, and each column reads the envelope interpolated
between analysis bins, so edges stay smooth at every zoom. Mouse wheel
over the waves or `+` / `-` zooms both at once (1.5 to 30 s across).
Below, the controller:
per deck a header (title, time, tempo, BPM), a small overview strip with
cue and hot cue markers, jog wheel, TEMPO fader with RESET, BEAT SYNC, CUE
and PLAY, eight pads (four hot cues, three stem kills, all on); a centre
mixer with GAIN knob and MATCH button, HI / MID / LOW knobs, channel
faders, MASTER and crossfader; and a track browser at the bottom.

GAIN is a -12 to +12 dB trim per deck. Loudness of every track is measured
at load (90th percentile of the per-second RMS, so the drops count, not
the intros). MATCH sets the trim so the deck plays as loud as the other
deck; the status line shows both loudness values. All knobs and sliders
also respond to the mouse wheel while hovered: 2 percent of the range per
notch when scrolling slowly, accelerating up to 8 times that when notches
come faster than four per second, back to slow after a pause.

BPM and beat grid are detected at load: onset envelope from log-energy flux
in a low and a mid band, autocorrelation candidates (plus their halves and
doubles), each refined by a comb search over period and phase, scored by
mean onset strength at the beat positions, 110 to 190 BPM preferred. Both
test DNB tracks come out at 174.0. BEAT SYNC is a toggle: switching it on
matches the deck tempo to the other deck and shifts its position so the
beats line up; while it stays on the tempo keeps following the other deck,
and every PLAY starts the deck on the nearest beat of the other one. Phase
is only corrected at play start, never mid-play (no downbeat detection, so
bars may be off by a beat or two). When detection picked a
wrong multiple (half, double, 3:2), sync uses the multiple closest to the
fader centre; if even that is outside the -8 to +8 percent range it refuses
and says so in the status line. The `/2` and `x2` buttons next to the BPM
correct a wrong tempo by hand, SET GRID makes the current position beat 1
of a bar when the grid sits in the wrong place (right click it to go back
to the detected grid). A hand-set tempo or grid is saved in the track's
`.cues` sidecar and restored on the next load.

```sh
odin build dj -o:speed -out:djai
./djai ~/Music/dnb          # folder to browse; default is the current directory
```

Loading a track picks up `<track>_stems/` next to it when the three stem
files exist (made by `./stems`), so the stem pads work; otherwise the plain
file plays and the stem pads are greyed out. Every browser row shows
`stems` (green) or `make stems` (orange): click `make stems` to run `stems`
(found next to `djai`, else on PATH) in the background; further clicks
queue up and run one after another. Load the track again when the status
line says the stems are ready.

The browser is a file browser: folders first (orange, `..` goes up), then
audio files, stem folders hidden. `UP` / `DOWN` select, `ENTER` or a double
click opens a folder, `BACKSPACE` goes up, `LEFT` / `RIGHT` load the
selected track into deck 1 / 2, `F2` makes stems for it, HOME jumps to the
home directory. A row can also be dragged onto a deck (its wave row or its
controller panel) to load it there, and a file dropped from the desktop
onto a deck loads the same way (outside a deck, the nearer half of the
window decides; dropped on the browser, the browser opens the file's
folder; a dropped folder opens in the browser). Loading into a deck that
is playing opens a dialog (LOAD or CANCEL, `ENTER` / `ESC`), so a wrong
key or drop never cuts the music; closing the window while a deck plays
asks the same way.

Deck keys: `Q` / `P` play-pause, `W` / `O` cue, `1 2 3 4` / `7 8 9 0` hot
cues 1 to 4, `Z` / `X` and `N` / `M` skip one bar (four beats of the track's
grid, so the beat phase is kept) back / forward, `A` / `S` and `K` / `L`
move the channel fader down / up by 10 percent, `+` / `-` zoom the waves.
A fader key does not jump: the fader glides to the new target over one bar
at the current tempo, counted from the last press, so four quick presses
from 20 percent reach 60 percent one bar after the fourth. The target shows
as an orange mark on the fader; dragging the fader cancels the glide. `D` /
`J` toggle the fader at once: any level drops to 0, 0 jumps to full, so a
double press always ends at full. Keys
repeat while held. Hot cues are red, orange, blue and
purple, drawn as numbered markers on the overview and the scrolling waves
and as pad colours. Mouse: click the overview to seek, drag the scrolling wave left or right to
scrub, drag knobs vertically, right click a knob to reset it, right click a
hot cue pad to clear it, right click a stem pad to solo it.

Cue point and hot cues are saved per track in `<track>.cues` next to the
file (plain text, positions in frames) and restored on load.

CUE works like a CDJ: stopped, it sets the cue point at the current position;
playing, it jumps back to the cue point and stops. Tempo range is -8 to +8
percent, pitch follows tempo (no key lock).

Text is drawn with DejaVu Sans embedded in the binary (`dj/assets/`, licence
next to it), two atlases so small labels and big numbers stay sharp.

Audio: raylib's audio stream (miniaudio underneath) at 44.1 kHz, every track
is decoded to stereo float in RAM at load. Decoding and analysis run on a
worker thread, the deck shows "loading ..." meanwhile and the swap into the
deck takes microseconds under the audio lock, so the other deck keeps
playing and the UI keeps moving (a 4-minute track with stems takes
about 130 MB). Decoding supports WAV, MP3, OGG and FLAC.

Debug flags: `--autoload` loads the first two tracks, `--autoplay` also
starts them, `--sync` then syncs deck 2 to deck 1 and prints the phases,
`--separate=N` runs separation on browser entry N at start, `--nav-up`
opens the parent folder at start, `--bpm` prints BPM, offset and tempo
candidates for every file in the folder and exits, `--screenshot=file.png`
saves the window after two seconds (or after the separation finishes) and
exits.
