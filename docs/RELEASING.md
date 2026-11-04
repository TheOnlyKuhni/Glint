# Releasing Glint

How updates work, the one-time setup, and the steps for each release.

## Going public

### Publish without notarization (free)

Everyone can see and download Glint; macOS blocks it on first open, and the README explains how to get past that.

1. Raise the version and build, and move the `[Unreleased]` notes in `CHANGELOG.md` under the new version.
2. Update the version badge and the beta note in `README.md`. Add a screenshot or GIF near the top.
3. Run `Tools/release.sh`, try the resulting zip, then attach it to a GitHub Release.
4. Commit and push `appcast.xml` and the version bump.
5. Make the repo public: `gh repo edit TheOnlyKuhni/Glint --visibility public --accept-visibility-change-consequences`.
   Every commit becomes visible, including the email address on them.
6. Check while signed out of GitHub: the README and its links, the zip's download, and the feed
   (`https://raw.githubusercontent.com/TheOnlyKuhni/Glint/main/appcast.xml`).

### Remove the macOS warning (paid)

Needs the Apple Developer Program. See *Developer ID and notarization* below, then remove the "Opening Glint for the
first time" section from the README.

## How updates work

- Glint uses [Sparkle 2](https://sparkle-project.org) (Swift package, added to the Xcode project).
- Each installed copy reads the feed in `Config/Info.plist` → `SUFeedURL`:
  `https://raw.githubusercontent.com/TheOnlyKuhni/Glint/main/appcast.xml`
- `appcast.xml` lists releases. Each entry points to a zip attached to a GitHub Release and carries an EdDSA
  signature. Glint only installs a zip whose signature matches the public key in `SUPublicEDKey`.
- Without a key in `SUPublicEDKey`, the updater stays off. The key is in the repo, so builds from source do check for
  updates unless the builder removes it.

> [!WARNING]
> **Private repository:** GitHub serves `raw.githubusercontent.com` files and release downloads of a private repo
> only to signed-in users, so Sparkle can't reach them. While the repo is private, testers update by downloading the
> new zip from the Releases page (or by pulling and building). Updates start working as soon as the repo is public.
> If you want automatic updates during the private beta, host `appcast.xml` and the zips somewhere public (for
> example a separate public repo with only releases) and point `SUFeedURL` and the `REPO` in `Tools/release.sh` there.

## One-time setup

### 1. Create the update signing key

Build the project once (so Xcode downloads Sparkle), then:

```bash
"$(find build/DerivedData/SourcePackages/artifacts -type d -path '*Sparkle/bin' | head -1)/generate_keys"
```

- The **private key** is saved in your login Keychain ("Private key for signing Sparkle updates"). Never commit it.
  Back it up: `generate_keys -x sparkle-private-key.txt` exports it; store that file in your password manager and
  delete it. **If you lose it, existing installs can no longer be updated.**
- The command prints the **public key**. Put it in `Config/Info.plist`:

```xml
<key>SUPublicEDKey</key>
<string>PASTE_THE_PUBLIC_KEY_HERE</string>
```

Commit that change. The public key is meant to be public.

(If you build with Xcode's default DerivedData instead of `build/DerivedData`, the tools are in
`~/Library/Developer/Xcode/DerivedData/Glint-*/SourcePackages/artifacts/sparkle/Sparkle/bin/`.)

### 2. Developer ID and notarization (recommended before going public)

Right now Glint is signed with an *Apple Development* certificate, so macOS warns testers on first launch and they
have to click *Open Anyway* in Privacy & Security. To ship without that warning, and for the official Homebrew cask:

1. Join the [Apple Developer Program](https://developer.apple.com/programs/) (99 USD/year).
2. In Xcode → Settings → Accounts → Manage Certificates, add a **Developer ID Application** certificate.
3. In the Glint target's Release configuration, set *Code Signing Identity* to **Developer ID Application**
   (hardened runtime and entitlements are already set up).
4. Store notarization credentials once:
   `xcrun notarytool store-credentials glint-notary --apple-id <you@example.com> --team-id <TEAM_ID>`
5. `Tools/release.sh` still needs three changes, which can only be tested with the certificate. Apple rejects a build
   that has any of what today's Release build has:
   - the `get-task-allow` entitlement: set `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO` for Release;
   - signatures without a secure timestamp: add `OTHER_CODE_SIGN_FLAGS = --timestamp`;
   - Sparkle's helpers (`Autoupdate`, `Updater.app`, `Downloader.xpc`, `Installer.xpc`) signed ad hoc: re-sign them with
     the Developer ID from the inside out, then Sparkle.framework, then Glint.app.
6. Release with `NOTARY_PROFILE=glint-notary Tools/release.sh`. Before publishing, check the zip's app with
   `spctl -a -vv -t exec Glint.app`: it should say "accepted" and "Notarized Developer ID".

## Each release

1. In Xcode (Glint target → General), raise **Version** (`MARKETING_VERSION`, e.g. `0.2`) and **Build**
   (`CURRENT_PROJECT_VERSION`, always +1; Sparkle compares the build number).
2. Add the changes to `CHANGELOG.md`.
3. Run `Tools/release.sh`. It builds Release, zips `Glint.app` into `releases/Glint-<version>.zip`, signs it with your
   key (macOS may ask to allow Keychain access) and adds an entry to `appcast.xml`.
4. Create the GitHub Release with the zip (the script prints the exact command):
   `gh release create v0.2 releases/Glint-0.2.zip --title "Glint 0.2" --notes "…"`
5. Commit and push `appcast.xml` (and the version bump). Installed copies see the update within a day, or right
   away with *Check for Updates…*.

## Homebrew

`Distribution/Homebrew/glint.rb` is a ready cask. Two ways to offer it:

- **Own tap (works now, once the repo is public):** create a public repo `TheOnlyKuhni/homebrew-glint`, copy the
  file to `Casks/glint.rb`, and set `version` and `sha256` (printed by `Tools/release.sh`). Users install with
  `brew install --cask theonlykuhni/glint/glint`. Update the two lines for each release.
- **Official homebrew/cask:** needs a notarized app, a public repo with some popularity, and a pull request to
  [Homebrew/homebrew-cask](https://github.com/Homebrew/homebrew-cask). Then `brew install --cask glint` works.

`brew uninstall --zap --cask glint` removes the app and every file in the `zap` list. Keep that list in sync with
`Glint/Support/Uninstaller.swift` and `Tools/uninstall.sh` whenever Glint starts storing something new.
