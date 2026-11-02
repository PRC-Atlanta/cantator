# Cantor

Native macOS playback for running choir and special-music tracks from the mixing console. It pulls the service from Planning Center, matches items to your files, and plays them through a two-step arm and go with clean, controlled endings.

See [DESIGN.md](DESIGN.md) for how it works, [DECISIONS.md](DECISIONS.md) for the judgment calls, and [NEXT_STEPS.md](NEXT_STEPS.md) for known limitations.

## Build and run

Requires macOS 15 or later and Xcode 16 or later. There are no third-party dependencies.

1. Open `Cantor.xcodeproj`.
2. Choose the **Cantor** scheme and press Run.

From the command line:

```bash
xcodebuild -project Cantor.xcodeproj -scheme Cantor -configuration Release -derivedDataPath build/dd build
```

The app ends up in `build/dd/Build/Products/Release/Cantor.app`. Copy it to `/Applications` so macOS keeps its folder permissions between runs. Rebuilding with an ad hoc signature can make macOS ask again.

## Tests

```bash
cd Packages/CantorCore && swift test
```

Those tests never touch real audio hardware. An opt-in set runs real Core Audio against virtual devices only. It needs BlackHole 2ch, plus a Pro Tools Audio Bridge device for the channel map case:

```bash
cd Packages/CantorCore && CANTOR_HARDWARE_TEST=1 swift test
```

## First-time setup

Everything is in **Cantor > Settings**.

### Outputs and console routing

1. Connect your audio interface and patch its outputs to a stereo pair of console channels.
2. In **Outputs > House**, choose the interface. On a multichannel interface, choose the output pair, such as 3-4.
3. In **Outputs > Cue**, choose a different device for headphones. The Mac's headphone jack works well. House and cue must be separate devices: Cantor refuses to arm otherwise.
4. Set the console channel trim using a loud track while the fader is down, then leave it. Tracks are matched to -18 LUFS, so levels stay consistent from cue to cue. Set the fader for the room.
5. Cantor applies a static gain only. It has no limiter and never changes level during a cue.

While a service is loaded, Cantor moves macOS alert sounds and the default output off the house device, if that's where they are, and restores them afterward. Other apps' notifications can still make sound on other devices. Turn on Do Not Disturb before the service: macOS doesn't let apps do that.

### Planning Center token

1. Go to [api.planningcenteronline.com/oauth/applications](https://api.planningcenteronline.com/oauth/applications) and sign in.
2. Under **Personal Access Tokens**, create one.
3. In **Settings > Planning Center**, paste the Application ID and Secret, then choose **Sync Now**.

Both values are stored only in the macOS Keychain.

### AI matching (optional)

Matching works without AI. To have Claude rank ambiguous matches, install [Claude Code](https://code.claude.com/docs) and sign in with your Claude account, then choose **Resolve Ambiguous** in the Service view:

```bash
claude auth login
```

**Settings > AI Matching** shows whether Cantor can see the sign-in. No API key is involved, and requests count toward your Claude account's usage. Cantor sends item titles, arrangement names, filenames and durations only, which can include a soloist's name if it's in the title or filename. You confirm every match either way.

### Folders

Cantor watches `~/Downloads`, `~/Desktop` and any Google Drive folders under `~/Library/CloudStorage`. Add others in **Settings > Folders**. The first scan makes macOS ask for permission to each location: allow these before a service.

Cantor never moves, renames or deletes your files. **Make Local** copies a track to `~/Music/Cantor`, which also downloads it if it's only in Drive.

## Running a service

**During the week**

1. Select the service in the sidebar and choose **Refresh** to pull the latest plan.
2. Review each item that needs a track. Check **Needs** for items with playback, preview a candidate on your headphones, then choose **Confirm**.
3. In Library, set each track's end point and fade. Use **Preview Ending** to hear the last 15 seconds, and **Use** to accept the suggested end.

**Before the service**

1. Choose **Load Service** to load every cue into memory.
2. Open **Pre-Service Check** and clear everything under **Must Fix**.
3. Plug in the Mac and keep the lid open. Closing the lid sleeps it.
4. Press Command-L to enter Show Mode. This locks editing and enables the house transport.

**During the service**

| Key | Action |
| --- | --- |
| Up / Down | Choose the next cue |
| A | Arm |
| Space | GO |
| F | End of song: fade with the track's saved fade |
| P | Hold, then Space to resume |
| M / Shift-M | Jump to the next or previous marker, while armed or held |
| `[` / `]` | Move the end point 1 s for this run only |
| H | Preview in headphones: the selected cue, or the next cue while one is armed or playing |
| D | Disarm. If the cue shows a mid-track start, this clears it |
| Return | Acknowledge a fault |
| Esc | Panic fade. Press twice to stop at once |

Nothing plays until you arm and then press GO. Clicks and double-clicks never start audio. Stream Deck works by sending these keystrokes: Cantor's window must be the active one, and the state bar shows KEYS NOT FOCUSED when it isn't.

## Data

Everything is in `~/Library/Application Support/Cantor`, including `runlog.jsonl`, a record of what played and when.
