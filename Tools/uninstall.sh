#!/bin/zsh
# Removes Glint and everything it stores. Saved screenshots and recordings are kept.
# Usage: zsh Tools/uninstall.sh [bundle-id]   (default com.philippk.glint; pass yours for builds from source)
# Keep in sync with Glint/Support/Uninstaller.swift and the Homebrew cask's zap stanza.
set -u
ID=${1:-com.philippk.glint}

echo "Quitting Glint…"
osascript -e "tell application id \"$ID\" to quit" 2>/dev/null
sleep 1
pkill -x Glint 2>/dev/null

echo "Removing the app…"
for app in /Applications/Glint.app ~/Applications/Glint.app; do
  [[ -d $app ]] && rm -rf "$app" && echo "  $app"
done

echo "Removing data and settings…"
for item in \
  ~/Library/Application\ Support/Glint \
  ~/Library/Logs/Glint \
  ~/Library/Caches/$ID \
  ~/Library/HTTPStorages/$ID \
  ~/Library/HTTPStorages/$ID.binarycookies \
  ~/Library/WebKit/$ID \
  ~/Library/Saved\ Application\ State/$ID.savedState \
  ~/Library/Preferences/$ID.plist; do
  [[ -e $item ]] && rm -rf "$item" && echo "  $item"
done
defaults delete "$ID" 2>/dev/null

echo "Resetting privacy permissions…"
for service in ScreenCapture Microphone Camera Accessibility ListenEvent; do
  tccutil reset $service "$ID" >/dev/null 2>&1
done

echo
echo "Glint is uninstalled."
echo "If you added the \"Glint Focus On/Off\" shortcuts, delete them in the Shortcuts app."
