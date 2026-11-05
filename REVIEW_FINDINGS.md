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

# Review findings: second pass (2026-11-02)

Three independent reviewers read the 16 commits after `79d42f9`, which the first pass covered: Planning Center (connector sync, service picker, service types, notes and schedule matching), the live show and library (Arm + Play, adding tracks to services, live EQ, meters, Not a Playback, multi-select), and Import (conversion, movies, FFmpeg, progress). Each one only read the code and ran the tests. ✓ means I re-read the code path myself and confirmed it before fixing.

**Baseline:** 315 tests passed before the fixes. **After:** 334 tests, 0 failures, 5 hardware tests skipped. The Release app builds.

## High: fixed

1. **✓ A sync that finished after Show Mode was turned on changed the loaded service.** Refresh checked Show Mode only when it started, and a connector sync can run for 8 minutes.
   - Fix: [AppModel.refreshPlans](Cantor/App/AppModel.swift) sets the read aside if Show Mode is on when it ends, and says so once the show is over.
   - Test: none. This is AppModel code, which has no test target. The guard is one line after the `await`.
2. **✓ A partly failed connector run counted as a sync, dropping services and skipping the token fallback.** Only "no data at all" was an error.
   - Fix: [PlanningCenterConnector.plans(fromStream:)](Packages/CantorCore/Sources/CantorCore/Planning/PlanningCenterConnector.swift) now throws, which hands over to the token client or keeps the saved plans, when:
     - the run ends in an error;
     - a service-type or plan list call fails;
     - Planning Center returns an `{"errors": …}` document;
     - an active, unskipped service type's plans were never read.
   - Tests: `testFailedPlanListIsNotASync`, `testErrorDocumentIsNotData`, `testRunThatEndsInAnErrorIsNotASync`, `testServiceTypeWhosePlansWereNeverReadIsNotASync`.
3. **✓ Import hung for good when the writer failed mid-encode,** for example on a full disk. The loop waited only on the reader. The progress display stuck, the queue stopped, and a hidden partial file was left.
   - Fix: the loop also ends when the writer stops writing, and every non-writing state counts as a failure.
   - Test: `testFullDiskEndsTheImportInsteadOfHanging` imports into a 1 MB disk image.

## Medium: fixed

4. **✓ A Play Now still loading could fire later over whatever the operator had armed since,** with no GO, or quietly acknowledge a fault.
   - Fix: `ShowController.playNow(_:pressedAt:)` cancels the request if the show's state or Show Mode changed after the button was pressed.
   - Tests: `testLatePlayNowIsCancelledWhenTheShowChanged`, `testLatePlayNowDoesNotAcknowledgeAFaultItNeverSaw`.
5. **✓ Live EQ clicked on the house output.** These all cleared every filter's state at once:
   - a gain dragged through 0 dB;
   - Band On/Off, Bypass and Reset.

   Output gain also changed in one step.
   - Fix: when sections come or go, [PlaybackKernel](Packages/CantorCore/Sources/CantorCore/Playback/PlaybackKernel.swift) crossfades from the old chain to the new one over 20 ms, using preallocated buffers. Output gain glides with a 5 ms time constant. Knob moves still update in place.
   - Tests: `testTurningABandOffLiveDoesNotClick` and `testBypassOnABoostedTrackGlides`. Both fail on the old kernel (one-sample jumps of 0.13 and 0.43) and pass on the new one.
   - This also covers first-pass finding 51 for preview.
6. **✓ ALAC in an `.m4a` was copied, not converted,** because the choice was made by extension.
   - Fix: an `.m4a` now goes through the encoder. AAC passes straight through and anything else is converted.
   - Tests: `testALACm4aIsConverted`, `testAACm4aIsPassedThroughNotReencoded`, `testMP3IsCopiedAsItIs`.
7. **✓ A running import queue kept converting through a cue.** The cue check only blocked starting an import.
   - Fix: the queue moved into CantorCore as [ImportQueue](Packages/CantorCore/Sources/CantorCore/Library/ImportQueue.swift). It waits between files while a cue is armed or playing or Show Mode is on, and shows "Import paused". It converts on a utility-priority dispatch queue instead of blocking Swift's shared threads.
   - Tests: `testQueueWaitsWhileTheShowIsBusyAndRunsInOrder`, `testQueuePausesBetweenFilesWhenACueIsArmed`, `testQueueReportsFailuresTogether`.
