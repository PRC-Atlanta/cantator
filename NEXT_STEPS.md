# Next steps

## Test on the real rig before relying on it

These could not be tested in development.

- **Google Drive placeholders.** Detection uses `lstat` flags, which is the documented signal for dataless files, but no real Drive placeholder was tested. Check that a cloud-only file shows as not downloaded, and that Make Local downloads it.
- **A physical audio interface.** The audio path and channel map were tested on virtual devices (BlackHole and Pro Tools Audio Bridge). Confirm that output pairs route correctly on your interface, because channel map behavior varies by driver.
- **Unplugging the interface during playback.** Fault handling was tested by simulating the loss, not by pulling a cable.
- **Planning Center with a real token.** The client was tested against stubbed responses built from the documented API. No request has reached the live API.
- **Claude with your account.** The standalone Claude Code on this Mac is signed out, so no real request has run, for matching or for new files. Run `claude auth login`, then drop a song into a watched folder and try Resolve Ambiguous. The process handling was tested with a stand-in script, and the signed-out result with the real CLI. The success output format is from documentation and has not been seen from a real run.
- **The service picker.** Listing and reading were tested with stand-in connector output and stubbed parsing, not a live Planning Center account. Check that a service type with more than 25 services in six weeks still shows the oldest ones: the list asks each type for its last 25.
- **New files from Drive.** The pop-up flow was tested end to end with a file written into a watched folder during a loaded service. Arrival dates of real Drive syncs and AirDrop were not tested.
- **MP3 decoding.** WAV and AAC were tested with real files. MP3 goes through the same Apple decoder, but no real MP3 was tested.
- **Import in the app.** Conversion was tested with generated WAV, AIFF, FLAC, 96 kHz six-channel and mono files, with tags, and with generated MOV, M4V, MP4, MKV, AVI and OGG files through FFmpeg 9. No real phone or camera video was tried. The open panel, the scan after it and the New File pop-up for an imported file have not been run in the app.
- **Keyboard control.** Key handling in the real window has not been exercised. Debug self-checks call the same controller directly. Confirm each key, and confirm that Stream Deck hotkeys arrive.
- **Sleep prevention and system sound moves.** The sound guard's logic is unit tested with a fake. Neither has run against the live system settings.
- **Inspector appearance.** The self-capture cannot draw macOS glass materials, so the inspectors were not visually checked. The sidebar was, in the running app on macOS 26.
- **Dropping tracks on the sidebar.** The sidebar's rows are now system list rows. Dropping library tracks on a service or on New Service…, and holding a drag on a service to open it, have not been tried since: automated drags never start a drag session.
- **Building a service.** New Service…, the editor's typed titles, Add Item and Add Section, the arrow buttons, Looks Like and Use, Duplicate, Save as Template and Delete were built against the model and compile, and the model is unit tested. Dragging a row onto another to reorder uses the Table's row drag with a string payload, the same mechanism as dragging a library track onto a service; confirm it works on the real rig. Confirm that clicking the outputs row at the bottom of the sidebar opens Settings on Outputs: it sends the standard `showSettingsWindow:` action.
- **The first launch.** The Welcome sheet shows only when settings.json has no `hasChosenServiceSource`. Run once with a fresh home to see it.

## Known limits

- House and cue are compared by device. An aggregate device that contains the house interface is not detected, so avoid using one as the cue output.
- A long Drive download during Make Local keeps copying in the background after the five-minute timeout message.
- Rebuilding with an ad hoc signature can make macOS ask for folder permissions again.

## Not in v1

- MIDI control with learn mode. Stream Deck works through keystrokes.
- Reordering cues in the Show view, and overriding points per cue instead of per track.
- Sharing one interface between house and cue on different outputs.
- Musical key detection. Key is a manual field.
- Undo for library edits.
- A red night theme.
- Developer ID signing and notarization.
- Syncing to a spare Mac. The data folder can be copied by hand.
- Choosing which duplicate file is the canonical one.
- Per-service-type rules for which items need playback.
- Reading PCO item notes, as distinct from the item description and details.
