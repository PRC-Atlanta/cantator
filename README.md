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

### Claude (optional)

Cantor uses your Claude account, through Claude Code, for two things: filing new files, and ranking ambiguous matches when you choose **Resolve Ambiguous** in the Service view. Install [Claude Code](https://code.claude.com/docs) and sign in:

```bash
claude auth login
```

The **Claude** section at the bottom of the sidebar always shows whether Claude is connected, signed out, not found, turned off or at its usage limit, with what to do about it. Click it to check again. Cantor also checks at launch, when you switch back to it (for example after signing in in Terminal), every five minutes, and after every Claude request. **Settings > Claude** shows the same status, plus a Usage section: whether Claude is in use (and if not, why and what Cantor does instead), what it is doing right now, the last request with its time and result, and how many requests Cantor has made since it opened. No API key is involved, and requests count toward your Claude account's usage. Claude never gets file paths, notes or audio, and nothing it suggests is applied until you accept it. Without Claude, new files are guessed from their names and matching works by name.

### Folders and new files

Cantor watches `~/Downloads`, `~/Desktop` and any Google Drive folders under `~/Library/CloudStorage`. Add others in **Settings > Folders**. The first scan makes macOS ask for permission to each location: allow these before a service.

When a new audio file arrives in a watched folder, Cantor asks Claude where it belongs and shows a **New File** pop-up with a title, a category (Choir, Special, Offertory and so on, the same tags as the library sidebar), and the upcoming service item it looks like it's for. Change anything, then **Accept**, **Later**, or **Not a Playback**. Accepting a service item confirms that match. Not a Playback moves the file to **Excluded**.

- The pop-up never appears while a service is loaded, a cue is armed or playing, or a preview is playing. Files wait in **New Files** in the sidebar until you unload.
- Files that arrive while Cantor is closed show up the next time it starts.
- Files already in a folder when you add it are not treated as new.
- Claude gets the filename, the two folders above it, the duration, embedded tags, the category names and the titles of upcoming items that still need a file.

### Stems

Stems and click tracks often sit in the same folders as playbacks. Cantor leaves them out of matching, the library lists and the New File pop-up. It treats a file as a stem when:

- its name says click, stems, BGVs, vox, drums, snare and so on,
- it is in a folder named Stems or Multitracks, or the folder above it is, or
- it is one of three or more files in one folder with the same length, and its name says bass, keys, guide, vocals and so on, or at least two files in that set are named as stems.

A name that says mix, full, master, playback, accompaniment, instrumental, split, key, with, without or no is never treated as a stem, so "Way Maker - Full Mix" and "Holy Forever No BGVs" stay in. Neither does a track confirmed for a service.

**Excluded** in the Library sidebar lists every file left out, with the reason. If a playback is missing from matching, find it there, preview it, and choose **This Is a Playback**. Cantor remembers that and never excludes it again. Cantor rechecks its own guesses on every scan, but never undoes yours.

Cantor never moves, renames or deletes your files. **Make Local** copies a track to `~/Music/Cantor`, which also downloads it if it's only in Drive.

### EQ

Some playbacks are mixed better than others. Each track has its own EQ, saved with it and used every time it plays, on the house output and in preview. Select a track in the library and choose **Edit EQ** in the inspector.

- Drag a numbered handle on the curve to move a band's frequency and gain. HP and LP are a high-pass and low-pass, off until you turn them on.
- Click a band button to select it, double-click to turn it on or off. Bands 1 to 6 can each be a low shelf, bell or high shelf.
- Turn the FREQ, Q, GAIN and OUT knobs by dragging up or down. Hold Option for fine moves, double-click to reset.
- **Preview** plays the track on the cue output, and every change is heard right away. **EQ On** switches to bypass so you can compare. **Reset** goes back to the track as mixed.
- Loudness matching measures the file as mixed, so use OUT to bring the level back after a big boost.
- Editing is locked in Show Mode. A cue that is already armed or playing keeps its EQ until it is armed again.

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
| `[` / `]` | Move the end point 1 s for this run only. `]` during the automatic end fade brings the level back and extends the run |
| H | Preview in headphones: the selected cue, or the next cue while one is armed or playing |
| D | Disarm. If the cue shows a mid-track start, this clears it |
| Return | Acknowledge a fault |
| Esc | Panic fade. Press twice to stop at once |

Nothing plays until you arm and then press GO. Clicks and double-clicks never start audio. Stream Deck works by sending these keystrokes: Cantor's window must be the active one, and the state bar shows KEYS NOT FOCUSED when it isn't.

## Data

Everything is in `~/Library/Application Support/Cantor`, including `runlog.jsonl`, a record of what played and when.