8. **The FFmpeg sandbox let FFmpeg write through system services.** `(allow default)` left Mach services open; the reviewer's `defaults write` from inside the sandbox went through.
   - Fix: the profile now also denies:
     - Mach lookups, which covers cfprefsd, Apple Events and LaunchServices;
     - Apple Events;
     - forking;
     - starting any program but FFmpeg itself.
   - Tests: `testSandboxBlocksWritesThroughSystemServices`, `testSandboxStartsNoOtherProgram`. FFmpeg imports still pass under the new profile.
9. **✓ Not Needed didn't stick on an item whose notes mention tracks,** such as "no tracks". Every Refresh turned it back on and could auto-confirm a file.
   - Fix: `ServiceCue.operatorNeeds` keeps the operator's choice for that item. Redetect and merging never override it, and it is saved.
   - Test: `testOperatorNotNeededSticksThroughNotesAndSyncs`.
10. **Re-reading a saved service didn't check the item count,** so a short or failed read could wipe its lines.
    - Fix: without a count, a read whose last page says more pages remain is refused. An error document is refused too.
    - Test: `testRereadWithoutACountNeedsEveryPage`.
11. **Auto-confirm accepted an exact title match whose length was far off,** for example another Mass setting's Gloria.
    - Fix: a name match with a length mismatch now waits for the operator. A file the operator chose for that song before still goes on, because Planning Center lengths are often placeholders.
    - Test: `testWrongLengthNameMatchWaitsForTheOperator`.

## Found while fixing

- **Import progress could crash the app** (in `e12c095`, the build installed before this pass). The progress update read the import status inside its own assignment, which Swift's exclusivity check stops at run time. It was found by the new queue tests. `ImportQueue` now reads, then writes.

## Low: open

- **Alert sounds and sleep during Play Now:** with no service loaded, Play Now doesn't keep macOS alert sounds off the house output or hold off sleep.
- **A fault during Play Now:** the Show view names the service's cue, not the Play Now track. Its kept position is under a one-off id.
- **Live EQ drags during a song:** each drag re-runs a failed buffer load, and its alert keeps coming back. Each edit also rebuilds the show (first-pass finding 44).
- **Plans read per service type:** the token sync reads 6 and the connector 4, so switching source drops plans 5 and 6.
- **Arrival order:** `plans()` keeps plans in the order they arrive, not by date.
- **The service picker** misses plans for service types that have services every day.
- **Name collisions:** an import's name is chosen before encoding, so a file with the same name dropped in during an import is replaced. A name near 255 bytes can't take " 2".
- **FFmpeg errors** logged inside a component (`[mov @ …] [error]`) aren't picked out, so the message can be "exited with status N".
- **Two live EQ changes within 20 ms:** the second restarts the crossfade from the first's new chain.

The long blocking waits on Swift's shared threads were fixed with finding 7, since imports now run on a dispatch queue.

# Review findings: third pass, before release (2026-11-02)

Five independent reviewers read the whole app at `6e4589b`, each only reading code: the audio and playback core, the library and saved data, Planning Center and Claude, the app layer and UI, and signing and release readiness. ✓ means I re-read the code path myself and confirmed it before fixing.

**Baseline:** 334 tests passed. **After:** 347 tests, 0 failures, 5 hardware tests skipped. The Release app builds and is signed with Developer ID (team 6RHHE8NEYA), with the hardened runtime, a secure timestamp and no entitlements; `codesign --verify --strict` passes. It has not been notarized yet.

## Release blockers: fixed

1. **✓ A file remembered for one song was auto-confirmed onto another.**
   - The memory key was a cleaned-up title with numbers and words like choir, special and solo dropped. So "Psalm 23" and "Psalm 91" shared `title:psalm`, and "Choir Special" had the empty key `title:`.
   - The second-pass fix for finding 11 also let remembered matches skip the length check. The same keys spread Needed and Not Needed choices.
   - Fix: [AliasMemory](Packages/CantorCore/Sources/CantorCore/Model/Models.swift) works as follows.
     - An item with a song id is matched by that song only.
     - A title key keeps the title's numbers, and a title with nothing left gets no key.
     - A title-only hit becomes a new source, `rememberedTitle`, which is offered but never auto-confirmed.
   - Tests: `testRememberedFileStaysWithItsOwnSong`, `testGenericTitlesHaveNoMemory`, `testTitleOnlyMemoryIsOfferedButNeverConfirmsItself`, `testRememberedNeedsStayWithTheirSong`.
