# Cantator

Native macOS playback for running choir and special-music tracks from the mixing console. You build the service in Cantator, or pull it from Planning Center, give each item its file, and play them through a two-step arm and go with clean, controlled endings. No account is needed: Planning Center and Claude are both optional.

See [DESIGN.md](DESIGN.md) for how it works, [DECISIONS.md](DECISIONS.md) for the judgment calls, and [NEXT_STEPS.md](NEXT_STEPS.md) for known limitations.

## Build and run

Requires macOS 15 or later and Xcode 16 or later. There are no third-party dependencies.

1. Open `Cantor.xcodeproj`.
2. Choose the **Cantor** scheme and press Run.

From the command line:

```bash
xcodebuild -project Cantor.xcodeproj -scheme Cantor -configuration Release -derivedDataPath build/dd build
```

The app ends up in `build/dd/Build/Products/Release/Cantator.app`. Copy it to `/Applications` so macOS keeps its folder permissions between runs.

### Signing and notarizing

Release builds are signed with the Developer ID Application certificate for team 6RHHE8NEYA, with the hardened runtime and a secure timestamp, and no entitlements. That certificate's private key must be in the login keychain. Debug builds stay ad hoc signed.

Use `scripts/release.sh` (below) for anything you ship: Xcode leaves Sparkle's helper tools on Sparkle's own signature, and the script re-signs them with the Developer ID, which notarization requires. The steps below are what it does for the app itself.

To notarize a Release build, store an app-specific password once with `xcrun notarytool store-credentials`, then zip, submit, staple and check:

```bash
ditto -c -k --keepParent build/dd/Build/Products/Release/Cantator.app Cantator.zip
```

```bash
xcrun notarytool submit Cantator.zip --keychain-profile <profile> --wait
```

```bash
xcrun stapler staple build/dd/Build/Products/Release/Cantator.app
```

```bash
spctl --assess -vv --type execute build/dd/Build/Products/Release/Cantator.app
```

The last command should report "Notarized Developer ID". Zip the stapled app again to share it. After the first Developer ID build replaces an ad hoc one, macOS asks once more for folder access, and the Keychain asks once to let Cantator read the Planning Center credentials.

### Releasing an update

