# Cantator

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

The app ends up in `build/dd/Build/Products/Release/Cantator.app`. Copy it to `/Applications` so macOS keeps its folder permissions between runs. Rebuilding with an ad hoc signature can make macOS ask again.

## Tests

```bash
cd Packages/CantorCore && swift test
```

Those tests never touch real audio hardware. An opt-in set runs real Core Audio against virtual devices only. It needs BlackHole 2ch, plus a Pro Tools Audio Bridge device for the channel map case:

```bash
cd Packages/CantorCore && CANTOR_HARDWARE_TEST=1 swift test
```

## First-time setup

Everything is in **Cantator > Settings**.

### Outputs and console routing

1. Connect your audio interface and patch its outputs to a stereo pair of console channels.
2. In **Outputs > House**, choose the interface. On a multichannel interface, choose the output pair, such as 3-4.
3. In **Outputs > Cue**, choose a different device for headphones. The Mac's headphone jack works well. House and cue must be separate devices: Cantator refuses to arm otherwise.
4. Set the console channel trim using a loud track while the fader is down, then leave it. Tracks are matched to -18 LUFS, so levels stay consistent from cue to cue. Set the fader for the room.
5. Cantator applies a static gain only. It has no limiter and never changes level during a cue.

While a service is loaded, Cantator moves macOS alert sounds and the default output off the house device, if that's where they are, and restores them afterward. Other apps' notifications can still make sound on other devices. Turn on Do Not Disturb before the service: macOS doesn't let apps do that.

### Planning Center

Cantator reads your upcoming services in one of two ways, chosen in **Settings > Planning Center**. Sync only runs when you choose **Sync Now** or **Refresh**.

**Service Types** in the same pane lists every service type Cantator has seen. **Import all service types** is on at first. Turn it off and uncheck a type, such as weddings or funerals, and Sync Now skips it and the sidebar hides it. **Choose Service…** still lists every type, so one of those can be added by hand when it's needed, and it then stays in the sidebar.

**Claude connector (the default).** Cantator asks Claude Code, signed in to your Claude account, to read Planning Center through the Planning Center connector on that account.

1. At claude.ai, open **Settings > Connectors** and connect **Planning Center**, allowing Services.
2. In Terminal, run `claude auth login` so the Claude Code on this Mac uses the same account.
3. Choose **Sync Now**.

Claude may only use the connector's three read-only Services tools: service types, plans and plan items. Cantator reads the plans from the connector's own answers, not from what Claude writes, and checks each plan's item count, so a plan that comes back incomplete keeps its saved copy. Claude does see item titles and descriptions, which can include people's names. A sync reads the next four plans of every service type, can take a few minutes, and counts toward your Claude usage. Planning Center's admins are notified the first time someone connects an AI tool.

**Choose Service…** at the top of the sidebar's Services list shows every service from six weeks back to three weeks ahead, for every service type. Pick one and choose **Read Service** (or double-click it): Claude reads that one service's items and it opens, ready to match. Use it for a service further out than the sync reaches, or a past one you want to run again. A picked service stays in the sidebar while it is inside that window. The list is read the first time you open the picker each day; the refresh button reads it again. It uses the same source as sync, with the same token fallback.

The connector doesn't give attachment filenames, which help matching. Cantator keeps the ones from the last token sync.

**API token (the fallback).** If the connector can't be used (Claude Code is signed out, at its usage limit, or the connector isn't connected), Cantator syncs with a token instead and says so. Choose **API Token** to always use it.

