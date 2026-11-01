# Live-playback UI research (from memory, no web lookup; uncertain items flagged)

## QLab (Figure 53)
- Hierarchy: cue list (rows) on top, inspector below, workspace toolbar. Go button is large, top-left; Space = GO, Esc = panic (stop all), Esc twice hard-stops.
- Armed/live: a "playhead" bar marks the next cue; running cues show a green/colored progress in the row; a cue's armed/disarmed state is a toggle (disarmed cues are greyed and will not fire). Broken cues show red/orange.
- Audio cues: waveform in the Time and Loops tab with start/end sliders and fade handles; per-cue level matrix. Pre-wait/post-wait and auto-continue/follow.
- Safety: GO is separated from selection (selecting does not fire); a workspace can be locked in settings; "Lock" of GO for a short interval exists (I believe a configurable minimum GO delay, roughly 0.25 s; unsure of exact name).
- Lesson: playhead-vs-selection separation, space=GO, esc=panic, disarm per cue.

## Ableton Live (Session view)
- Clip grid; clips launch on click of the triangle, with launch quantization. Clips pulse green while playing, blink when queued. Stop buttons per track. Track "arm" is for recording, not a playback safety.
- Weakness for church use: one click launches; easy to fire accidentally. Warp/analysis overhead. Strong: queued/blinking state shows pending action; clip colors are user-set.

## Logic Pro
- Timeline-centric, not cue-based. Transport bar centered at top (play, stop, record, cycle) with big time display (SMPTE/bars). Space toggles play. Large clock readout is the useful idea. Not designed for live trigger; MainStage is Apple's live product (patches/concerts, full-screen layout of controls) but I have limited detail.

## Farrago (Rogue Amoeba)
- Soundboard of colored tiles, each with a waveform, play/loop/hold controls; keyboard shortcut assignable per tile; sets/pages. Per-tile start/end, fade, and a master output device selection. Simple and quick; tiles are click-to-fire (and have a "Lock" or a Stop All; unsure of precise lock feature). Good: color-coding, per-tile playback options, single output routing.

## SoundSource (Rogue Amoeba)
- Menu-bar per-app/per-device volume, EQ, and routing. Lesson: output device selection exposed per source; compact menu-bar presence. Not a player. Not relevant to show-time layout other than routing UX.

## PlaybackPro (Pro Tools-like playback tool for live use)
- I know less here. Playlist/set-list oriented with large play, next/previous song, simple monitor of the current item and countdown. Lesson (moderate confidence): setlist order and a prominent current/next area beat a grid for ordered services.

## MultiTracks Playback
- Setlist on the left, big transport and a stems mixer in the main area, click/cues; pads and key changes. Ordered setlist with the current song highlighted; large time and section markers on the waveform. Detail beyond that is uncertain.

## ProPresenter audio bin
- Playlist-ish bin of audio items, click to play, small transport, volume. Easy accidental fire; little armed concept. Counter-example mostly.

## Cross-cutting takeaways
1. Separate selection from firing (QLab). Selection never makes sound.
2. One universal GO and one universal panic (Space / Esc).
3. Two states for the next cue: ARMED (will fire on GO) vs not; running cue is clearly distinct (color + motion).
4. Big monospaced remaining-time clock (Logic's transport clock idea).
5. Waveform with end marker and fade region visible on the live cue only; no editing at show time.
6. Color reserved for status: green running, amber armed, red warning/panic, blue/cyan cue-output only.
7. Ordered list beats a grid for a service run; grid pages add accidental-click surface.
8. Dark booth: dark UI, low-chroma, large text, no bright whites; optional red-shifted night mode.
