# Cantor: design

Cantor is a native macOS playback app for the person running choir and special-music tracks from the mixing console during a live service. It is an ordered cue list with a two-step arm and go, not a clip launcher.

## Critique of the four proposals

| Conflict | Resolution |
| --- | --- |
| A wants engines always running to avoid clicks. D wants the house engine stopped unless armed. | D wins. A stopped engine cannot emit. ARM starts the engine with the kernel producing exact zeros. GO opens with a 5 ms ramp, so there is no click. |
| B targets -18 LUFS, D targets -16. | -18 LUFS, changeable in Settings. Choir tracks have dynamics and the console has headroom to make up. Capped at -1 dBTP. |
| B wants GRDB/SQLite. | Atomic JSON files with rolling backups. A show app should have no third-party dependencies, and the data set is thousands of rows at most. |
| B's tiered hashing vs simplicity. | One content ID: SHA-256 of the audio payload (tags stripped for MP3), cached by path, size and mtime. Duplicates collapse into one track with several paths, so cue points survive. Tiering saved little on an SSD. |
| D's aggressive decode at ARM vs A's preload. | Decode every matched cue into RAM on Load Service. ARM never touches disk, so a Drive stall cannot delay or cut a cue. |
| D resamples at load vs letting the graph do it. | Keep native-rate buffers and let the engine's mixer convert. Marker frames stay simple and no resampler is written. |
| A's manual end nudges vs D's fixed end marker. | Markers are saved per track. `[` and `]` move the end for this run only and are never persisted in show mode. |
| D refuses matching house and cue devices. | Kept, including the same device on different channels. It is the only rule that makes "never the house" verifiable. |
| Should a failed pre-service check block the show? | No. Issues are advisory, because the operator may have no alternative. A specific cue that cannot play (no file, not in RAM) refuses to arm. |

## Architecture

```
Cantor (app target: SwiftUI + AppKit)
  AppModel, Views, KeyRouter
CantorCore (Swift package: all logic, tested without hardware)
  Playback/   ShowStateMachine, GoGuard, FadeCurve, PlaybackKernel
  Audio/      OutputEngine, HouseBus, CueBus, AudioDevices, PCMDecoder, LoudnessMeter, TrackAnalyzer
  Library/    LibraryStore, FolderScanner, FolderWatcher, ContentHasher, FileLocality, Materializer
  Planning/   PCOClient, ServiceStore, PlaybackDetector
  Matching/   TitleNormalizer, StringSimilarity, Matcher, LLMTiebreaker
  Show/       ShowController, PreServiceCheck, RunLog
  System/     Keychain, SleepGuard, SystemSoundGuard, PowerStatus
```

Audio path:

```
House:  PlaybackKernel -> AVAudioSourceNode -> mainMixer -> output (device UID + channel map)
Cue:    PlaybackKernel -> AVAudioSourceNode -> mainMixer -> output (a different device UID)
```

These are two separate `AVAudioEngine` instances with no shared nodes. `HouseBus` is only reachable through `ShowController`. Audition code only receives a `CueBus`, so no code path exists from the audition feature to the house device.

The kernel is a plain Swift class with an SPSC command ring and atomics. It does no allocation or locking while rendering. Because it has no Core Audio dependency, fade timing is unit-tested by rendering it offline.

## Data model

Stored in `~/Library/Application Support/Cantor/`: `library.json`, `aliases.json`, `services/<planID>.json`, `waveforms/<trackID>.peaks`, `runlog.jsonl`, plus rolling `.bak` copies.

- **Track**: id, contentID, files (path, locality), title, durationSec, sampleRate, channels, startSec, endSec?, suggestedEndSec?, fadeOutSec (3), fadeInSec (0), trimDb, integratedLUFS?, truePeakDb?, markers, key, notes, tags, pcoSongIDs, playCount, lastPlayed.
- **ServicePlan**: PCO plan id, serviceType, title, dates, times, syncedAt, items.
- **ServiceCue**: PCO item id or manual id, position, title, itemType, notes, arrangement, song id, lengthSec, needsPlayback, candidates, trackID (confirmed only), changedSinceConfirm.
- **AliasMemory**: PCO song id or normalized title to confirmed contentID.

## Show state machine

```
idle --arm--> armed --go--> live --hold--> held --go--> live
                |            |--fade---> fading --done--> idle
                |            |--panic--> panicking --done--> idle
                |--disarm--> idle        (held and fading also accept panic)
any active state --deviceLost--> faulted --acknowledge--> idle
```

## Safety rules

1. Only `go` from `armed` or `held` makes the house audible. `go` from anything else is a no-op.
2. Selection never plays. Clicks, double-clicks, Return, and drag and drop have no audio effect anywhere in the app.
3. The app launches idle. It never auto-arms, never auto-advances, and never auto-resumes after a device change or wake.
4. `go` needs a cue armed for at least 300 ms, and key repeats are ignored. Arm and Go are different keys and different buttons.
5. House transport needs Show Mode (Cmd-L). In Show Mode, library and plan editing are off, the sidebar stays closed and the window cannot be closed. Show Mode cannot be left and the app cannot quit silently while a cue is armed or live.
6. Esc fades everything (1.5 s). Esc twice within 1 s stops hard. This works in every view and whether or not Show Mode is on.
7. House device loss during playback stops immediately, retains position, and shows a red fault. Cantor never rebinds to another device by itself.
8. House and cue must be different devices. Audition is unavailable until a cue device is set.
9. Transport keys act only when aimed at the main window with no sheet, dialog or text field in focus. Typing in Settings can never arm or start a cue. Transport menu items show their key in the title instead of being menu shortcuts, because a bare-key menu shortcut would fire from a text field.
10. Show plays what was last saved: edits to a loaded service apply as soon as no cue is engaged.
11. If the Cantor window is not key while armed or live, the state bar says KEYS NOT FOCUSED.
12. Cue-to-house level: static gain only, no limiter, no gain change while playing.

