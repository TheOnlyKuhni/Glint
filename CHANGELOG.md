# Changelog

All notable changes to Glint are listed here. Versions follow [Semantic Versioning](https://semver.org).

## [Unreleased]

### Fixed

- Glint crashed when "Show menu bar icon" was switched in Settings. With the icon hidden, it now still appears during
  a recording, so a recording can always be stopped
- "Convert to sRGB profile" converts the colors instead of only relabeling them
- The recording control bar no longer appears in full-screen recordings
- 30 fps GIFs played about 10% too fast
- Window captures opened in the editor at the wrong size with "Scale Retina screenshots to 1x"
- A capture could be lost when its name contained "/", and an empty or dot-first file name format produced broken or
  hidden files
- With both "Open Annotate tool" and Quick Access on, closing the editor showed the capture twice
- Closing an Annotate window removed the Dock icon while a video editor was still open
- "Keep history" is applied while Glint keeps running, not only at launch
- "Save as…" can't give a file an extension that doesn't match its format

### Changed

- "Always on top" applies to open Annotate windows right away
- Removed the "Show color names" setting, which did nothing: the editor always shows color names
- The log file starts over at 2 MB

## [0.1] – Beta

First beta release.

- Screenshots: area, window, full screen, previous area, self-timer, All-In-One, scrolling capture, Capture Text (OCR)
- Annotate editor with shapes, arrows, text, counters, pen, highlighter, blur and pixelate, spotlight, backgrounds,
  Crop & Resize
- Screen and window recording (video and GIF) with audio, camera, clicks and keystrokes; video editor
- Quick Access overlay, Pin to the Screen, Capture History
- Automatic updates (Sparkle) and a built-in uninstaller
