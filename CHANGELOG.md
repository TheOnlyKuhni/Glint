# Changelog

All notable changes to Glint are listed here. Versions follow [Semantic Versioning](https://semver.org).

## [Unreleased]

### Added

- Trash: captures removed from the Capture History can be put back. Open it from the history's "…" menu or Settings →
  Advanced, and empty it by hand or automatically after 1 to 90 days
- Open images in Annotate from Finder: Open With, the "Open in Glint Annotate" service, or by dropping them on the Dock
  icon, including images not made with Glint
- Video editor: ←/→ and the ‹ › buttons move through the video: a tap nudges, holding speeds up. ⌥←/→ step one frame,
  ⌘←/→ go to the start or end, K pauses
- Video editor: background presets, shared with the screenshot editor
- Video editor: export as MP4, MOV or GIF
- Crop & Resize: a zoom lens shows the exact pixels while a handle is dragged
- TIFF as a screenshot format, and a Format choice in the Save panels for screenshots
- Hover animations on the video editor's buttons and on the timeline's zooms, camera actions, clips and events

### Changed

- Screenshot editor: a new toolbar (a dark dock with the tools in groups and a sliding selection); the head bars'
  buttons and Drag Me now match the bottom bar's buttons
- Stepping one frame in the video editor is now ⌥←/→

### Fixed

- Recordings ending on a still screen had a video track shorter than their sound, and such recordings couldn't be
  exported from the video editor
- Alerts opened from the Capture History sat below it and couldn't be clicked
- Rotated photos (EXIF orientation) opened sideways in Annotate; grayscale, indexed and 16-bit images are converted on
  opening, and a file's DPI only counts as a screen scale at 144 or 216

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