2. **✓ The project couldn't be notarized.** The hardened runtime was off, signing was ad hoc with no team, and `get-task-allow` was in the Release signature.
   - Fix: the target's Release configuration sets:
     - `ENABLE_HARDENED_RUNTIME = YES`
     - `CODE_SIGN_IDENTITY = "Developer ID Application"`
     - `DEVELOPMENT_TEAM = 6RHHE8NEYA`
     - `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO`
     - `OTHER_CODE_SIGN_FLAGS = --timestamp`
   - Debug stays ad hoc, with the hardened runtime on.
   - The folder usage descriptions for Desktop, Downloads, Documents, File Provider (Google Drive), network volumes and removable volumes were added too, so the permission prompts say why.
   - Checked on the built product with `codesign -dv`, `codesign -d --entitlements -` and `codesign --verify --strict`.

## Medium: fixed

3. **✓ A scan that finished during an engaged cue merged on the main thread.**
   - Fix: [AppModel.rescan](Cantor/App/AppModel.swift) keeps only the hash cache, then scans again once the show is idle.
   - Not unit-tested, because AppModel has no test target.
4. **✓ Tracks confirmed while Load Service decoded were never loaded.**
   - Fix: the load now runs `loadMissingBuffers()` when it finishes.
   - Not unit-tested (AppModel).
5. **✓ Arm + Play during Load Service left the service "loaded" with no cues.**
   - Fix: `ShowController.load(cues:)` now returns whether it took the cues. If it refused because a cue was engaged, AppModel loads them on the first idle tick, and Unload clears that.
   - Test: `testLoadWaitsWhileAPlayNowIsSounding`.
6. **✓ Library merging grew with the square of the library size,** about 6 s for a no-change rescan of 10,000 files.
   - Fix: [Library.merge](Packages/CantorCore/Sources/CantorCore/Library/Library.swift) builds path and content lookups once per merge.
   - Tests:
     - `testFastMergeMatchesTheReference` runs the old merge, kept in the test, against the new one on 1,200 random merges (moves, duplicates, downloads, missing files and gaps) and finds them identical.
     - `testLargeLibraryMergesQuickly` merges 10,000 files in about 0.13 s in Debug.
7. **✓ A saved output pair survived a change to a smaller device,** so every Arm was refused with no picker to fix it.
   - Fix: choosing a device resets a pair it doesn't have to 1-2 (`OutputRouting.fitPairs`). Check now has a blocking item for a missing house pair and a warning for a missing cue pair.
   - Tests: `testChoosingASmallerDeviceResetsItsPair`, `testMissingOutputPairIsFlagged`.
8. **✓ Importing lossless audio at 32 kHz or below failed,** because the 256 kbps bit rate is above what the AAC encoder accepts there.
   - Fix: `Importer.bitRate` uses the highest rate the encoder accepts, up to 256 kbps stereo or 128 kbps mono.
   - Test: `testLowSampleRatesImport` covers 8, 11.025, 16, 22.05 and 32 kHz.
9. **✓ A file dated in the future started a full rescan every 3 seconds.**
   - Fix: a future date isn't treated as a file still being written.
   - Test: `testFutureDatedFileIsNotTreatedAsBeingWritten`.
10. **✓ Make Local on a symlinked track copied the link.**
    - Fix: the copy reads through the link.
    - Test: `testMakeLocalCopiesTheAudioBehindALink`.
11. **✓ One NaN or infinite sample in a float file silenced the rest of the cue when EQ was on.**
    - Fix: `PCMDecoder` sets non-finite samples to 0, which also keeps infinite peaks out of the saved library.
    - Test: `testBadFloatSamplesAreZeroedSoTheEQKeepsPlaying`.

## Low: open

