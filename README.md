<div align="center">

<img src="Glint/Resources/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="128" alt="Glint icon">

# Glint

**Screenshots, screen recordings and annotations for macOS, right from the menu bar.**

![macOS 15+](https://img.shields.io/badge/macOS-15%2B-blue)
![Version 1.0](https://img.shields.io/badge/version-1.0-blue)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

<br>

**[Download Glint 1.0](../../releases/latest)** · free · macOS 15 or later · Apple silicon and Intel

<br>

<a href="https://ko-fi.com/kuhni"><img src="https://storage.ko-fi.com/cdn/kofi3.png?v=3" height="48" alt="Buy me a coffee on Ko-fi"></a>

</div>

---

Glint is a free, open-source screenshot and screen recording tool for the Mac. Capture any part of the screen,
annotate it, put it on a nice background, record a video or GIF, and drag the result straight into any app.

It's an independent alternative to apps like [CleanShot X](https://cleanshot.com), [Shottr](https://shottr.cc),
[Xnapper](https://xnapper.com), [Snagit](https://www.techsmith.com/snagit/), [Monosnap](https://monosnap.com) and
macOS's built-in Screenshot app. Glint is not affiliated with, endorsed by or connected to any of them; all product
names are trademarks of their respective owners.

> [!NOTE]
> Glint is free and open source, made by one person. Please [report bugs](../../issues/new/choose); questions and ideas
> are welcome in [Discussions](../../discussions).

## See it in action

https://github.com/user-attachments/assets/c00b964d-317a-4ded-8038-74ec53f49b71

All six features in under three minutes. Each one has its own short video in the [feature tour](#feature-tour) below,
together with the settings it offers. (The Tidewater team and its numbers are made up.)

## Opening Glint for the first time

> [!IMPORTANT]
> **macOS will block Glint the first time you open it. This is expected for now.** Glint isn't notarized by Apple yet,
> so macOS says "Apple could not verify 'Glint' is free of malware" and offers no way to open it from that message.

To open it, once:

1. Move **Glint.app** to your **Applications** folder and open it. When the message appears, click **Done**.
2. Open **System Settings → Privacy & Security** and scroll down to **Security**.
3. Click **Open Anyway** next to the message about Glint, and confirm with your password or Touch ID.

<details>
<summary>Or use Terminal, and why this happens</summary>

Instead of the steps above, you can remove the download flag from the app, then open it as usual:

```bash
xattr -dr com.apple.quarantine /Applications/Glint.app
```

**Why:** macOS only opens downloaded apps without asking if they're signed with a paid Apple Developer ID and checked
by Apple (notarization). Glint is a free project that doesn't have this yet. It doesn't mean Glint was found to contain
anything harmful; it means Apple hasn't checked it. Only do this with a copy from this repository's
[Releases](../../releases) page. All of the source code is here, and you can [build it yourself](#building-from-source)
if you prefer.

</details>

## Contents

- [See it in action](#see-it-in-action)
- [Opening Glint for the first time](#opening-glint-for-the-first-time)
- [Features](#features)
- [Feature tour](#feature-tour)
  - [Area screenshots and annotations](#area-screenshots-and-annotations)
  - [Scrolling Capture](#scrolling-capture)
  - [Capture Text](#capture-text)
  - [Studio Mode](#studio-mode)
  - [Capture History](#capture-history)
  - [Pin to the Screen](#pin-to-the-screen)
- [Requirements](#requirements)
- [Installation](#installation)
- [Getting started](#getting-started)
- [Updates](#updates)
- [Uninstalling](#uninstalling)
- [Privacy](#privacy)
- [Building from source](#building-from-source)
- [Contributing](#contributing)
- [Support the project](#support-the-project)
- [License](#license)
- [Acknowledgements](#acknowledgements)

## Features

Everything Glint does, in short. The [feature tour](#feature-tour) shows six of them in action, with their settings.

- **Capture:** area, window (on your wallpaper with padding and shadow, or transparent), full screen, previous area,
  self-timer, All-In-One (⇧⌘5), scrolling capture, freeze screen and crosshair with magnifier.
- **Capture Text (OCR):** copy the text in any part of the screen; also reads QR codes and barcodes.
- **Annotate:** arrows, shapes, text styles, counters, pen, highlighter (snaps to text lines), blur, pixelate,
  spotlight, a magnifier for enlarged callouts, a hand-drawn look for shapes, and added images.
- **Backgrounds:** gradients, your wallpaper or any image, padding, inset, shadow, rounded corners, alignment,
  aspect ratios and presets.
- **Crop & Resize:** ratios, exact sizes, rotate and flip, output size, and a zoom lens for placing handles to the
  pixel. Saved edits stay editable.
- **Record:** screen or window as video or GIF, with microphone and system audio, camera overlay, highlighted clicks
  and keystrokes, and Do Not Disturb while recording.
- **Video editor:** trim and cut, zooms, captions from your speech (transcribed on your Mac, as phrases or word by
  word), background presets, padding, corners and shadow, keyboard scrubbing, and export to MP4, MOV or GIF.
- **Studio Mode:** record the screen as an editable project: automatic zooms that follow the cursor, cursor size,
  style, smoothing and click effects, keystrokes and the camera, all adjustable after recording.
- **Quick Access:** a floating stack of your latest captures to copy, save, annotate, pin or drag anywhere. Pull a
  card down, swipe down with two fingers or click the bar above the stack to tuck it away; pull or swipe a card toward
  the screen edge to close it.
- **Export formats:** screenshots as PNG, JPEG, HEIC or TIFF.
- **Pin to the Screen** and **Capture History** to restore earlier captures.
- **Open images from Finder:** any PNG, JPEG, HEIC, TIFF, WebP or BMP opens in Annotate through **Open With**.
- **Automation:** the `glint` command (`glint fullscreen` takes a screenshot and prints its path) for scripts and AI
  agents, and `glint://` links for Shortcuts, Raycast and others. See [docs/command-line.md](docs/command-line.md).

## Feature tour

Each video shows one feature from start to finish. Below each video are the settings it uses, in **Settings** unless a
different place is named.

### Area screenshots and annotations

https://github.com/user-attachments/assets/648d695d-075c-4f3c-9bb5-960cc4afb7cd

Choose **Capture Area** in the menu bar (or press ⇧⌘4) and drag over any part of the screen. The capture lands in
**Quick Access** in the corner. From there you can copy it, save it, pin it, drag it into another app, or click the
pencil to open the editor. In the editor you add arrows, text and counters, highlight or blur private details, and put
everything on a background. Then you drag the result straight into a chat or document.

The same flow works for a **window** (press Space while selecting), the **full screen**, the **previous area**, a
**timer**, and **All-In-One** (⇧⌘5), which offers every mode in one place.

<details>
<summary><strong>Settings for screenshots, Quick Access and the editor</strong></summary>

**General**
- Export location, play sounds and the shutter sound, hide desktop icons while capturing.
- **After Capture**, separately for screenshots and recordings: show Quick Access, copy to the clipboard, save, open the
  editor, pin to the screen (recordings: open the video editor). Any combination is allowed.

**Screenshots**
- File format: PNG, JPEG, HEIC or TIFF. Convert to the sRGB profile, scale Retina screenshots to 1×, add a 1px border.
- A background preset applied to every screenshot, the timer interval, and showing the cursor (full screen and
  timer only).
- Freeze the screen while selecting; crosshair mode with a magnifier for pixel-exact selections.
- Window screenshots: on the wallpaper with padding, or transparent (hold ⇧ while capturing for a transparent one
  once), and the window's shadow. The wallpaper itself (your desktop picture, a color or an image) is set in
  **Wallpaper**.

**Quick Access**
- Position (left or right), move to the screen the pointer is on, and the size of the cards.
- Auto-close after an interval (it waits while an editor is open), close after dragging (hold ⌥ to keep the card),
  and what the Save button does (⌥-click always asks for a place).

**Annotate**
- Reverse arrow direction, select objects after placing them, smooth drawing, hand-drawn shapes, shadows on objects,
  grow the canvas to fit annotations, and remember whether the Background panel was open.
- Window: always on top, show a Dock icon, open editors as tabs in one window.

**Advanced:** the file name format (with date placeholders), or a name asked after every capture.

</details>

### Scrolling Capture

https://github.com/user-attachments/assets/ba06ce3b-a999-4ca8-97c5-806ef5617fbe

Choose **Scrolling Capture** in the menu bar and select the part of a window that scrolls, such as a web page, a chat
or a long document. Click **Start Capture**. Then either click **Auto-Scroll** and let Glint scroll for you, or scroll
slowly yourself. A live preview grows next to the selection while Glint stitches the page together. Click **Done** and
you have the whole page in one image. Vertical and horizontal scrolling both work.

<details>
<summary><strong>Settings and tips</strong></summary>

- The result follows **General → After Capture** like any screenshot, and uses the file format from **Screenshots**.
- **Auto-Scroll** needs the Accessibility permission. Glint asks for it the first time you use it.
- For a clean result, avoid animations or videos inside the selection, don't scroll too fast, and don't scroll back
  up while capturing. **How it works** in the capture bar explains this with short animations.

</details>

### Capture Text

https://github.com/user-attachments/assets/a7fa3704-0ad5-4ab6-9e64-f51926822386

Choose **Capture Text (OCR)** and select anything with text in it: a picture, a video, a slide or a PDF. The text is
copied as real, editable text, ready to paste. QR codes and barcodes are read too, and when the text contains a link,
the notification offers to open it. Text recognition runs on your Mac; nothing is uploaded.

<details>
<summary><strong>Settings (Advanced → Text Recognition)</strong></summary>

- **Language:** detect it automatically, or choose one.
- **Keep line breaks** as in the original, or join the lines into paragraphs.
- **Keep list formatting:** bullets become "-", numbering like "1." stays, and indented lines stay indented.
- **Detect links:** when the text contains a link, the notification offers to open it.
- **Copy text together with QR codes:** when off, only the code's content is copied.
- A pinned screenshot can do the same: right-click it and choose **Extract text**.

</details>

### Studio Mode

https://github.com/user-attachments/assets/1a822c6b-f416-4adb-83bb-af394b80aa07

Studio Mode records the screen, pointer, keystrokes and camera separately, so you polish the video *after* recording
instead of recording it again. Glint adds zooms that follow your clicks and typing. You can then:
- restyle the cursor;
- fine-tune every zoom;
- give each scene its own camera layout;
- add captions transcribed from your voice on your Mac.

Turn it on in the recording bar (**Record Screen** in the menu bar), record as usual, and the video editor opens with
everything editable.

<details>
<summary><strong>What you can change in the editor</strong></summary>

- **Cursor:** show or hide it, size, style (macOS, Bold, Light, Touch), movement (natural or smooth), press and ripple
  animations, hide it when it doesn't move or while typing.
- **Zooms:** each zoom on the timeline has its own level, length and animation. It can follow the cursor or stay on
  one spot. **Apply Zoom Level to All** changes every zoom at once.
- **Camera:** show or hide it, position, size, shape, flip. Camera actions on the timeline switch it between full size,
  resized and hidden for a scene. You can also make it shrink while zoomed in.
- **Captions:** Classic, Outline, Social Media or Minimal. Show them as phrases or word by word, highlight the spoken
  word, and edit or delete any caption. **Back to Where It Was Said** jumps to a caption's moment. The language can be
  chosen.
- **Keystrokes and clicks:** every click, drag, scroll, shortcut and typed word is on the timeline. Use it to find a
  moment, or remove what shouldn't be seen.
- **Everything from the regular video editor:** trim and cut, background, padding, corners and shadow, and export to
  MP4, MOV or GIF with resolution, quality and an estimated file size. Subtitles can be saved as .srt.

</details>

<details>
<summary><strong>Recording settings (Settings → Screen Recording)</strong></summary>

- **General:** controls while recording, countdown, dim the screen, recording time in the menu bar, remember the last
  selection, Do Not Disturb while recording.
- **Cursor and keystrokes:** show the cursor, highlight clicks (color, ring or filled, size), show keystrokes
  (position, size, display time).
- **Studio Mode:** automatic zooms on clicks, drags, right-clicks, typing (three or more keys in a row) and scrolling,
  following the cursor. The zoom level, and the style for new captions.
- **Video:** frame rate, maximum resolution, scale Retina videos to 1×.
- **Audio:** microphone and system audio, mono, and separate audio tracks.
- **GIF:** resolution, quality, and optimized GIFs.

</details>

### Capture History

https://github.com/user-attachments/assets/9ea8fa2a-11c8-4823-9d24-998817b56263

Nothing gets lost. **Capture History** in the menu bar opens a panel with all recent captures, newest first. Filter by
type (All, Screenshots, Videos, Studio, GIFs), move through them with the pointer or the arrow keys, and click one to
bring it back to Quick Access. Hold ⌥ while clicking to keep the panel open.

<details>
<summary><strong>Settings and shortcuts</strong></summary>

- **Keep history** (Settings → Advanced): 1, 3, 7, 14 or 30 days, or forever. Older captures are removed on their own,
  even while Glint stays open for weeks.
- Right-click a capture to open it in the editor (⌘E), pin it, Quick Look it (Space), copy it (⌘C), save it (⌘S), show
  it in Finder, restore it (Return) or delete it. You can also drag a capture straight into another app.
- **…** in the panel's corner has **Clear History**.
- Studio Mode recordings stay editable in the history: they keep their pointer, keys and camera.

</details>

### Pin to the Screen

https://github.com/user-attachments/assets/3976571e-c068-4261-a680-a2d5c5b53f9e

Keep a screenshot floating above everything else as a reference while you work. Pin it from Quick Access (the pin
button), from Capture History, as an automatic **After Capture** action, or open any image with **Pin to the Screen…**
in the menu bar.

<details>
<summary><strong>What a pin can do</strong></summary>

- Drag it to move it (or nudge it with the arrow keys, ⇧ for bigger steps). Scroll or pinch to zoom, and click the
  zoom level for the options.
- **Lock** makes it click-through: while the pointer is over a locked pin, the pin fades so you can work with what's
  behind it.
- Right-click it to open it in the editor, copy, share, extract its text, save it, send it to the back, change the
  zoom or opacity, or toggle its shadow, rounded corners and border.
- **Hide/Show Pinned Screenshots** hides all pins at once.
- Rounded corners, shadow and border for new pins are set in **Settings → Advanced → Pinned Screenshots**.

</details>

## Requirements

- macOS 15 Sequoia or later
- Apple silicon or Intel Mac

## Installation

### Download

1. Download `Glint-<version>.zip` from the [latest release](../../releases/latest).
2. Unzip it and move **Glint.app** to your **Applications** folder.
3. Open Glint. macOS blocks it the first time: follow [these steps](#opening-glint-for-the-first-time).
4. Glint lives in the menu bar; there's no Dock icon.

### With an AI agent

If you use an AI coding agent (Claude Code, Codex, Cursor, …), you can let it do the setup. Ask it:

> Help me set up Glint: https://github.com/TheOnlyKuhni/Glint/blob/main/docs/agent-setup.md

[docs/agent-setup.md](docs/agent-setup.md) walks the agent through downloading, the Gatekeeper step, permissions,
turning off Apple's shortcuts and a test capture. It asks you before changing anything.

### Homebrew

A Homebrew cask is planned.

### From source

See [Building from source](#building-from-source).

## Getting started

Glint asks for a permission when a feature first needs it:

| Permission | Used for |
|---|---|
| Screen Recording | Screenshots and recordings (required) |
| Microphone / Camera | Only if you turn them on for a recording |
| Accessibility / Input Monitoring | Only for showing keystrokes in recordings and for auto-scrolling |

Default shortcuts match macOS's own screenshot shortcuts:

| Shortcut | Action |
|---|---|
| ⇧⌘3 | Capture full screen |
| ⇧⌘4 | Capture area (press Space to pick a window) |
| ⇧⌘5 | All-In-One |
| ⌃⇧⌘4 | Capture area and copy to the clipboard |

### Turn off Apple's screenshot shortcuts

While macOS's own screenshot shortcuts are on, macOS takes these keys and Glint's shortcuts don't work. To turn
them off:

1. Open **System Settings → Keyboard**.
2. Click **Keyboard Shortcuts…** and choose **Screenshots** on the left.
3. Uncheck these:
   - **Save picture of screen as a file** (⇧⌘3)
   - **Save picture of selected area as a file** (⇧⌘4)
   - **Copy picture of selected area to the clipboard** (⌃⇧⌘4)
   - **Screenshot and recording options** (⇧⌘5)
4. Click **Done**. The change works right away.

**Copy picture of screen to the clipboard** (⌃⇧⌘3) has no Glint default, so you can leave it on. Glint's
**Settings → Shortcuts** shows a warning while any of the others is still on.

If you'd rather keep Apple's shortcuts, give Glint different ones in **Settings → Shortcuts**. Every shortcut can be
changed there.

## Updates

Glint updates itself with [Sparkle](https://sparkle-project.org). It checks once a day; you can also choose
**Check for Updates…** in the menu bar menu or turn automatic checks off in **Settings → General → Updates**.
Updates are signed, and Glint only installs updates signed with the project's key.

Builds you make from source check the same feed and would update to the official release. To turn that off, remove
the `SUPublicEDKey` value from `Config/Info.plist`.

## Uninstalling

**From the app:** open **Settings → Advanced → Uninstall Glint…**. Glint deletes its settings, Capture History,
saved edits and logs, turns off Launch at Login, resets its privacy permissions, moves itself to the Trash and quits.

**With the script** (if Glint no longer opens):

```bash
curl -fsSL https://raw.githubusercontent.com/TheOnlyKuhni/Glint/main/Tools/uninstall.sh | zsh
```

**By hand:** quit Glint, move `/Applications/Glint.app` to the Trash and delete:

| Location | Contents |
|---|---|
| `~/Library/Application Support/Glint` | Capture History and saved edits |
| `~/Library/Preferences/com.philippk.glint.plist` | Settings |
| `~/Library/Logs/Glint` | Log file |
| `~/Library/Caches/com.philippk.glint` | Update cache |
| `~/Library/HTTPStorages/com.philippk.glint` | Update-check data |
| `/usr/local/bin/glint` | The command line tool's link, if you installed it |

Then remove Glint from **System Settings → Privacy & Security** (Screen Recording, Microphone, Camera,
Accessibility, Input Monitoring) and **General → Login Items**. If you set up *Do Not Disturb while recording*,
delete the "Glint Focus On" and "Glint Focus Off" shortcuts in the Shortcuts app.

Screenshots and recordings you saved (by default on your Desktop) are never removed.

## Privacy

Glint works entirely on your Mac. It has no accounts, analytics or cloud upload. The only network request is the
update check, which downloads the release feed from GitHub. Captures stay in the folders you choose and in
`~/Library/Application Support/Glint`.

## Building from source

**Requirements:** Xcode 27 or later (the project uses the macOS 27 SDK and runs on macOS 15+).

```bash
git clone https://github.com/TheOnlyKuhni/Glint.git
cd Glint
open Glint.xcodeproj
```

1. In Xcode, select the **Glint** target → **Signing & Capabilities**.
2. Choose your own **Team**, and change the **Bundle Identifier** to something of your own
   (for example `com.yourname.glint`).
3. Press **⌘R**. Xcode fetches the Sparkle package on the first build.

Or build and launch from the terminal (after setting your team once in Xcode):

```bash
Tools/run.sh
```

Signing with a stable identity keeps the Screen Recording permission across rebuilds.

**Project layout:** `Glint/` holds the app sources, grouped by feature (`Capture`, `Annotate`, `Record`,
`VideoEditor`, `QuickAccess`, `Pin`, `History`, `Settings`, …). `Config/` has Info.plist and entitlements, `Tools/`
has build, release and uninstall scripts, and [`docs/RELEASING.md`](docs/RELEASING.md) explains how releases and
updates are published.

## Contributing

Bug reports, ideas and pull requests are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) first.

## Support the project

<div align="center">

Glint is free and always will be. If it saves you time and you'd like to say thanks, you can support it on Ko-fi.
It's completely voluntary and very much appreciated.

<a href="https://ko-fi.com/kuhni"><img src="https://storage.ko-fi.com/cdn/kofi3.png?v=3" height="48" alt="Buy me a coffee on Ko-fi"></a>

</div>

## License

Glint is released under the [MIT License](LICENSE).

## Acknowledgements

- [Sparkle](https://sparkle-project.org) for updates (MIT-style license, see
  [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)).
- Icons in the app are Apple's [SF Symbols](https://developer.apple.com/sf-symbols/), loaded from macOS at runtime
  and used under Apple's terms for apps on Apple platforms.
