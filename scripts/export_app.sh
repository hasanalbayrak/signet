#!/usr/bin/env bash
set -euo pipefail

# Script to export Signet as a native macOS application bundle (.app)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_DIR="$PROJECT_ROOT/Signet.app"

echo "==> Building Signet in Release mode..."
cd "$PROJECT_ROOT"
swift build -c release

# Find release executable
RELEASE_BIN="$(find "$PROJECT_ROOT/.build" -path "*/Release/Signet" -type f -perm +111 | head -n 1)"
if [ -z "$RELEASE_BIN" ] || [ ! -f "$RELEASE_BIN" ]; then
    echo "Error: Could not find compiled Signet binary."
    exit 1
fi

echo "==> Packaging Signet.app bundle..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources/bin"

# 1. Copy executable
cp "$RELEASE_BIN" "$APP_DIR/Contents/MacOS/Signet"
chmod +x "$APP_DIR/Contents/MacOS/Signet"

# 2. Copy embedded zsign binary
ZSIGN_SRC="$PROJECT_ROOT/Sources/Signet/Resources/bin/zsign"
if [ -f "$ZSIGN_SRC" ]; then
    cp "$ZSIGN_SRC" "$APP_DIR/Contents/Resources/bin/zsign"
    chmod +x "$APP_DIR/Contents/Resources/bin/zsign"
fi

# 3. Copy AppIcon
ICON_SRC="$PROJECT_ROOT/Sources/Signet/Resources/AppIcon.icns"
if [ -f "$ICON_SRC" ]; then
    cp "$ICON_SRC" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

# 4. Write Info.plist
cat << 'EOF' > "$APP_DIR/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Signet</string>
    <key>CFBundleIdentifier</key>
    <string>com.hasanalbayrak.signet</string>
    <key>CFBundleName</key>
    <string>Signet</string>
    <key>CFBundleDisplayName</key>
    <string>Signet</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

# 4. Ad-hoc codesign
echo "==> Signing application bundle with ad-hoc signature..."
codesign --force --deep --sign - "$APP_DIR"
xattr -cr "$APP_DIR" 2>/dev/null || true

echo "==> Successfully exported Signet to:"
echo "    $APP_DIR"
echo ""
echo "To run Signet now:"
echo "    open Signet.app"
