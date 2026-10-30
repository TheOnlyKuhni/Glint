# Contributing to Glint

Thanks for helping! Glint is a small project, so a few simple rules keep it manageable.

## Reporting bugs and ideas

Open an [issue](../../issues/new/choose) and fill in the template. For bugs, the Glint and macOS versions and
steps to reproduce help most.

## Pull requests

1. For anything bigger than a small fix, open an issue first so we can agree on the approach.
2. Fork the repo, create a branch, and keep each pull request focused on one change.
3. Build and try your change (see *Building from source* in the README). Don't commit your own signing team or
   bundle identifier.
4. Describe what you changed and how you tested it.

## Code style

- AppKit for windows, overlays and the canvas; SwiftUI for panels and settings.
- Follow the style of the surrounding code: short doc comments on types and non-obvious functions, no dead code.
- Guard APIs newer than macOS 15 with `#available`.
- Use SF Symbols or your own drawings for icons. Don't add images, icons, sounds or other assets you don't have the
  right to publish under the MIT license.

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
