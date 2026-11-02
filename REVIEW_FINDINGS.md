# Review findings: first pass (2026-11-02)

Six independent reviewers went through the code:
- five covered one area each: playback/audio, library/inbox/matching, show/planning/model/system, app layer, and views;
- one traced the end-to-end flows from a key press down to the kernel.

Findings that more than one reviewer reported are merged. ✓ means I re-read the code path myself and confirmed it.

**Baseline:** `swift test` passes 194 tests (5 hardware tests skipped), and the Debug app builds.

**What held up:**
- Nothing makes house sound without Arm and then GO.
- Only one house cue can play at a time, at every layer.
- No allocation or reference counting on the render thread, and the command ring's memory ordering is correct.
- Fade math, RBJ biquads and BS.1770 loudness all match their references.
- Key repeats can't trigger Arm or GO, and transport keys never fire from text fields.
- Sleep counts as a fault.
- System sound is restored on unload, on quit and at the next launch.
- Saved JSON is written atomically and keeps a `.bak`.

## Status (2026-11-02)
Tier 1 and Tier 2 are fixed, uncommitted. `swift test`: 269 tests, 0 failures, 5 hardware tests skipped. The Debug app builds.

Not fixed or only partly fixed:
- **28:** the same-length rule for cloud-only stems. There is no duration without downloading the file.
- **29:** placeholder *renames*. The old size isn't stored. Moves are fixed.
- **29:** a fresh added date on the first Drive enumeration. This needs checking on a real Drive.
- **31:** needs checking against a real VBR MP3 without a length header.
- **8:** the stale-notification filter needs real Core Audio to test.
- **Keychain:** no unit test, because it would touch the login keychain.

Tier 3 is still open, apart from these, which were fixed along the way:
- the preview race (34) and the stale preview position (35);
- Check refreshing after routing or plan changes (32);
- the Load/Unload race (49);
- the Claude status staying "off" (50).

## Tier 1: can go wrong during a service

1. **✓ D doesn't clear a mid-track start while idle.** In [ShowController.swift:168](Packages/CantorCore/Sources/CantorCore/Show/ShowController.swift:168), `disarm()` only clears the kept position from `.armed`.
   - What goes wrong: fault → Return → D (to start from the top) does nothing. A and GO then resume mid-song into the room.
   - The README says D clears it.
2. **✓ An alert during a live cue takes over the transport keys.**
   - Code: SwiftUI `.alert` ([RootView.swift:49](Cantor/Views/RootView.swift:49)) is a sheet, and [KeyRouter.swift:37](Cantor/App/KeyRouter.swift:37) gives up all keys except Esc while a sheet is attached.
   - Ways to trigger it:
     - H with no cue device set;
     - a preview decode failure;
     - a save failure from the save scheduled after GO.
   - What goes wrong: F, P, `[`, `]` and M stop working. Space and Return close the alert. Esc, the natural way to close an alert, starts a panic fade on the live cue.
   - Related: the "say once" save alert repeats whenever a later save succeeds ([AppModel.swift:233](Cantor/App/AppModel.swift:233)).
3. **✓ Settings that change the show aren't locked in Show Mode.**
   - Unlocked: loudness matching on/off, target LUFS, fades and panic length ([SettingsView.swift:79](Cantor/Views/SettingsView.swift:79)).
   - The Outputs tab is locked only while a cue is engaged, so house device and pair can be changed between songs.
   - Sync Now, Add/Remove Folder and Rescan also run in Show Mode. A sync can add, remove or reorder the loaded cues.
   - What goes wrong: the next cue plays at a very different level, or on a different output.
4. **✓ Background analysis changes cues in the middle of a service.** [AppModel.swift:326](Cantor/App/AppModel.swift:326) keeps running after Load Service.
   - When it finishes it sets `integratedLUFS`, which can move gain by up to ±24 dB, and it can move `startSec`.
   - `markCuesChanged` then applies those changes to the show at the next idle moment.
5. **✓ A cue becomes impossible to arm after a device loss past its end marker.**
   - Cause: `deviceLost()` saves the raw position. A panic fade can run past the end marker, and then every Arm is refused with `.emptyRange`.
   - Nothing clears the saved position except reloading the service. See [ShowController.swift:241](Packages/CantorCore/Sources/CantorCore/Show/ShowController.swift:241).
   - Related: a device loss *during* a panic or F fade keeps the position, so the next Arm resumes a song the operator had stopped.