## Keyboard (Show Mode)

| Key | Action |
| --- | --- |
| Up / Down | Move the next-cue pointer (only when not live) |
| A | Arm the next cue |
| Space | GO |
| F | End of song: fade with the track's saved fade |
| P | Hold (GO resumes) |
| M | Jump to next marker while armed or held; Shift-M previous |
| `[` / `]` | Move the end point -1 s / +1 s for this run |
| H | Audition on the cue output (toggle): the pointed cue, or the next one while a cue is engaged |
| Return | Acknowledge a fault |
| D | Disarm |
| Esc | Panic fade; twice for hard stop |

Stream Deck works by sending these keystrokes. MIDI is deferred (see NEXT_STEPS.md).

## Screens

- **Show**: full-width state bar (word, icon and color: IDLE, ARMED, LIVE, HOLD, FADING, PANIC, FAULT). Cue list at left. At right: current cue title, large waveform with playhead, start and end markers and fade zone, remaining time in large SF Mono, next cue, house and cue meters. Key legend along the bottom.
- **Service**: sidebar of upcoming plans. Table of items with Needs, Match, Confidence and State. Inspector shows candidates with the reason, preview on the cue output, Confirm, Choose Other, Not Needed. Load Service builds the cue list and starts the decode.
- **Library**: sidebar (All, tags, Needs Attention, Not Downloaded, Duplicates). Sortable table. Inspector with waveform, start, end, fade, trim, markers, key, notes, tags, file paths.
- **Check**: pre-service checklist grouped by Blocking, Warning and OK, each row saying what to do.
- **Settings**: Outputs, Planning Center, AI Matching, Folders, Playback.

Dark by default with an adaptive light appearance. Color is used only for state.

## Planning Center and AI flow

1. Fetch service types, then future plans, then items (`include=song,arrangement`) and plan times. Attachments are fetched for playback candidates only. Requests are spaced 150 ms apart, 429s honor Retry-After, and pagination follows `links.next`.
2. Detect needs-playback by item type and keywords, with an operator override remembered per song.
3. Match each cue: remembered aliases first (0.98), PCO attachment filename, then a string-similarity blend (token Jaccard, Jaro-Winkler, normalized Levenshtein) with a duration check.
4. On request, items in the ambiguous band (top 0.45 to 0.85, or a margin under 0.08) go to Claude in one batch: item titles, arrangement names, candidate filenames and durations only. No paths, no notes, no audio. The call runs the operator's installed Claude Code headlessly, using its signed-in Claude account, with no tools, settings or MCP servers. The result blends 0.6 string, 0.4 Claude.
5. Everything needs operator confirmation. Nothing is auto-confirmed, at any confidence.

## New files

1. FSEvents triggers a rescan. Each scanned file carries its added-to-folder date. A track created by the scan counts as new when one of its files arrived after Cantor started watching that folder (`AppSettings.watchedSince`, stamped when a folder is first seen and cleared when it is removed). So a launch catches files that arrived while the app was closed, and adding a folder does not flood the inbox. Another copy of audio already in the library is not new.
2. New tracks go into `new-files.json`, so they survive quitting.
3. While no cue is armed or playing, waiting files go to Claude in batches of 25: filename, the two folders above it, duration, embedded tags, category names and upcoming unmatched item titles. Claude returns a title, one category, whether it is a playback at all, an optional item id from the list, a confidence and a reason. Ids it was not given are ignored. If Claude is off, signed out or fails, the category is guessed from keywords and the item from the name matcher at 0.75 or above, and the pop-up says why.
4. The pop-up shows only when no service is loaded, the show is idle, Show Mode is off, no preview is playing and nothing is loading. Accept writes the title and category tag, confirms the service item if one is chosen and still empty, and can copy the file to `~/Music/Cantor`.
6. Everything is snapshotted to disk. The Show view reads only snapshots and RAM. A resync that changes a confirmed item flags it rather than dropping it.

## Failure handling

| Failure | Behavior |
| --- | --- |
| Drive file not downloaded | Flagged in Library and Check. Make Local copies it to `~/Music/Cantor` and proves the file decodes. |
| Internet drops | Nothing in Show depends on it. Check displays sync age. |
| House interface unplugged | Instant stop, FAULT with the reason, position kept. Re-arm is manual and shows where it will start. Arm then Disarm clears it to start from the top. |
| Cue interface unplugged | Audition stops. Show continues. |
| Sample-rate change | Treated as device loss. |
| Sleep | Power assertions while a service is loaded. Wake always returns idle. Check warns about battery power and lid close. |
| Crash | Audio stops with the process. System sound output is restored on next launch from a saved record. |
| File replaced by a new mix | New content ID, new track. Old cue flags the file as missing. Load Service also compares each file with the confirmed audio. |
| Saved data unreadable | The file is set aside, not overwritten, and the app says so. Older files with missing fields still load. |
| Plan leaves Planning Center's future list | The loaded plan and recent plans with confirmed work are kept. |

## System alerts

While a service is loaded, if the macOS default or alert output device is the house device, Cantor moves it to another output and restores it on unload, quit, or next launch after a crash. If there is no other device, Check says so. Focus cannot be set by an app, so Check reminds the operator.

## v1 scope

In: everything above. Out, see NEXT_STEPS.md: MIDI, per-cue overrides of track points, cue-output sharing a device with house, key detection, a red night theme, undo, Developer ID notarization, spare-Mac sync.
