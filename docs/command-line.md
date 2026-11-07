# Automating Glint

Glint can be controlled from outside the app in two ways, with the same commands:

- **The `glint` command**, for Terminal, scripts and AI agents. It waits until Glint is done and prints the result:
  `glint fullscreen` prints the new screenshot's path.
- **`glint://` links**, for Shortcuts, Raycast, Alfred or anything else that can open a URL:
  `glint://capture-fullscreen`. A link doesn't return anything.

Both need **Settings → Advanced → API → Allow URL scheme API** to be on (it is by default), and the **Screen
Recording** permission for captures.

## The `glint` command

### Installing

The tool is inside the app, at `/Applications/Glint.app/Contents/Resources/glint`, and works from there. To type just
`glint`, link it into `/usr/local/bin`, either way (both ask for your password):

- In Glint: **Settings → Advanced → API → Command line tool → Install…**
- In Terminal: `/Applications/Glint.app/Contents/Resources/glint install`

The link points into the app, so it keeps working when Glint updates itself.

### Using it

```bash
glint <command> [file] [--timeout <seconds>] [--no-wait]
```

- It starts Glint if it isn't running.
- `--timeout`: how long to wait for Glint. 20 seconds by default, 10 minutes for commands where someone selects
  something on screen.
- `--no-wait`: send the command and return right away, without a result.
- Exit status: `0` done, `1` cancelled or failed (the reason goes to stderr), `2` no answer from Glint.

```bash
glint annotate "$(glint fullscreen)"   # screenshot, then open it in the editor
cp "$(glint last)" ~/Desktop/          # copy the newest capture
glint record                           # select the area and click Record …
glint record                           # … then stop: prints the .mp4
```

## Commands

The first column is the `glint://` command; `glint` accepts it too (`glint toggle-overlays`), and has the short
names in the second column. **Select** means someone has to select an area or window on screen, so an agent can't
finish it alone.

### Screenshots and text

| Command | `glint` | What it does | `glint` prints |
|---|---|---|---|
| `capture-fullscreen` | `fullscreen` | The screen the pointer is on, right away | the file |
| `capture-previous-area` | `previous` | The last captured area, right away (no area yet: like `capture-area`) | the file |
| `capture-area` | `area` | Select an area; Space switches to picking a window | the file |
| `capture-window` | `window` | Select a window | the file |
| `self-timer` | `timer` | Select an area; captured after the timer (5 s by default) | the file |
| `capture-area-copy` | | Select an area; only copied to the clipboard | the file |
| `capture-area-save` | | Select an area; only saved to the export location | the file |
| `capture-area-annotate` | | Select an area; opens in the editor | the file |
| `capture-area-pin` | | Select an area; pinned to the screen | the file |
| `scrolling-capture` | `scrolling` | Select an area, then scroll to capture more | the file |
| `all-in-one` | | The All-In-One tool (select) | the file |
| `capture-text` | `text` | Select an area; its text or QR code is copied | the text |
| `capture-text-with-line-breaks` | | The same, keeping line breaks | the text |
| `capture-text-without-line-breaks` | | The same, joining lines | the text |

### Recordings

| Command | `glint` | What it does | `glint` prints |
|---|---|---|---|
| `record-screen` | `record` | Select an area or window and click Record. While recording, it stops | the file, when stopping |
| `record-studio` | `studio` | The same in Studio Mode; opens in the video editor when it stops | the file, when stopping |
| `pause-recording` | `pause` | Pauses or resumes the recording | |
| `restart-recording` | `restart` | Throws away what was recorded so far and starts again | |
| `toggle-camera-fullscreen` | | The camera overlay to full screen and back | |

Recordings are `.mp4` (or `.gif`). A Studio Mode recording has a `Studio` folder next to its video.

### Files

These take an absolute path. Without one, an Open dialog asks for the file.

| Command | `glint` | What it does |
|---|---|---|
| `open-annotate` | `annotate <file>` | Opens an image in the screenshot editor (PNG, JPEG, HEIC, TIFF, WebP, BMP) |
| `open-video-editor` | `edit-video <file>` | Opens a video in the video editor, or a GIF in the GIF trimmer |
| `pin` | `pin <file>` | Pins an image to the screen |
| `annotate-file` | | Choose an image to open in the editor |
| `pin-image` | | Choose an image to pin |

### Everything else

The "last capture" commands only know captures made since Glint started.