1. Go to [api.planningcenteronline.com/oauth/applications](https://api.planningcenteronline.com/oauth/applications) and sign in.
2. Under **Personal Access Tokens**, create one.
3. In **Settings > Planning Center**, paste the Application ID and Secret.

Both values are stored only in the macOS Keychain.

### Claude (optional)

Cantator uses your Claude account, through Claude Code, for two things: filing new files, and ranking ambiguous matches when you choose **Resolve Ambiguous** in the Service view. Install [Claude Code](https://code.claude.com/docs) and sign in:

```bash
claude auth login
```

The **Claude** section at the bottom of the sidebar always shows whether Claude is connected, signed out, not found, turned off or at its usage limit, with what to do about it. Click it to check again. Cantator also checks at launch, when you switch back to it (for example after signing in in Terminal), every five minutes, and after every Claude request. **Settings > Claude** shows the same status, plus a Usage section: whether Claude is in use (and if not, why and what Cantator does instead), what it is doing right now, the last request with its time and result, and how many requests Cantator has made since it opened. No API key is involved, and requests count toward your Claude account's usage. Claude never gets file paths or audio, and nothing it suggests is applied until you accept it. When Planning Center syncs through the connector, Claude also reads item titles and descriptions there. Without Claude, new files are guessed from their names and matching works by name.

### Folders and new files

Cantator watches `~/Downloads`, `~/Desktop` and any Google Drive folders under `~/Library/CloudStorage`. Add others in **Settings > Folders**. The first scan makes macOS ask for permission to each location: allow these before a service.

When a new audio file arrives in a watched folder, Cantator asks Claude where it belongs and shows a **New File** pop-up with a title, a category (Choir, Special, Offertory and so on, the same tags as the library sidebar), and the upcoming service item it looks like it's for. Change anything, then **Accept**, **Later**, or **Not a Playback**. Accepting a service item confirms that match. Not a Playback moves the file to **Excluded**.

- The pop-up never appears while a service is loaded, a cue is armed or playing, or a preview is playing. Files wait in **New Files** in the sidebar until you unload.
- Files that arrive while Cantator is closed show up the next time it starts.
- Files already in a folder when you add it are not treated as new.
- Claude gets the filename, the two folders above it, the duration, embedded tags, the category names and the titles of upcoming items that still need a file.

### Stems

Stems and click tracks often sit in the same folders as playbacks. Cantator leaves them out of matching, the library lists and the New File pop-up. It treats a file as a stem when:

- its name says click, stems, BGVs, vox, drums, snare and so on,
- it is in a folder named Stems or Multitracks, or the folder above it is, or
- it is one of three or more files in one folder with the same length, and its name says bass, keys, guide, vocals and so on, or at least two files in that set are named as stems.

A name that says mix, full, master, playback, accompaniment, instrumental, split, key, with, without or no is never treated as a stem, so "Way Maker - Full Mix" and "Holy Forever No BGVs" stay in. Neither does a track confirmed for a service.

**Excluded** in the Library sidebar lists every file left out, with the reason. If a playback is missing from matching, find it there, preview it, and choose **This Is a Playback**. Cantator remembers that and never excludes it again. Cantator rechecks its own guesses on every scan, but never undoes yours.

Cantator never moves, renames or deletes your files. **Make Local** copies a track to `~/Music/Cantor`, which also downloads it if it's only in Drive.

### EQ

Some playbacks are mixed better than others. Each track has its own EQ, saved with it and used every time it plays, on the house output and in preview. Select a track in the library and choose **Edit EQ** in the inspector.

- Drag a numbered handle on the curve to move a band's frequency and gain. HP and LP are a high-pass and low-pass, off until you turn them on.
- Click a band button to select it, double-click to turn it on or off. Bands 1 to 6 can each be a low shelf, bell or high shelf.
- Turn the FREQ, Q, GAIN and OUT knobs by dragging up or down. Hold Option for fine moves, double-click to reset.
- **Preview** plays the track on the cue output, and every change is heard right away. **EQ On** switches to bypass so you can compare. **Reset** goes back to the track as mixed.
- Loudness matching measures the file as mixed, so use OUT to bring the level back after a big boost.
- Editing is locked in Show Mode, except the EQ. EQ changes are heard at once on the cue that is armed or playing, and saved with the track for next time.

## Running a service

**During the week**

1. Select the service in the sidebar and choose **Refresh** to pull the latest plan. If it isn't there, use **Choose Service…**.
2. Review each item that needs a track. Items whose notes say "tracks" are checked for you, and a strong match is put on them as **Auto-confirmed**. Check **Needs** for other items with playback, preview a candidate on your headphones, then choose **Confirm**. To change an automatic match, confirm another file or choose **Clear Match**.
3. In Library, set each track's end point and fade. Use **Preview Ending** to hear the last 15 seconds, and **Use** to accept the suggested end.
4. To play a track the plan doesn't list, add it from Library: **Add to Service** in the right-click menu or the track's details picks the service and the spot, or drag it onto a service in the sidebar to add it at the end. Hold the drag there for a moment and the service opens, so you can drop it on the item it should follow. **Remove from Service** in the item's details takes it out again.

**Before the service**

1. Choose **Load Service** to load every cue into memory.
2. Open **Pre-Service Check** and clear everything under **Must Fix**.
3. Plug in the Mac and keep the lid open. Closing the lid sleeps it.
4. Press Command-Shift-L to enter Show Mode. This locks editing, except the EQ, and enables the house transport.

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

Nothing plays until you arm and then press GO. Clicks and double-clicks never start audio. Stream Deck works by sending these keystrokes: Cantator's window must be the active one, and the state bar shows KEYS NOT FOCUSED when it isn't.

## Data

Everything is in `~/Library/Application Support/Cantor`, including `runlog.jsonl`, a record of what played and when.