Cantator checks for updates with [Sparkle](https://sparkle-project.org). Its feed is the `appcast.xml` on the newest GitHub release of PRC-Atlanta/cantator, and updates are signed with a key kept in the login keychain under the account `cantator` (public key in `Config/Info.plist`). Back that key up: without it, installed copies can't take another update. Sparkle's `generate_keys -x <file>` exports it.

Releases run on GitHub, so no Mac's keychain is involved. Commit the notes as `ReleaseNotes/<version>.md` and push to main, then start the release workflow from the repository's Actions tab, or:

```bash
gh workflow run release.yml --repo PRC-Atlanta/cantator -f version=1.2.11
```

It builds on GitHub's macOS runner, signs with the Developer ID, notarizes, staples, writes the feed and publishes the release, in about ten minutes. The certificate, the notarization login and Sparkle's key are repository secrets, listed at the top of `.github/workflows/release.yml`, and each run puts them in a keychain it deletes when it finishes.

To build a release on a Mac instead, for example to try it before publishing, `scripts/release.sh` does it in one step: it builds with the version you give and a build number from the commit count, notarizes and staples, and writes the zip and feed to `build/releases/<version>/`. The notarytool profile defaults to `cantator`; set `NOTARY_PROFILE` for another. Run it on a clean, pushed commit:

```bash
scripts/release.sh 1.1 notes.md
```

Try the app it built, then publish. This tags the commit and creates the GitHub release:

```bash
scripts/release.sh 1.1 notes.md --publish
```

The notes are Markdown and appear in the update window. Without them, GitHub writes notes from the commits.

Installed copies check once a day and ask before installing; **Check for Updates…** in the Cantator menu checks now. Nothing is checked while a cue is armed or playing, in Show Mode or while a service loads, and no scheduled check runs while the Show view is open. An update chosen while a cue is engaged waits to relaunch until the show is idle. Debug builds never check.

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
3. In **Outputs > Cue**, choose the device for headphones. The Mac's headphone jack works well. On a multichannel interface such as Dante Virtual Soundcard, house and cue can share the device on different pairs, such as house on 1-2 and cue on 3-4. They can never share a pair: Cantator refuses to arm otherwise.
4. Set the console channel trim using a loud track while the fader is down, then leave it. Tracks are matched to -18 LUFS, so levels stay consistent from cue to cue. Set the fader for the room.
5. Cantator applies a static gain only. It has no limiter and never changes level during a cue.

While a service is loaded, Cantator moves macOS alert sounds and the default output off the house device, if that's where they are, and restores them afterward. Other apps' notifications can still make sound on other devices. Turn on Do Not Disturb before the service: macOS doesn't let apps do that.

### Services

The first launch asks one question: will you build services in Cantator, or sync them from Planning Center? The answer is in **Settings > Services** and can be changed any time. Building them here is the default for a fresh install. It needs no account, nothing leaves the Mac, and Planning Center and Claude stay out of the way: no Choose Service…, no sync button, no Planning Center or Claude panes. Choosing Planning Center brings them all back and turns Claude on; services can still be built by hand in that mode.

**New Service…** at the top of the sidebar's Services list (also File > New Service…, Command-N) takes a name such as "Sunday Morning", a date and time, and a start point: blank, a copy of another service's order, or a template. A copy or a template brings the sections and item titles, never the tracks, so last week's song can't play by mistake. Dropping library tracks on New Service… starts the service with them, each as an item of its own, already matched.

A service built here opens as an editor. **Add Item** and **Add Section** go after the selected row, or at the end. Titles and section names are typed in place, notes in the inspector. The **Track** checkbox says an item runs on a track. Rows move with the arrows at their right end, or by dragging one onto the row it should follow; the track travels with its item. Tracks come from the Library: drag one onto an item or onto the service, use **Add to Service** on a library track, or pick in the inspector. There, **Looks Like** lists library tracks that share words with the item's title, with the shared words as the reason, and **Use** takes one; search below it finds anything else. Nothing is assigned until you choose it. Each item shows **Ready**, **Loaded**, **Not downloaded**, **No end point**, **Suggested** or **No track**, in the show's colors.

In any service, Planning Center or built here, the selected item's **File** cell is a search box: type part of a song's title or file name, then click a result or pick one with the arrow keys and Return. A right-click on a row has its actions, such as **Use**, **Preview**, **Clear Match**, **Move Up** and **Delete Item**. A two-finger swipe left on a row shows its **Delete** button; swipe right to put it away. A deleted Planning Center item comes back with the next **Refresh** as Planning Center has it, and is matched like a new item, so a song whose file you chose before gets that file again; an item added here is gone for good.

The toolbar's **More** menu has **Duplicate for Next Week**, **Save as Template…** and **Delete Service…**. The name and date can be changed in the inspector when no item is selected. Once a service is over it folds under **Past Services** in the sidebar, where it can be opened again or copied, and leaves after eight weeks (**Settings > Services** changes that). **Load Service** works the same for every service.

The filter button beside **Services** in the sidebar limits the list to the next one, two, three, four or eight weeks. The window is counted from today, so it moves on by itself: with two weeks chosen, the sidebar always shows today through the same weekday two weeks out, and a line under the list says how many later services are not shown. The loaded service always shows. **All Upcoming** shows every service again.

For practice days that only load songs, pin a service: right-click it in the sidebar and choose **Pin Service**, or turn on **Pinned** in its inspector. A pinned service sits at the top of the services list with a pin, whatever its date. The filter never hides it, it never folds into Past Services, and neither its age nor a Planning Center sync removes it. **Unpin Service** puts it back by its date.

Show and Pre-Service Check stay at the top of the sidebar and the library at the bottom, with only the services scrolling between them. Under it the sidebar always shows the house and cue outputs, amber until both are set, connected and different. Clicking it opens **Settings > Outputs**.

### Planning Center

Shown when Planning Center is the chosen source. Cantator reads your upcoming services in one of two ways: with an API token when one is saved in **Settings > Planning Center**, and through the Claude connector otherwise. Sync only runs when you choose **Sync Now** or **Refresh**.

**Service Types** in the same pane lists every service type Cantator has seen. **Import all service types** is on at first. Turn it off and uncheck a type, such as weddings or funerals, and Sync Now skips it and the sidebar hides it. **Choose Service…** still lists every type, so one of those can be added by hand when it's needed, and it then stays in the sidebar.

**Claude connector (when no token is saved).** Cantator asks Claude Code, signed in to your Claude account, to read Planning Center through the Planning Center connector on that account.

1. At claude.ai, open **Settings > Connectors** and connect **Planning Center**, allowing Services.
2. In Terminal, run `claude auth login` so the Claude Code on this Mac uses the same account.
3. Choose **Sync Now**.

Claude may only use the connector's three read-only Services tools: service types, plans and plan items. Cantator reads the plans from the connector's own answers, not from what Claude writes, and checks each plan's item count, so a plan that comes back incomplete keeps its saved copy. Claude does see item titles and descriptions, which can include people's names. A sync reads the next four plans of every service type, can take a few minutes, and counts toward your Claude usage. Planning Center's admins are notified the first time someone connects an AI tool.

**Choose Service…** at the top of the sidebar's Services list shows every service from six weeks back to three weeks ahead, for every service type. Pick one and choose **Read Service** (or double-click it): Claude reads that one service's items and it opens, ready to match. Use it for a service further out than the sync reaches, or a past one you want to run again. A picked service stays in the sidebar while it is inside that window. The list is read the first time you open the picker each day; the refresh button reads it again. It uses the same source as sync, with the same token fallback.

The connector doesn't give attachment filenames, which help matching. Cantator keeps the ones from the last token sync.

**API token (used first whenever one is saved).** It is faster, gives attachment filenames and uses no Claude usage, so a saved token always goes first. If it stops working and Claude is on, Cantator uses the connector instead and says so. Without a token, a connector that can't be used (Claude Code signed out, at its usage limit, or the connector not connected) means no sync.

1. Go to [api.planningcenteronline.com/oauth/applications](https://api.planningcenteronline.com/oauth/applications) and sign in.
2. Under **Personal Access Tokens**, create one.
3. In **Settings > Planning Center**, paste the Application ID and Secret.

Both values are stored only in the macOS Keychain.

### Claude (optional)

Claude is its own switch in **Settings > Services**, in both modes: off by default when services are built here, on when Planning Center was chosen at first launch. Off, nothing about it is shown and Cantator guesses from names. On, the Claude pane and **Resolve Ambiguous** in the Service toolbar appear.

Cantator uses your Claude account, through Claude Code, for two things: filing new files, and ranking ambiguous matches when you choose **Resolve Ambiguous** in the Service view. Install [Claude Code](https://code.claude.com/docs) and sign in. On a Mac with only the Claude desktop app, Cantator uses the copy of Claude Code that app keeps for its Code tab; **Sign In** in **Settings > Claude** signs it in. Either way, sign in with:

```bash
claude auth login
```

**Settings > Claude** shows whether Claude is connected, signed out, not found, turned off or at its usage limit, with what to do about it. Cantator checks at launch, when you switch back to it (for example after signing in in Terminal), every five minutes, and after every Claude request. It also has a Usage section: whether Claude is in use (and if not, why and what Cantator does instead), what it is doing right now, the last request with its time and result, and how many requests Cantator has made since it opened. No API key is involved, and requests count toward your Claude account's usage. Claude never gets file paths or audio, and nothing it suggests is applied until you accept it. When Planning Center syncs through the connector, Claude also reads item titles and descriptions there. Without Claude, new files are guessed from their names and matching works by name.

### Folders and new files

Cantator watches `~/Downloads`, `~/Desktop` and any Google Drive folders under `~/Library/CloudStorage`. Add others in **Settings > Folders**. The first scan makes macOS ask for permission to each location: allow these before a service.

When new audio files arrive in a watched folder, Cantator lists them all in one **New Files** window. Each row has a **Playback** checkbox, a title, a tag (Choir, Special, Offertory and so on, the same tags as the library sidebar), and the upcoming service item it looks like it's for. With Claude on, Claude fills those in and says why in the last column; otherwise they are guessed from the file name and folder. Rows are grouped by folder, so a song's playback, parts and demo sit together. Change any row, or select several (Shift-click, Command-click, or Command-A) and use **Selected** or right-click to mark them **Playback** or **Not a Playback** or give them a tag. **Show** narrows the list to playbacks or to the rest. **Apply** files every row at once: playbacks get their title and tag, a service item confirms that match, and the rest move to **Excluded**. **Later** keeps them waiting.

With **Copy playbacks into ~/Music/Cantor** checked, as it is unless you uncheck it (Cantator remembers), Apply also copies every playback into `~/Music/Cantor`, downloading it from Drive first if it's only there, so it plays even if the original is moved or deleted. Copies run one at a time, wait while a cue is armed or playing, and the Library title says how many are left. A file that can't be copied still plays from where it is, and one alert at the end lists them. The originals stay where they are, and a copy is part of the same track, not a duplicate. Files marked Not a Playback are never copied.

**Sort with Claude** in the Library toolbar, or right-click, sends the selected tracks through the same window. Use it for files that were already in a folder when Cantator started watching it, which are never treated as new: select **All Tracks**, press Command-A, and choose **Sort with Claude**. The window opens at once and fills in as Claude answers, 25 files at a time. Tracks a service uses are playbacks already, so they are left out. Without Claude the button says **Sort**, and titles and tags are guessed from names.

**Settings > Services** has a second way: **Add them to the library quietly**. Then the window doesn't open on its own; files wait under **New Files** in the sidebar for a week, where clicking reviews them, and after that they are ordinary library tracks.

- The window never opens while a service is loaded, a cue is armed or playing, or a preview is playing. Files wait in **New Files** in the sidebar until you unload.
- Files that arrive while Cantator is closed show up the next time it starts.
- Claude gets the filename, the two folders above it, the duration, embedded tags, the tag names and the titles of upcoming items that still need a file.

### Tags

Tags group the library in the sidebar and the Simple view. **Tag** in the Library toolbar adds a tag to the selected tracks, or removes it when they all have it; **New Tag…** there makes a tag and adds it to them. **Edit Tags…**, in the same menu, in **File**, or on a tag in the sidebar, lists every tag with how many tracks have it: click a name to rename it, the trash button deletes it, and the field at the bottom adds one. A rename or delete changes every track that has the tag, and renaming onto another tag merges the two. Deleting a tag never removes tracks.

### Stems

Stems, click tracks, practice parts and demos often sit in the same folders as playbacks. Cantator leaves them out of matching, the library lists and New Files, without asking Claude. It treats a file as one when:

- its name says click, stems, BGVs, vox, drums, snare and so on, or PTX, practice, rehearsal or demo, as in "Thou Oh Lord - S PTX" or "Listening Demo",
- it is in a folder named Stems, Multitracks, Practice or Rehearsal, or the folder above it is, or
- it is one of three or more files in one folder with the same length, and its name says bass, keys, guide, vocals and so on, or at least two files in that set are named as stems.

A name that says mix, full, master, playback, accompaniment, instrumental, split, key, with, without or no is never treated as a stem, so "Way Maker - Full Mix" and "Holy Forever No BGVs" stay in. Neither does a track confirmed for a service.

**Excluded** in the Library sidebar lists every file left out, with the reason. If a playback is missing from matching, find it there, preview it, and choose **This Is a Playback**. Cantator remembers that and never excludes it again. Cantator rechecks its own guesses on every scan, but never undoes yours.

### Duplicates

The same song is often in more than one place, such as an MP3 in Downloads and the WAV in Drive, or a file downloaded twice as "Way Maker (1).mp3". Identical files are already one track. Files that are not identical but have the same name, apart from a copy number, "copy", a leading track number or a bitrate, and the same length within half a second, are copies: Cantator keeps one and moves the rest to **Excluded** with "Duplicate of" and the file it kept. It keeps the copy a service uses or that you chose, then the one with your end point, markers, tags or notes, then one on this Mac, then a WAV or AIFF, then one already in `~/Music/Cantor`. A different version, such as "Full Mix" and "Instrumental" or two keys, has a different name and is never treated as a copy.

**Duplicates** in the Library sidebar also lists tracks that only look like the same song: the same title and length within a second, under different file names. Select the one to use and choose **Keep This One**, and the others go to Excluded. **This Is a Playback** brings any of them back.

Cantator never moves, renames or deletes your files. **Make Local** copies a track to `~/Music/Cantor`, which also downloads it if it's only in Drive.

### Importing files

To add a file from somewhere Cantator doesn't watch, choose **Import…** in the Library toolbar or **File > Import Audio…** (Command-I), then pick one or more files. WAV, AIFF, FLAC, ALAC and CAF files are converted to m4a (AAC, 256 kbps stereo, 128 kbps mono) in `~/Music/Cantor`, under the original file's name. MP3 and AAC files are kept as they are, because converting an already compressed file again only loses quality: an MP3 is copied, and an m4a holding AAC is passed through unchanged. An m4a holding ALAC is converted like any other lossless file. Files above 48 kHz are converted to 48 kHz, and files with more than two channels are mixed down to stereo. Title, artist, album, genre and comment tags are kept. The original is left where it was.

From a movie (MOV, MP4 or M4V), only the audio is imported: the first audio track, which is the main mix. When that audio is already AAC, as it usually is, it is copied out without converting it again.

Some file types, such as MKV, AVI, WebM, OGG and WMA, need FFmpeg. When FFmpeg is installed, Cantator uses it for those files; when it isn't, Import says FFmpeg is needed for that file. Cantator runs FFmpeg in a sandbox: no network, no system services, no other programs, and file writes only in a temporary folder of its own.

While it converts, the Import button and the Library's subtitle show the file and how far it has got, such as "Importing 2 of 5 · 43%". Files are converted one at a time; files chosen while others convert are added to the end. A file already converting finishes, but the next one waits while a cue is armed or playing or Show Mode is on, and the button shows "Import paused" until the show is idle.

Imported files then show in **New Files** like any new arrival, and wait in **New Files** while a service is loaded. Import can't be started in Show Mode or while a cue is armed or playing.

## EQ

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
3. In Library, set each track's end point and fade. A track that ends in two seconds or more of silence shows an amber **End Point** panel under its waveform with the last 20 seconds drawn large: click or drag there to set the end, **Preview End** to hear it, or **Use** to end where the sound stops. A track with sound to its last two seconds needs no end point.

Every preview button, including the headphones on a candidate, becomes **Stop** while it plays: press it again to stop.
4. To play a track the plan doesn't list, add it from Library: **Add to Service** in the right-click menu or the track's details picks the service and the spot, or drag it onto a service in the sidebar to add it at the end. Hold the drag there for a moment and the service opens, so you can drop it on the item it should follow. **Remove from Service** in the item's details takes it out again.

**Before the service**

1. Choose **Load Service** to load every cue into memory.
2. Open **Pre-Service Check** and clear everything under **Must Fix**. A yellow mark next to it in the sidebar means it found something. Click an issue to go to the service item it's about, or to Settings for an output problem.
3. Plug in the Mac and keep the lid open. Closing the lid sleeps it.
4. Open **Show**. Arm and GO work there right away. Clicking anything else in the sidebar disarms an armed cue.
5. To lock editing too, press Command-Shift-L for Show Mode. It locks everything except the EQ, and the sidebar turns into the service's program so you can follow along. The cue the show is on is marked and kept in view.

To do steps 1, 4 and 5 at once, double-click the service in the sidebar: it loads, the Show view opens and Show Mode turns on. Right-click it for **Load and Enter Show Mode** or **Load Service**.

**During the service**

| Key | Action |
| --- | --- |
| Up / Down, or click a cue | Choose the next cue, in the cue list or the sidebar's program, while nothing is armed or playing |
| A | Arm. Pressing it again while a cue is armed or playing does nothing |
| Space | GO |
| F | End of song: fade with the track's saved fade |
| P | Hold, then Space to resume |
| M / Shift-M | Jump to the next or previous marker, while armed or held |
| `[` / `]` | Move the end point 1 s and save it with the track, so the next time the song plays it ends there too. With nothing armed they move the pointed cue's end; armed or playing, the run hears it at once. `]` during the automatic end fade brings the level back and extends the run |
| H | Preview in headphones: the selected cue, or the next cue while one is armed or playing |
| D | Disarm. If the cue shows a mid-track start, this clears it |
| Return | Acknowledge a fault |
| Esc | Panic fade. Press twice to stop at once |

Nothing plays until you arm and then press GO. Clicks and double-clicks never start audio. Stream Deck works by sending these keystrokes: Cantator's window must be the active one, and the state bar shows KEYS NOT FOCUSED when it isn't.

## Data

Everything is in `~/Library/Application Support/Cantor`, including `runlog.jsonl`, a record of what played and when.
