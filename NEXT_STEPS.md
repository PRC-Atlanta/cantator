# Next steps

## Test on the real rig before relying on it

These could not be tested in development.

- **Google Drive placeholders.** Detection uses `lstat` flags, which is the documented signal for dataless files, but no real Drive placeholder was tested. Check that a cloud-only file shows as not downloaded, and that Make Local downloads it.
- **A physical audio interface.** The audio path and channel map were tested on virtual devices (BlackHole and Pro Tools Audio Bridge). Confirm that output pairs route correctly on your interface, because channel map behavior varies by driver.
- **Unplugging the interface during playback.** Fault handling was tested by simulating the loss, not by pulling a cable.
- **Planning Center with a real token.** The client was tested against stubbed responses built from the documented API. No request has reached the live API.
- **Claude matching with a real key.** The request and response were tested with fixtures only.
- **MP3 decoding.** WAV and AAC were tested with real files. MP3 goes through the same Apple decoder, but no real MP3 was tested.
- **Keyboard control.** Key handling in the real window has not been exercised. Debug self-checks call the same controller directly. Confirm each key, and confirm that Stream Deck hotkeys arrive.
- **Sleep prevention and system sound moves.** The sound guard's logic is unit tested with a fake. Neither has run against the live system settings.
- **Sidebar and inspector appearance.** The self-capture cannot draw macOS glass materials, so these were not visually checked.

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
