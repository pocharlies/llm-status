#!/bin/bash
# Monta "LLM Status.app" a partir de main.swift y (con --install) la instala
# en ~/Applications con su LaunchAgent.
set -euo pipefail
cd "$(dirname "$0")"

APP="$PWD/build/LLM Status.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS"

swiftc -O -o "$APP/Contents/MacOS/LLMStatus" main.swift

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>LLMStatus</string>
  <key>CFBundleIdentifier</key><string>com.e-dani.llm-status</string>
  <key>CFBundleName</key><string>LLM Status</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF

codesign -s - --force "$APP"
echo "OK: $APP"

if [[ "${1:-}" == "--install" ]]; then
  DEST="$HOME/Applications/LLM Status.app"
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"

  LA="$HOME/Library/LaunchAgents/com.e-dani.llm-status.plist"
  mkdir -p "$HOME/Library/LaunchAgents"
  cat > "$LA" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.e-dani.llm-status</string>
  <key>ProgramArguments</key><array>
    <string>$DEST/Contents/MacOS/LLMStatus</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
</dict></plist>
EOF

  launchctl bootout "gui/$(id -u)/com.e-dani.llm-status" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$LA"
  echo "OK: instalada y en marcha"
fi
