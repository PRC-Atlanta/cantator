# Decisions

Calls made without asking, with the reason. Design-level conflicts between proposals are in the table at the top of DESIGN.md.

- **Name**: Cantator, after cantor, the person who leads singing. The repo stays `live-audio-player`. The Xcode project, target, scheme and `CantorCore` package keep the old name, and so do the bundle ID, `~/Library/Application Support/Cantor`, `~/Music/Cantor` and the keychain item, so renaming the app loses no library, token or folder permission.
- **Unsandboxed, ad hoc signed**: single-operator tool. Sandbox bookmarks can go stale when Drive remounts, and changing the system alert device needs no entitlement outside the sandbox. Not App Store distributable.
- **macOS 15 minimum**: gives `Synchronization.Atomic` for render-thread state with no C shim.
- **Logic in a local Swift package**: `swift test` runs without launching the app, so tests can never touch real audio output.
- **Swift language mode 5**: render-thread code uses unsafe pointers on purpose. Strict mode would add noise without improving it.
- **No third-party dependencies**: nothing to break or update before a Sunday.
- **Originals are never moved, renamed or deleted**: Make Local copies to `~/Music/Cantor`, so Drive sharing keeps working.
- **Points are per track, not per cue** in v1.
- **Only one house cue at a time**: arming while something plays is refused. Choir playback has no crossfades.
- **No marker jumps while live**: Hold first, then jump, then GO. A jump while the house hears it would be a surprise.
- **Hold resumes through GO**, so a stray key cannot restart a held track.
- **Panic fade is 1.5 s, adjustable in Settings. End-of-song uses the track's saved fade.**
- **A manual fade that would run past the end marker is shortened to land on it.**
- **Fade curve**: equal-power cosine. It sounds even and reaches exact silence.
- **Suggested end = last point above -50 dBFS, and it is not automatically saved**: the operator has to accept it, because "has an end point" should mean a person checked it.
- **AI uses the operator's Claude account, not an API key**: Cantator runs their installed, unmodified Claude Code (`claude -p`) with its existing login. API variables are removed from its environment, and a Claude Code set up with an API key is refused. Optional: name matching works without it.
- **This is for the owner's own use**: Anthropic's terms say products built for other people should use API keys and may not route requests through subscription credentials on users' behalf. If Cantator is ever given to anyone else, this part has to change.
- **Claude Code call**: no tools, no settings, no MCP servers, no saved session, low effort, from an empty folder, with the prompt on stdin. `--bare` is not used because it skips the account login.
- **Model**: blank uses the account's default, changeable in Settings.
- **Cantator watches the folders, Claude only reads names**: Claude gets no file system access. Cantator sends it filenames, two folder names, durations and tags, which is all a classifier could use anyway since it cannot hear the audio.
- **Categories are library tags**: the pop-up's category is the same tag that makes a library sidebar section, so there is one way to group tracks. Defaults are choir, special, offertory, prelude, postlude, children and walk-in, plus any tag already in use.
- **"New" means arrived after Cantator started watching that folder**, by the file's added-to-folder date. Otherwise adding a folder, or the first run, would put every existing file in front of the operator.
- **A loaded service holds all pop-ups**, even between songs. Loading is the signal that the service has started. Claude may still be asked while a service is loaded and idle, so pop-ups are ready the moment it is unloaded.
- **Stems are found by Cantator, not Claude**: names, folders and same-length sets are on disk and free to check, and a stem set is clearest when seen as a set, which a batch of filenames sent to Claude may split. Exclusion only hides a file from matching and lists, so a wrong guess costs a click in Excluded, while a missed stem only adds a candidate the operator still has to confirm.
- **EQ is static and per track**: a high-pass, six bell or shelf bands and a low-pass at 12 dB per octave, plus output gain. No dynamics, sidechain or mid/side: the job is fixing a mix that is too boomy or dull, not mastering. RBJ biquads in double precision run inside the playback kernel, so nothing is rendered ahead and an EQ costs nothing while flat.
- **EQ edits reach preview at once and house at the next arm**: preview gets new coefficients through the kernel's command ring while it plays, so the operator hears each knob move. A cue already armed or playing keeps the EQ it started with, like every other track edit.
- **Loudness matching measures the file as mixed**: the EQ does not change the matched gain. A big boost can raise the level and the peaks, so the OUT knob is there to bring it back.
- **Accepting a suggested service item confirms the match**: the operator is looking at it and pressing Accept, which is the confirmation the rule requires.
- **Claude status lives in the sidebar**: always visible while preparing, hidden in Show Mode where it doesn't matter. Amber only when something needs fixing, never green, because green means LIVE. The check is `claude auth status`, which uses no account usage, and it is skipped while a cue is armed or playing.
- **Copy to ~/Music/Cantor defaults on for Downloads and Desktop**, since those get cleaned out.
- **Songs default to Needs Playback**: an extra row costs one click, a missed cue costs the moment. A choice is remembered per song.
- **Scores cap at 0.97 for string and LLM matches**: 100% would read as certainty, and nothing is auto-confirmed anyway.
- **Hardware tests are opt-in and use virtual devices only**: `swift test` alone never opens an audio device.
- **`SelfCheck` is compiled in Debug only**: it drives the real flow with a throwaway home and virtual devices.
- **Sleep with a cue armed or playing counts as device loss**: wake always lands in a fault the operator acknowledges, never in sound.
- **Transport keys are not menu shortcuts**: a bare-key shortcut would fire from a text field in Settings. The keys are shown in the menu titles instead.