6. **✓ `[` near the end can cut the house output within one sample.**
   - Code: `setEnd` clamps to `position + 1` ([PlaybackKernel.swift:281](Packages/CantorCore/Sources/CantorCore/Playback/PlaybackKernel.swift:281)), and the next render starts a fade that is 1 frame long.
   - It happens on tracks with a fade under 1 s.
   - Separately, `]` stops working once the end fade has begun.
   - Two quick presses in one audio buffer only move the end once.
7. **✓ Resuming from Hold near the end halves the saved end fade.** The `lead` is computed from `playStart`, which is reset on every play ([PlaybackKernel.swift:186](Packages/CantorCore/Sources/CantorCore/Playback/PlaybackKernel.swift:186)).
8. **The UI can show LIVE while the house engine is dead.**
   - Two things detect a dead engine: the configuration-change observer, added only after `engine.start()`, and a 1 s check that the device UID still exists. Nothing checks `engine.isRunning`.
   - What goes wrong: a fast USB drop and reconnect leaves the state LIVE with the remaining time frozen.
   - Also, a notification already queued from the previous engine can fault the newly armed cue.
   - Plausible, not reproduced. See [OutputEngine.swift:64](Packages/CantorCore/Sources/CantorCore/Audio/OutputEngine.swift:64).
9. **Main-thread stalls during a live cue delay Esc.**
   - Rescans (FSEvents, every 3 s while a download is unsettled, on wake) run `Library.merge` on the main thread with several passes over all tracks.
   - Every GO triggers a synchronous `saveNow` of everything 0.5 s later.
10. **A channel pair that doesn't exist silently moves to another pair instead of refusing.**
    - If the configured pair is past the device's last pair, it is clamped to the last pair. If the device reports 2 or fewer channels, audio goes to 1–2.
    - See [OutputEngine.swift:44](Packages/CantorCore/Sources/CantorCore/Audio/OutputEngine.swift:44) and :88.
11. **Re-confirming a cue on a loaded service leaves it unarmable.** The new track is never decoded, so Arm fails with "not loaded".
12. **Claude filing keeps running after a cue is armed.** `canClassify` is checked only once, before a batch of 25-file `claude -p` calls ([AppModel.swift:708](Cantor/App/AppModel.swift:708)).

## Tier 2: data and correctness

13. **✓ Privacy: the folder sent to Claude can include an email address or account name.** `folder(of:)` takes the last two path components ([FileClassifier.swift:20](Packages/CantorCore/Sources/CantorCore/Inbox/FileClassifier.swift:20)). For a file at a watched root, that sends `GoogleDrive-btarcau@gmail.com/My Drive` or `bentarcau/Downloads`.
14. **Resync drops confirmed cues and doesn't flag arrangement or key changes.**
    - A PCO item that is re-created loses its confirmation.
    - `changedSinceConfirm` ignores arrangement and key.
    - See [Models.swift:296](Packages/CantorCore/Sources/CantorCore/Model/Models.swift:296).
15. **Scan gaps mark existing files missing.** Files skipped as unsettled or undecodable, and roots that fail to enumerate (no permission, Drive not running), become `.missing` on confirmed tracks.
16. **A rescan requested while one is running is dropped.** There is no pending flag, so the new file, folder or Load Service reconcile waits for some later event.
17. **✓ Numbered titles match each other.** All-digit tokens are dropped, so "Psalm 23" scores 0.97 against "Psalm 91" and is never sent to Claude.
18. **✓ The tiebreaker trusts the model's numbers.** Confidence isn't clamped: a reply of 85 wipes the other candidates' scores. An out-of-range `chosen_index` demotes every candidate.
19. **A late Resolve Ambiguous result overwrites newer candidates.** It can bring back excluded or deleted tracks.
20. **✓ The run log can lose or reorder entries.**
    - Writes run on a concurrent global queue with seek-then-write. Back-to-back "hard-stop" and "device-lost" can collide.
    - Queued writes are lost at quit.
    - If opening the file fails, `write(to:)` replaces the whole log.
    - `device-lost` is logged without the cue name.
21. **Keychain.**
    - `write` deletes before it adds and ignores the delete status, so a failed add loses the secret.
    - `read` treats every error, including denied access, as "no token".
22. **PCO sync.**
    - `plan_times` and `attachments` use `try?`, so a failure wipes the saved service times.
    - Requests are spaced 150 ms apart, about 133 per 20 s, against a limit of 100.
    - One plan that fails aborts the whole sync.
