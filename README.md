<div align="center">

<img src="Glint/Resources/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="128" alt="Glint icon">

# Glint

**Screenshots, screen recordings and annotations for macOS, right from the menu bar.**

![macOS 15+](https://img.shields.io/badge/macOS-15%2B-blue)
![Version 0.1 beta](https://img.shields.io/badge/version-0.1%20beta-orange)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Ko-fi](https://img.shields.io/badge/Ko--fi-support-ff5e5b?logo=kofi&logoColor=white)](https://ko-fi.com/kuhni)

</div>

---

Glint is a free, open-source screenshot and screen recording tool for the Mac. Capture any part of the screen,
annotate it, put it on a nice background, record a video or GIF, and drag the result straight into any app.

It's an independent alternative to apps like [CleanShot X](https://cleanshot.com), [Shottr](https://shottr.cc),
[Xnapper](https://xnapper.com), [Snagit](https://www.techsmith.com/snagit/), [Monosnap](https://monosnap.com) and
macOS's built-in Screenshot app. Glint is not affiliated with, endorsed by or connected to any of them; all product
names are trademarks of their respective owners.

> [!NOTE]
> Glint is in **beta (0.1)**. Expect rough edges, and please [report bugs](../../issues/new/choose).

## Contents

- [Features](#features)
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

- **Capture:** area, window (on your wallpaper with padding and shadow, or transparent), full screen, previous area,
  self-timer, All-In-One (⇧⌘5), scrolling capture, freeze screen and crosshair with magnifier.
- **Capture Text (OCR):** copy the text in any part of the screen; also reads QR codes and barcodes.
- **Annotate:** arrows, shapes, text styles, counters, pen, highlighter (snaps to text lines), blur, pixelate,
  spotlight and added images.
- **Backgrounds:** gradients, your wallpaper or any image, padding, inset, shadow, rounded corners, alignment,
  aspect ratios and presets.
- **Crop & Resize:** ratios, exact sizes, rotate and flip, output size. Saved edits stay editable.
- **Record:** screen or window as video or GIF, with microphone and system audio, camera overlay, highlighted clicks
  and keystrokes, and Do Not Disturb while recording.
- **Video editor:** trim and cut, zooms, background, padding, corners and shadow, export to video or GIF.
- **Quick Access:** a floating stack of your latest captures to copy, save, annotate, pin or drag anywhere.
- **Pin to the Screen** and **Capture History** to restore earlier captures.
- **URL scheme** (`glint://capture-area`, `glint://open-annotate?filepath=…`, …) for automation.

## Requirements

- macOS 15 Sequoia or later
- Apple silicon or Intel Mac

## Installation

### Download

1. Download the latest `Glint-<version>.zip` from [Releases](../../releases).
2. Unzip it and move **Glint.app** to your **Applications** folder.
3. Open Glint. It lives in the menu bar; there's no Dock icon.

> [!IMPORTANT]
> Beta builds are not notarized by Apple yet. The first time you open Glint, macOS says it can't verify the
> developer. Click **Done**, then go to **System Settings → Privacy & Security**, scroll down and click
> **Open Anyway** next to the Glint message. You only need to do this once.

### Homebrew

A Homebrew cask is planned. Once it's available:

```bash
brew install --cask glint
```

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

To use them, turn off the system shortcuts first in **System Settings → Keyboard → Keyboard Shortcuts →
Screenshots**. Every shortcut can be changed in Glint's **Settings → Shortcuts**.

## Updates

Glint updates itself with [Sparkle](https://sparkle-project.org). It checks once a day; you can also choose
**Check for Updates…** in the menu bar menu or turn automatic checks off in **Settings → General → Updates**.
Updates are signed, and Glint only installs updates signed with the project's key.

Builds you make from source don't check for updates.

## Uninstalling

**From the app:** open **Settings → Advanced → Uninstall Glint…**. Glint deletes its settings, Capture History,
saved edits and logs, turns off Launch at Login, resets its privacy permissions, moves itself to the Trash and quits.

**With Homebrew** (once available): `brew uninstall --zap --cask glint`

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

Glint is free and always will be. If it saves you time and you'd like to say thanks, you can support it on
[Ko-fi](https://ko-fi.com/kuhni). It's completely voluntary and very much appreciated. ☕

[![Support Glint on Ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/kuhni)

## License

Glint is released under the [MIT License](LICENSE).

## Acknowledgements

- [Sparkle](https://sparkle-project.org) for updates (MIT-style license, see
  [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)).
- Icons in the app are Apple's [SF Symbols](https://developer.apple.com/sf-symbols/), loaded from macOS at runtime
  and used under Apple's terms for apps on Apple platforms.