| Command | `glint` | What it does |
|---|---|---|
| `restore-last-capture` | | Shows the last capture in Quick Access again |
| `annotate-last-screenshot` | | Opens the last capture in the editor |
| `pin-last-screenshot` | | Pins the last capture |
| `annotate-clipboard` | | Opens the image on the clipboard in the editor |
| `toggle-overlays` | | Hides or shows the Quick Access cards |
| `save-all-overlays` | | Saves every Quick Access card to the export location and closes them |
| `close-all-overlays` | | Closes every Quick Access card |
| `toggle-pins`, `close-all-pins` | | Hides/shows or closes the pinned screenshots |
| `toggle-desktop-icons` | | Hides or shows the desktop icons |
| `open-history` | | Opens the Capture History |
| `open-settings` | `settings` | Opens Glint's settings |
| | `last`, `history [n]` | Prints the newest capture's path, or the newest n (default 10) |
| | `install` | Links the tool to `/usr/local/bin/glint` |

## `glint://` links

The command is the link's host, a file goes in `filepath` (URL-encoded, so a space is `%20`):

```bash
open -g "glint://capture-fullscreen"
open -g "glint://open-annotate?filepath=/Users/me/Desktop/My%20Shot.png"
```

`open` hands the link to macOS, which passes it to Glint (and starts Glint first if needed). `-g` keeps your current
app in front. Good to know:

- A link sent while Glint is still starting can get lost. Start it first (`open -a Glint`) and wait a few seconds.
- Glint doesn't answer a link. An unknown command beeps. A capture that's still running ignores the next one.
- To find the result, look at the newest file in the Capture History (below), or use the `glint` command instead.

## Where captures go

Every capture goes into the Capture History, one folder per capture:

```
~/Library/Application Support/Glint/History/<id>/<name>.<png|jpg|heic|tiff|mp4|gif>
```

What else happens follows **Settings → General → After Capture** (by default: show Quick Access, and copy
screenshots to the clipboard); the `capture-area-copy`, `-save`, `-annotate` and `-pin` commands do only their own
action. Saved captures also go to the export location (the Desktop by default). The history is cleared after
**Settings → Advanced → Keep history** (1 week by default), so copy files you want to keep.

## Settings with `defaults`

There's no command for settings. They're macOS preferences in the `com.philippk.glint` domain. Quit Glint before
changing them, so it doesn't write its own values back, and open it again afterwards:

```bash
osascript -e 'quit app "Glint"'
defaults write com.philippk.glint screenshots.format -string jpeg
open -a Glint
```

| Key | Type | Values (default first) |
|---|---|---|
| `afterCapture.<action>.screenshot` | bool | actions: `showQuickAccess` (on), `copyToClipboard` (on), `save`, `openAnnotate`, `pin` (off) |
| `afterCapture.<action>.recording` | bool | actions: `showQuickAccess` (on), `copyToClipboard`, `save`, `openVideoEditor` (off) |
| `exportLocation` | string | empty (the Desktop) or a folder path |
| `screenshots.format` | string | `png`, `jpeg`, `heic`, `tiff` |
| `screenshots.showCursor` | bool | `false`, `true` |
| `quickAccess.position` | string | `left`, `right` |
| `quickAccess.autoClose` | bool | `false`, `true` |
| `quickAccess.autoCloseInterval` | int | `30`; also 5, 10, 15, 60, 120, 300 (seconds) |
| `rec.frameRate` | int | `60`, `30`, `24` |
| `rec.showCursor` | bool | `true`, `false` |
| `advanced.historyDays` | int | `7`; also 1, 3, 14, 30, or `0` to keep everything |
| `advanced.allowURLScheme` | bool | `true`, `false` |

Shortcuts are easier to change in **Settings → Shortcuts**.

## For AI agents

- Use the `glint` command. Without the link installed, call it by its full path:
  `/Applications/Glint.app/Contents/Resources/glint`.
- `fullscreen` and `previous` work without the user. Everything marked **select** needs them: tell them what to
  select, and the command returns when they're done (or prints "Cancelled.").
- Run one capture at a time; a second one while the first is running answers "busy".
- If a command gets no answer, check `pgrep -x Glint`, the "Allow URL scheme API" setting and the Screen Recording
  permission. Glint logs every command it receives to `~/Library/Logs/Glint/glint.log`.

## How the `glint` command works

`glint` is a short zsh script. It sends the `glint://` link with `open -g` and adds `reply=<id>`. When the command is
done, Glint writes a one-line answer to `$(getconf DARWIN_USER_TEMP_DIR)glint-cli/<id>` (`file <path>`,
`text <text>`, `recording`, `ok`, `cancelled`, `busy` or `error <message>`); the script prints it and removes the
file. Glint only writes inside that folder, and only for an id made of letters, digits and dashes.
