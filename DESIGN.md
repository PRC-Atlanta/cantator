# Cantator: design

Cantator is a native macOS playback app for the person running choir and special-music tracks from the mixing console during a live service. It is an ordered cue list with a two-step arm and go, not a clip launcher.

## Critique of the four proposals

| Conflict | Resolution |
| --- | --- |
| A wants engines always running to avoid clicks. D wants the house engine stopped unless armed. | D wins. A stopped engine cannot emit. ARM starts the engine with the kernel producing exact zeros. GO opens with a 5 ms ramp, so there is no click. |
| B targets -18 LUFS, D targets -16. | -18 LUFS, changeable in Settings. Choir tracks have dynamics and the console has headroom to make up. Capped at -1 dBTP. |
| B wants GRDB/SQLite. | Atomic JSON files with rolling backups. A show app should have no third-party dependencies, and the data set is thousands of rows at most. |
| B's tiered hashing vs simplicity. | One content ID: SHA-256 of the audio payload (tags stripped for MP3), cached by path, size and mtime. Duplicates collapse into one track with several paths, so cue points survive. The copy in ~/Music/Cantor doesn't count toward Duplicates. Tiering saved little on an SSD. |
| D's aggressive decode at ARM vs A's preload. | Decode every matched cue into RAM on Load Service. ARM never touches disk, so a Drive stall cannot delay or cut a cue. |
| D resamples at load vs letting the graph do it. | Keep native-rate buffers and let the engine's mixer convert. Marker frames stay simple and no resampler is written. |
| A's manual end nudges vs D's fixed end marker. | Markers are saved per track. `[` and `]` move the end for this run only and are never persisted in show mode. |
| D refuses matching house and cue devices. | Kept, including the same device on different channels. It is the only rule that makes "never the house" verifiable. |
| Should a failed pre-service check block the show? | No. Issues are advisory, because the operator may have no alternative. A specific cue that cannot play (no file, not in RAM) refuses to arm. |

## Architecture

