# Setting up Glint with an AI agent

This page is written for an AI agent (Claude Code, Codex, Cursor or similar) that helps someone install Glint. As a
user, you can point your agent here:

> Help me set up Glint: https://github.com/TheOnlyKuhni/Glint/blob/main/docs/agent-setup.md

---

## Instructions for the agent

You're helping the user install **Glint**, a free, open-source screenshot and screen recording app for macOS that
lives in the menu bar. Follow these steps in order. Explain briefly what you're doing. Ask before anything that
changes the system, and let the user do the steps that need them (permissions, System Settings).

### 1. Check the Mac

```bash
sw_vers -productVersion   # needs 15.0 or later
pgrep -x Glint && echo "Glint is running"
ls -d /Applications/Glint.app 2>/dev/null
```

- On macOS older than 15, stop and tell the user Glint needs macOS 15 Sequoia or later.
- If Glint is already installed, ask whether to replace it. Glint also updates itself (menu bar menu → **Check for
  Updates…**), so a reinstall is rarely needed.

### 2. Download the latest release

Get it only from this repository's Releases page. Glint is in beta, so the newest release is marked as a
pre-release and GitHub's "latest" endpoint skips it. List all releases (newest first) and take the first zip:

```bash
mkdir -p "$TMPDIR/glint-install" && cd "$TMPDIR/glint-install"
url=$(curl -fsSL https://api.github.com/repos/TheOnlyKuhni/Glint/releases \
  | grep -o '"browser_download_url": *"[^"]*\.zip"' | head -1 | cut -d'"' -f4)
echo "$url"
curl -fL -o Glint.zip "$url"
ditto -x -k Glint.zip .
```

The file is called `Glint-<version>.zip` and contains `Glint.app`.

### 3. Move it to Applications

Quit a running Glint first, then move the app:

```bash
osascript -e 'quit app "Glint"' 2>/dev/null
rm -rf /Applications/Glint.app     # only if the user agreed to replace it
mv Glint.app /Applications/
```

### 4. Get past Gatekeeper

Glint isn't notarized by Apple yet. The first time it opens, macOS says "Apple could not verify 'Glint' is free of
malware" and won't open it. This is expected for a free app without a paid Apple Developer ID; it doesn't mean
anything harmful was found.

Explain this to the user and let them choose:

- **In Terminal (you can run it, after the user agrees):**

  ```bash
  xattr -dr com.apple.quarantine /Applications/Glint.app
  ```

- **By hand:** open Glint, click **Done** on the message, then go to **System Settings → Privacy & Security**, scroll
  to **Security** and click **Open Anyway** next to Glint, and confirm with the password or Touch ID.

Then open it:

```bash
open -a /Applications/Glint.app
```

Glint shows an icon in the menu bar and opens its menu once. It has no Dock icon and no window.

### 5. Screen Recording permission

Glint needs **Screen Recording** for every screenshot and recording. Only the user can grant it. Open the pane for
them:

```bash
open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
```

The pane is called **Screen & System Audio Recording** on recent macOS versions. Ask them to switch on
**Glint** (or add it with **+**). macOS may ask to quit and reopen Glint; let it, or run
`open -g -a Glint --args --background` afterwards (it starts without opening its menu).

Glint asks for the other permissions only when a feature needs them, so there's nothing to do for them now:

| Permission | Used for |
|---|---|
| Microphone / Camera | Only if the user turns them on for a recording |
| Accessibility / Input Monitoring | Only for showing keystrokes in recordings and for auto-scrolling |

### 6. Turn off Apple's screenshot shortcuts

Glint uses the same shortcuts as macOS: ⇧⌘3 (full screen), ⇧⌘4 (area), ⇧⌘5 (All-In-One) and ⌃⇧⌘4 (area to the
clipboard). While Apple's are on, macOS takes these keys and Glint's don't work.

Check which ones are on (no entry or `enabled = 1` means on):

```bash
defaults read com.apple.symbolichotkeys AppleSymbolicHotKeys | grep -A1 -E '^ +(28|29|30|31|184) = '
```

| Id | Shortcut | Name in System Settings |
|---|---|---|
| 28 | ⇧⌘3 | Save picture of screen as a file |
| 29 | ⌃⇧⌘3 | Copy picture of screen to the clipboard |
| 30 | ⇧⌘4 | Save picture of selected area as a file |
| 31 | ⌃⇧⌘4 | Copy picture of selected area to the clipboard |
| 184 | ⇧⌘5 | Screenshot and recording options |

Ask the user to turn them off. Don't edit `com.apple.symbolichotkeys` yourself: macOS only picks up a change there
after logging out, and a mistake can break other shortcuts.

1. Open **System Settings → Keyboard**:
   `open "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"`
2. Click **Keyboard Shortcuts…**.
3. Choose **Screenshots** on the left.
4. Uncheck the shortcuts above. ⌃⇧⌘3 has no Glint default, so it can stay on.
5. Click **Done**.

Glint's **Settings → Shortcuts** shows a warning while any of them is still on. If the user would rather keep
Apple's, they can give Glint other shortcuts there instead.

### 7. Basic setup

Ask the user what they'd like. The defaults work well:

- After a screenshot: Quick Access shows it in the corner, and it's copied to the clipboard.
- Captures are kept in the Capture History for a week. They're only saved to a folder (the Desktop by default) when
  the user clicks Save, or if they turn on Save after capture.

Common changes, with the setting to point them to:

| Wish | Where |
|---|---|
| Start Glint at login | Settings → General → Launch at login |
| Always save captures to a folder | Settings → General → After Capture: Save, and the export location above it |
| Open the editor after every screenshot | Settings → General → After Capture: Open Annotate tool |
| JPEG or HEIC instead of PNG | Settings → Screenshots → File format |
| Quick Access on the right | Settings → Quick Access → Position on screen |

Open Settings for them with `/Applications/Glint.app/Contents/Resources/glint settings`. Settings can also be written with `defaults`; see
[Settings with `defaults`](command-line.md#settings-with-defaults).

### 8. The `glint` command and a test capture

Glint includes a command line tool that takes captures and prints the file's path. Offer to install it. It links
`/usr/local/bin/glint` and needs the user's password, so ask them to run this in their own Terminal, or to click
**Install…** in Settings → Advanced → API → Command line tool:

```bash
/Applications/Glint.app/Contents/Resources/glint install
```

Then take a test screenshot (the full path works without installing):

```bash
/Applications/Glint.app/Contents/Resources/glint fullscreen
```

It prints the new file's path, and a Quick Access card appears in the bottom-left corner. If it fails, the message
says why; `tail ~/Library/Logs/Glint/glint.log` shows what Glint received.

Then ask the user to press ⇧⌘4 and drag over an area, to check the shortcut.

### 9. Wrap up

Tell the user briefly:

- Glint is in the menu bar; its menu has every capture type, the Capture History and Settings.
- ⇧⌘4 captures an area (Space switches to a window), ⇧⌘3 the full screen, ⇧⌘5 opens All-In-One.
- Quick Access cards can be dragged into any app. Pull a card down, swipe down with two fingers, or click the bar
  above them to tuck them away; pull a card toward the screen edge to close it.
- Questions and ideas go to [Discussions](https://github.com/TheOnlyKuhni/Glint/discussions), bugs to
  [Issues](https://github.com/TheOnlyKuhni/Glint/issues).

Remove the download folder when you're done: `rm -rf "$TMPDIR/glint-install"`.

## Using Glint from an agent later

Use the `glint` command, for example `glint fullscreen` to take a screenshot and get its path. Every command is in
[command-line.md](command-line.md).
