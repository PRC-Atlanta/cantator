# Decisions

Calls made without asking, with the reason. Design-level conflicts between proposals are in the table at the top of DESIGN.md.

- **Name**: Cantor, the person who leads singing. The repo stays `live-audio-player`.
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
- **LLM provider**: Anthropic Claude over plain HTTPS, because no official Swift SDK exists. Optional. Without a key, string matching still works.
- **LLM model**: `claude-opus-5-5` at low effort, changeable in Settings. Server-side refusal fallback is on (`fallbacks: "default"`).
- **Songs default to Needs Playback**: an extra row costs one click, a missed cue costs the moment. A choice is remembered per song.
- **Scores cap at 0.97 for string and LLM matches**: 100% would read as certainty, and nothing is auto-confirmed anyway.
- **Hardware tests are opt-in and use virtual devices only**: `swift test` alone never opens an audio device.
- **`SelfCheck` is compiled in Debug only**: it drives the real flow with a throwaway home and virtual devices.
- **Sleep with a cue armed or playing counts as device loss**: wake always lands in a fault the operator acknowledges, never in sound.
- **Transport keys are not menu shortcuts**: a bare-key shortcut would fire from a text field in Settings. The keys are shown in the menu titles instead.