```
Cantor (app target: SwiftUI + AppKit, builds Cantator.app)
  AppModel, Views, KeyRouter
CantorCore (Swift package: all logic, tested without hardware)
  Playback/   ShowStateMachine, GoGuard, FadeCurve, PlaybackKernel
  Audio/      OutputEngine, HouseBus, CueBus, AudioDevices, PCMDecoder, LoudnessMeter, TrackAnalyzer
  Library/    LibraryStore, FolderScanner, FolderWatcher, ContentHasher, FileLocality, Materializer, Importer, ImportQueue, FFmpeg
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

- **Track**: id, contentID, files (path, locality), title, durationSec, sampleRate, channels, startSec, endSec?, suggestedEndSec?, fadeOutSec (3), fadeInSec (0), trimDb, integratedLUFS?, truePeakDb?, markers, key, notes, tags, pcoSongIDs, playCount, lastPlayed, exclusion (reason, by operator)?, keptByOperator, eq (on, high-pass, six bell or shelf bands, low-pass, output dB)?.
- **ServicePlan**: PCO plan id, serviceType, title, dates, times, syncedAt, items, picked. A service built in Cantator has id `manual-<uuid>`, service type `cantator` and the operator's name as both title and type name; a sync never drops it, and `pruningPastManual` removes it `keepPastServicesWeeks` after its date unless it is loaded.
- **ServiceTemplate** (in settings): name, saved date, and items (title, header or not, needs playback, notes), never tracks.
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
5. The house transport works in the Show view, with or without Show Mode. Leaving the Show view disarms an armed cue; while a cue plays or holds, the Show view cannot be left. The Transport menu, like the keys, acts only in the Show view or Show Mode. Show Mode (Cmd-Shift-L; Cmd-L locks the screen on some Macs) is an optional lock: library and plan editing are off except the EQ, the sidebar shows the loaded service's program instead of its links, and the window cannot be closed. Show Mode cannot be left, the window cannot be closed and the app cannot quit silently while a cue is armed or live.
6. Esc fades everything (1.5 s). Esc twice within 1 s stops hard. This works in every view and whether or not Show Mode is on.
7. House device loss during playback stops immediately, retains position, and shows a red fault. Cantator never rebinds to another device by itself.
8. House and cue must be different devices. Audition is unavailable until a cue device is set.
9. Transport keys act only when aimed at the main window with no sheet, dialog or text field in focus. Typing in Settings can never arm or start a cue. Transport menu items show their key in the title instead of being menu shortcuts, because a bare-key menu shortcut would fire from a text field.
10. Show plays what was last saved: edits to a loaded service apply as soon as no cue is engaged.
11. If the Cantator window is not key while armed or live, the state bar says KEYS NOT FOCUSED.
12. Cue-to-house level: static gain only, no limiter, no gain change while playing.

## Keyboard (Show view or Show Mode)

| Key | Action |
| --- | --- |
| Up / Down | Move the next-cue pointer (only when not live) |
| A | Arm the next cue |
| Space | GO |
| F | End of song: fade with the track's saved fade |
| P | Hold (GO resumes) |
| M | Jump to next marker while armed or held; Shift-M previous |
| `[` / `]` | Move the end point -1 s / +1 s for this run. During the automatic end fade (not after F or Esc), `]` rises back to full and returns to LIVE |
| H | Audition on the cue output (toggle): the pointed cue, or the next one while a cue is engaged |
| Return | Acknowledge a fault |
| D | Disarm |
| Esc | Panic fade; twice for hard stop |

Stream Deck works by sending these keystrokes. MIDI is deferred (see NEXT_STEPS.md).

## Screens

- **Show**: full-width state bar (word, icon and color: IDLE, ARMED, LIVE, HOLD, FADING, PANIC, FAULT) with the current cue title and its remaining time in large SF Mono. Cue list at left. At right, in the EQ window's F6 palette: a short waveform with playhead, start and end markers and fade zone, the cue's full EQ editor, the same as the EQ window, fade, gain and end readouts, next cue, house and cue meters. State colors stay as they are; the F6 orange is not used here, since it reads as FADING. Key legend along the bottom. The state color stays inside the Show view and never runs under the sidebar. In Show Mode the sidebar is the program: the loaded service's items under their headers, scrollable, with no actions. Items in the show have a note, and the one the show is on has an arrow or its state's symbol and color, and stays scrolled into view.
- **Service**: sidebar of upcoming plans, with past ones folded under Past Services. Table of items with Needs, Match, Confidence and State. Inspector shows candidates with the reason, preview on the cue output, Confirm, Choose Other, Not Needed. Load Service builds the cue list and starts the decode. A service built in Cantator (`serviceTypeID == "cantator"`, every cue manual) is an editor instead: Add Item and Add Section, titles typed in place, notes, a Track checkbox, arrows and row drags to reorder, Looks Like (the name matcher's candidates, never auto-confirmed) with Use, and a More menu with Duplicate for Next Week, Save as Template and Delete Service. With no item selected the inspector edits the service's name and date.
- **New Service**: a sheet from the sidebar, File > New Service… or tracks dropped on New Service…: name, date and time, and a start point (blank, a copy of a service's order, a template). Copies and templates carry sections and item titles, never tracks.
- **Welcome**: the first launch's one question, build here or Planning Center, saved as `serviceSource` with `hasChosenServiceSource`. Settings saved before the question existed read as Planning Center with Claude on, so nobody is asked twice.
- **Service picker**: a sheet from Choose Service… in the sidebar. Every service type's plans from six weeks back to three weeks ahead, Upcoming then Past, with a service type filter. Read Service reads that plan's items and opens it.
- **EQ window**: one per track, opened from the inspector. Response curve with a handle per band (drag for frequency and gain), band buttons (double-click turns a band on or off), shape, FREQ, Q, GAIN and OUT knobs (drag, Option for fine, double-click to reset), On/Bypass, Preview and Reset. Open in Show Mode: edits reach the armed or playing house cue at once through the kernel's lock-free command queue, and are saved with the track (the save waits until no cue is engaged, like every save). Always dark, in the Waves F6's palette: a slate graph, a color per band (HP and LP white), orange knobs and yellow brackets on the selected handle. This is the one exception to color meaning state. Its neutral slate and chrome also dress the Show view's play area, and its band colors appear there only inside the EQ curve.
- **Library**: sidebar (All, tags, Needs Attention, Not Downloaded, Duplicates, Excluded). Excluded lists stems and Not a Playback files with the reason, and This Is a Playback brings one back. Sortable table. Inspector with waveform, start, end, fade, trim, markers, key, notes, tags, file paths.
- **Check**: pre-service checklist grouped by Blocking, Warning and OK, each row saying what to do.
- **Settings**: Outputs, Playback, Services (where services come from, the Claude switch, new-file handling, templates, how long past services stay), Folders, then Planning Center only while it is the source and Claude only while its switch is on. The sidebar's bottom row shows the house and cue outputs and opens Outputs; the Claude row above it appears only with Claude on.

Dark by default with an adaptive light appearance. Color is used only for state.

## Planning Center and AI flow

0. Source: the Planning Center connector on the Claude account by default, through `claude -p` with `--tools ""`, `--allowedTools` set to `services_service_types`, `services_plans` and `services_plan_items` on that server (found with `claude mcp list`), and `--output-format stream-json`. `PlanningCenterConnector` reads the tool results out of the stream, maps items with the same code as the token client, marks a plan `syncFailed` when its items are missing or its `items_count` disagrees, and sets `attachmentsUnavailable` on playback cues so merging keeps saved filenames. The next four plans per service type. On any connector error the token client below runs instead.
0a. Service picker: the list is one run with the same three tools, asking each service type for its last 25 past plans and next 10 future ones (the connector can only filter plans by past or future), then keeping those from six weeks back to three weeks ahead. Choosing one is a second run that reads only that plan's items. Its ids are checked to be numbers before they go into the request, and a read whose item count disagrees is an error rather than a half-filled plan. The token path lists with `filter=past` and `filter=future` the same way. A picked plan is marked `picked`, so a sync keeps it while it is inside the window, even with no confirmed cues.
1. Fetch service types, then future plans, then items (`include=song,arrangement`) and plan times. Attachments are fetched for playback candidates only. Requests are spaced 150 ms apart, 429s honor Retry-After, and pagination follows `links.next`.
2. Detect needs-playback from a track word in the item's title, arrangement or notes. An operator choice is remembered per song: a remembered Needed adds an item, but a track word beats a remembered Not Needed.
3. Match each cue: remembered aliases first (0.98; by the item's song when it has one, else by its title with numbers kept, and a title-only hit is never auto-confirmed), PCO attachment filename, then a string-similarity blend (token Jaccard, Jaro-Winkler, normalized Levenshtein) with a duration check.
4. On request, items in the ambiguous band (top 0.45 to 0.85, or a margin under 0.08) go to Claude in one batch: item titles, arrangement names, candidate filenames and durations only. No paths, no notes, no audio. The call runs the operator's installed Claude Code headlessly, using its signed-in Claude account, with no tools, settings or MCP servers. The result blends 0.6 string, 0.4 Claude.
5. A Proposed match (0.85 or more, 0.08 clear of the next) confirms itself after each ranking, outside Show Mode, and is marked Auto-confirmed. Clear Match sets `matchCleared` on the item so it is never auto-confirmed again; confirming another file clears the Auto mark. Everything else needs the operator.

## New files

1. FSEvents triggers a rescan. Each scanned file carries its added-to-folder date. A track created by the scan counts as new when one of its files arrived after Cantator started watching that folder (`AppSettings.watchedSince`, stamped when a folder is first seen and cleared when it is removed). So a launch catches files that arrived while the app was closed, and adding a folder does not flood the inbox. Another copy of audio already in the library is not new.
2. After each scan, StemDetector excludes stems: strong words in the name (click, stems, BGVs, drums), a Stems or Multitracks folder (the file's own folder or the one above), or sets of three or more files in one folder within 0.1 s of each other in length, where a weak word (bass, keys, guide, vocals) excludes a file, and a file with no telling words is excluded when two or more of the set are named as stems. Mix words (mix, full, master, accompaniment, key, with, no) always keep a file. Kept and confirmed tracks are never excluded. Detection reruns on every scan, so its own exclusions follow the files, while Not a Playback and This Is a Playback stay as the operator left them. Excluded tracks skip matching, analysis, the library lists and the inbox.
3. New tracks go into `new-files.json`, so they survive quitting.
4. While no cue is armed or playing, waiting files go to Claude in batches of 25: filename, the two folders above it, duration, embedded tags, category names and upcoming unmatched item titles. Claude returns a title, one category, whether it is a playback at all, an optional item id from the list, a confidence and a reason. Ids it was not given are ignored. If Claude is off, signed out or fails, the category is guessed from keywords and the item from the name matcher at 0.75 or above, and the pop-up says why.
5. The pop-up shows only when no service is loaded, the show is idle, Show Mode is off, no preview is playing and nothing is loading. Accept writes the title and category tag, confirms the service item if one is chosen and still empty, and can copy the file to `~/Music/Cantor`.
6. **Import…** (`Importer`) brings in a file from outside the watched folders. Uncompressed and lossless sources go through AVAssetReader to float PCM, at 48 kHz or below and two channels or fewer, then AVAssetWriter to 256 kbps AAC in an m4a. MP3 and ADTS AAC are copied unchanged. An m4a goes through the reader, so AAC passes straight through and ALAC is converted. A movie (MOV, MP4, M4V) gives its first audio track; AAC that already fits is passed through without decoding. Both paths write a hidden partial file, check it with the Make Local verifier, then rename it into `~/Music/Cantor`. Tags come from AVFoundation's common metadata, with gaps filled from `AudioTags`, since AVFoundation misses the info tags of WAV, AIFF and CAF. What AVFoundation can't open goes to FFmpeg when it is installed (`FFmpeg`, found in the Homebrew and MacPorts locations, never bundled): it runs under `sandbox-exec` with no network, no Mach services (so no cfprefsd, Apple Events or LaunchServices), no fork, no program but itself, and file writes only in its own temporary folder, extracting the first audio track to a lossless FLAC that then takes the AAC path. Without FFmpeg, those files are refused with a note that FFmpeg is needed. `ImportQueue` runs the files one at a time on a utility dispatch queue and waits between files while the house engine is held or Show Mode is on. The managed folder has no watch start, so AppModel keeps the imported paths and puts the tracks the next scan creates from them into the inbox. A track whose audio was already in the library just gains the file.
7. Everything is snapshotted to disk. The Show view reads only snapshots and RAM. A resync that changes a confirmed item flags it rather than dropping it.

## Failure handling

| Failure | Behavior |
| --- | --- |
| Drive file not downloaded | Flagged in Library and Check. Make Local copies it to `~/Music/Cantor` and proves the file decodes. |
| Internet drops | Nothing in Show depends on it. Check displays sync age. |
| House interface unplugged | Instant stop, FAULT with the reason, position kept. Re-arm is manual and shows where it will start. D clears it to start from the top. A loss during F or a panic keeps nothing, and a kept position inside the end fade is dropped at arm. |
| Cue interface unplugged | Audition stops. Show continues. |
| House output pair missing | Arm refuses and names the pair and the device's output count. Audio is never moved to another pair. |
| Alert while in the Show view or Show Mode | Shown in the Show view with Dismiss, never as a sheet, so the transport keys keep working. |
| Service item removed in Planning Center | A confirmed cue is kept and marked removed, or moves to the one re-added item for the same song. |
| Sample-rate change | Treated as device loss. |
| Sleep | Power assertions while a service is loaded. Wake always returns idle. Check warns about battery power and lid close. |
| Crash | Audio stops with the process. System sound output is restored on next launch from a saved record. |
| File replaced by a new mix | New content ID, new track. Old cue flags the file as missing. Load Service also compares each file with the confirmed audio. |
| Saved data unreadable | The file is set aside, not overwritten, and the app says so. Older files with missing fields still load. |
| Plan leaves Planning Center's future list | The loaded plan, recent plans with confirmed work, and plans chosen in the picker (while inside its window) are kept. |

## System alerts

While a service is loaded, if the macOS default or alert output device is the house device, Cantator moves it to another output and restores it on unload, quit, or next launch after a crash. If there is no other device, Check says so. Focus cannot be set by an app, so Check reminds the operator.

## v1 scope

In: everything above. Out, see NEXT_STEPS.md: MIDI, per-cue overrides of track points, cue-output sharing a device with house, key detection, a red night theme, undo, Developer ID notarization, spare-Mac sync.