- **Hold during a fade-in:** resuming comes back at full level within 5 ms.
- **The command ring:** a full ring to the audio thread drops a command silently. Nothing notices a position that stops advancing while live.
- **The "Not a Playback?" dialog** isn't gated by Show Mode and takes the transport keys.
- **Meters** are updated 30 times a second even when idle. A live EQ drag keeps a refresh retrying until the song ends.
- **VoiceOver:** the EQ knobs and graph handles have no accessibility value or adjust action. Cue rows show state only by symbol and colour.
- **A generic attachment filename** can auto-confirm the wrong file.
- **Planning Center paging:** `links.next` is followed with the credential without checking the host. `Retry-After` is not capped.
- **Keychain:** items stay in the file-based keychain. Expect one access prompt after the change of signature, and if it's denied, sync shows a Keychain error.
- **Ejected watched disk:** it stays a scan gap instead of showing its files as missing.
- **Renamed files** leave `.missing` entries that make Duplicates list a "same audio" group.
- **Interrupted imports:** a quit or crash during an import leaves a hidden partial file in ~/Music/Cantor.
- **Retagging:** the content hash only strips MP3 tags, so retagging a WAV, M4A or AIFF makes a new track. The comment in ContentHasher overstates this.
- **Copyright:** `NSHumanReadableCopyright` is still empty, and the build number is 1. Set both before each release.
- **Device names:** `hasPrefix("Pro Tools Audio Bridge 6")` also matches "…Bridge 64".


# Review findings: fourth pass, before 1.2.7 (2026-11-05)

Four independent reviewers read the eleven commits after `3ae9fd3` (the standalone-mode review), each only reading code: show and audio (`20a98e8`, `abc9d82`), the sidebar, pinning and `@AppEnvironment` (`c0538f7`, `69e83bb`, `ae5a526`, `9392815`, `cd28369`), Claude and Planning Center (`abeb0ae`, `29ccda3`, Claude Code discovery in `20a98e8`), and the Simple view and Pre-Service Check (`9278c67`, `c832d0a`, `6730963`). No blockers; the safety rules held. I checked every finding against the code before fixing it. Two fresh reviewers then read the fixes (`dfb1cb8`), and their findings were fixed in `334a96e`, which a fifth reviewer read before release. Its three low findings (a usage limit read as signed out, non-JSON output read as unanswered, an all-pinned fallback) were fixed before tagging.

## Fixed
- **Simple search field (high, from the fix review).** Releasing focus on any change of state could take the field away mid-word, so the rest of a typed song name armed and played. It now lets go only when Arm is pressed.
- **Expired Claude login flipped back to connected.** `auth status` still reads as logged in once a login has expired. A `loginExpired` flag now keeps it signed out until a request is answered; the sign-in check has three outcomes, and offline or overloaded is not an answer.
- **`[`/`]` just after a song ends** moved the next song's saved end. They pause for two seconds after a cue finishes.
- **Simple replace:** the old song stayed armed while the new one loaded, so GO played it. It now lets go first, unless the new song can't load. D drops a song still loading; A waits for a fault to be acknowledged; switching views cancels a pending load.
- **Simple keys** died after New Service changed the sidebar selection. Simple now counts as the Show view for keys, the Transport menu and alerts; New Service is off there.
- **Syncs, service reads, Resolve Ambiguous and Sign In** could run while a cue was armed or playing. All wait now.
- **Offline token errors** fell back to the connector for minutes. They now stop at once.
- **Claude Code in the desktop app:** verified builds first, newest first, real version folders only.
- **Pinning:** untitled Planning Center services showed as blank rows; Pre-Service Check now counts a pinned Planning Center service by its date (a pinned service built here never stands in); unpinning a hidden type keeps it; the loaded service never folds into Past Services, and a selected one that does opens the group.
- **Also:** end moves no longer re-decode cues; cue clicks point by id; double-click never turns on Show Mode over a pending load; the environment fallback logs each place once; two copies in ~/Music/Cantor count as duplicates.

## Open
- **Channel maps on a shared device** are now what keeps cue audio off the house pair. A preview on 3-4 with the house armed on 1-2 of the same device ran without a fault, but nobody has watched a meter on 1-2 during a preview on real Dante hardware.
- **Return on a sidebar service** may trigger the double-click action on macOS. Unconfirmed; it would only load and lock, never play.
- **"Sync With" in Settings** doesn't redraw right after a token is saved or cleared.
- **The alert's Sign In button** can appear on alerts unrelated to Claude while signed out.
- **Double-click on the loaded service while it still loads** opens the Show view without Show Mode and says nothing.


# Review findings: fifth pass, after 1.2.8 (2026-11-05)