23. **Decoding saved data is brittle.** Nested types use synthesized `Codable`. One new field or enum value makes the whole library or settings file unreadable, and it is set aside. This is a risk for future changes, not a current bug.
24. **System sound restore record.**
    - `engage` saves the record with `try?`.
    - `release` deletes the record even when the device was absent and nothing was restored.
25. **Make Local race after a timeout.**
    - It reuses the same `.partial` name, so a retry and the orphaned copy collide.
    - The prefix check has no trailing `/`.
    - A copy that fails verification is left at the destination.
26. **ClaudeCLI has no SIGKILL fallback.** A hung `claude` process leaves `isClassifying` or `isMatching` set for the whole session.
27. **Hashing uses `mappedIfSafe`.** If a file is truncated mid-hash (for example by a Drive sync), the app can crash with SIGBUS.
28. **Stem detection.**
    - "MultiTracks" splits into `multi` + `tracks` and doesn't match.
    - Cloud-only stems have a duration of 0 and skip the same-length rule.
29. **Drive placeholders.**
    - Moving or renaming a cloud-only file creates a ghost duplicate and a false "new file".
    - First enumeration may give old files a fresh added date. Plausible; needs checking on a real Drive.
30. **Kept resume positions survive changes to the cue's track or buffer.**
31. **A VBR MP3 without a length header may be decoded short.** A single `read` sized to the estimated length can drop the tail.
32. **Pre-Service Check gaps.**
    - It doesn't flag cues that Arm will refuse with `.emptyRange`.
    - It gives a false Must Fix for tracks already in RAM.
    - With no service loaded it checks `plans.first`, which can be last week's plan. The Library's "Add to…" button uses the same plan.
    - Its results go stale after routing or match changes.

## Tier 3: preview, editor and UI

33. **✓ Clicking an EQ handle jumps it and turns the band on**, including HP and LP. The drag uses the absolute position from the first event.
34. **✓ Previews aren't cancelled.**
    - A slow decode can start after Stop, replace a newer preview, or start after entering Show Mode or sleeping.
    - EQ edits made during the decode aren't heard.
35. **The preview position goes stale after a stop the app didn't ask for (sleep, config change).**
    - The New File pop-up stays blocked.
    - "Set End Here" writes a stale time.
36. **"Set End Here", "Add Marker" and EQ Preview use another track's preview position** when a different track is selected.
37. **Any drag on the inspector waveform moves the nearest boundary**, however far away it is.
38. **The EQ window's Preview button never changes to Stop.** `CueBus` isn't observable.
39. **Audition from a point past the end marker starts at the end marker** ([OutputEngine.swift:136](Packages/CantorCore/Sources/CantorCore/Audio/OutputEngine.swift:136)).
40. **Show view: the transport row is under-budgeted.** It overflows in FAULT with the Acknowledge button. The main window's `minWidth: 1370` overrides the 1131 pt minimum the Show view works out.
41. **Show view: the End label ignores the run-only nudge.**
42. **Show view: the peaks disk read isn't cached on a miss**, so a cue with no peaks file reads the disk every frame.
43. **"Proposed" and "Confirmed" chips are green**, which breaks the rule that green means LIVE only.
44. **Every drag frame or keystroke in the Library or EQ calls `updateTrack`**, which re-sorts the table, re-runs Check and rebuilds the show cues.
45. **The Option key mid-drag makes a knob jump. Gesture state isn't reset when a drag is cancelled.**
46. **The Claude path field re-checks on every keystroke, and the final value is often skipped.** Claude status also shows and runs in Show Mode.
47. **New File sheet.** It can keep a hidden service-item selection. The "Not a Playback" help text is wrong.
48. **The inspector keeps `tagText` and field edits across selection changes.**
49. **Load and Unload can race.**
50. **Turning Claude on while a cue is engaged leaves the status at "off".**
51. **EQ preview.**
    - Toggling a band clears or shifts filter state, which can click.
    - The output gain changes in one step.
    - There is no NaN/denormal protection; the denormal risk only matters on Intel.
52. **SelfCheck (Debug only) has no safety check of its own.** Run without a throwaway home, it writes to real folders and plays on the real house device.

## Decisions for the owner
- **GO by mouse:** the GO button and the GO menu item make house sound from a click. DESIGN implies this is intended, but it conflicts with "clicks never start audio".
- **Aggregate and Multi-Output devices:** one that includes the house interface passes the house-and-cue-differ check.
- **Panic then fault:** should resuming after that restart from the top?
