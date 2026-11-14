# Homebrew cask for Glint. Copy into a tap repository (github.com/TheOnlyKuhni/homebrew-glint, file Casks/glint.rb)
# and update version + sha256 for each release (Tools/release.sh prints both). See docs/RELEASING.md.
cask "glint" do
  version "1.0"
  sha256 "b7005a3e13779a16228ef18311648e90b5ab3c7ee687dbe850de35bd38ece8f0"

  url "https://github.com/TheOnlyKuhni/Glint/releases/download/v#{version}/Glint-#{version}.zip"
  name "Glint"
  desc "Screenshots, screen recordings and annotations from the menu bar"
  homepage "https://github.com/TheOnlyKuhni/Glint"

  livecheck do
    url "https://raw.githubusercontent.com/TheOnlyKuhni/Glint/main/appcast.xml"
    strategy :sparkle
  end

  auto_updates true
  depends_on macos: ">= :sequoia"

  app "Glint.app"
  binary "#{appdir}/Glint.app/Contents/Resources/glint"

  uninstall quit: "com.philippk.glint"

  zap trash: [
    "~/Library/Application Support/Glint",
    "~/Library/Caches/com.philippk.glint",
    "~/Library/HTTPStorages/com.philippk.glint",
    "~/Library/HTTPStorages/com.philippk.glint.binarycookies",
    "~/Library/Logs/Glint",
    "~/Library/Preferences/com.philippk.glint.plist",
    "~/Library/Saved Application State/com.philippk.glint.savedState",
    "~/Library/WebKit/com.philippk.glint",
  ]
end