1.2.8 went out without a review. Four independent reviewers then read `v1.2.7..v1.2.8`, each only reading code: the New Files list and Sort with Claude, tags (and a stray tag seen in testing), the copy queue with practice and demo detection, and end points. No blockers; the safety rules held. I checked every finding against the code before fixing it.

## Fixed
- **New Files answers were lost** when an alert covered the list or Later closed it. They live in the model now, and a copy-failure alert waits for the list to close.
- **Return in a title field applied every row.** Apply has no Return shortcut; Esc keeps the answers.
- **The list did a library lookup per row on every keystroke.** Rows are built once per update from a dictionary, and the tag and service-item lists once per update.
- **A service item that had passed** while a file waited could still be confirmed. Apply only confirms items the list offers now.
- **Sort with Claude replaced titles the operator had set.** A title that isn't just the file's name is kept.
- **The New Files list could open over the tag editor** and be dismissed as Later.
- **Cantator's own copy decided exclusion.** Its name is the title and tag, so "Practice of Praise - Accompaniment" lost its keep word, and ~/Music/Cantor made unrelated songs a same-length set. Detection reads the original file, and a file applied as a playback is the operator's choice, which detection leaves alone.
- **Practice parts made a choral pack's playback look like a stem** under the same-length rule. Parts and demos exclude on their own but no longer count as stems.
- **A Drive file that timed out** left the queue starting the next download while it kept going. A timeout stops the queue and reports the rest. The queue also waits through Show Mode, and analysis never starts while a cue is engaged.
- **The classifier prompt** read a lone S, A, T or B, and any pair of files, as a practice part and its helper. It now needs PTX or a part word, or a file that says demo.
- **Renaming onto an existing tag merged silently.** It asks first. A tag deleted while its name was being edited stays deleted, and guesses only use tags still on the list.
- **Tag counts:** the sidebar hides tags only excluded tracks have; the editor counts as the sidebar does. Text typed in the inspector's Add tag no longer carries to the next track.
- **End point panel:** a track with no length yet (a copy from a Drive placeholder) could get a 0.1 s end from a click; the panel stays closed until there is a length, which analysis now fills in. Sound past a file's reported length counts as needing an end. The panel opens when analysis finishes, shows where the sound stops when the silence is longer than 20 s, keeps a drag inside its window, and its Preview End button stops the preview it started.

## Fixed after the fix review
Two fresh reviewers read the fixes. Their findings, all fixed:
- **Spelled-out parts** ("Soprano PTX") still counted as stems in a same-length set, since voice names are weak words. A file with a part word never counts as a stem now.
- **A moved file was judged by its old path**, which a scan keeps, marked missing. Detection prefers an original that is still there.
- **Sound past a file's reported length** was flagged, but an end can't be set past that length, so clearing the flag cut the music. It isn't flagged now; the whole file plays.
- **Dragging the end in the panel ran away** to the file's end, since the view followed the end. The view holds still during a drag.
- **Kept as a playback** was set on every applied row, so a stem accepted unseen was never caught later. Only rows the operator turned from "not" into a playback are kept.
- **An answer kept through Later** could undo a rename made in the Library meanwhile. A title left as suggested gives way to it, and answers leave with their files on every path.
- **Return in the tag editor** closed it before a merge could be confirmed; Done has no Return shortcut. **Edit Tags…** is off while New Files is up. The delete alert says how many of the tracks are excluded.

## Open
- **The stray "choir" tag** seen in testing: no code path found. Most likely a stray click on Choir in a Tag menu. Every tag added to tracks is now logged (category `tags`) to settle it if it happens again.
- **A copy that finishes after its timeout** still lands in ~/Music/Cantor and joins its track by content on the next scan; a cloud-only original with no content ID yet can briefly become a track of its own.
- **Queued copies for a track a scan folds into another** are dropped without a report.
- **A file's reported length can be up to 1 s longer than its audio**, which counts toward the two seconds of silence.
- **Tag names are cleaned silently**: lowercase, letters, numbers, spaces and hyphens, 24 characters.
- **The New Files list rebuilds its rows on every keystroke** in a title: once per update now, not per row, but caching them would make it truly once.
- **After a copy timeout**, the next Apply or Make Local can start a download while the stuck one is still running.
- **A selected sidebar tag** whose last playback is excluded disappears from the sidebar while it stays selected.
