#!/usr/bin/env bash
#
# Build and install Zuddy for macOS (Release build).
#
# Usage:
#   ./scripts/install.sh             Build Release and install to /Applications
#   ./scripts/install.sh --user      Install to ~/Applications
#   ./scripts/install.sh --no-launch Do not open app after install
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

DEST_DIR="/Applications"
AUTO_LAUNCH=true

for arg in "$@"; do
    case "$arg" in
        --user)
            DEST_DIR="$HOME/Applications"
            mkdir -p "$DEST_DIR"
            ;;
        --no-launch)
            AUTO_LAUNCH=false
            ;;
        --help|-h)
            echo "Usage: $0 [--user] [--no-launch]"
            echo "  --user       Install to ~/Applications instead of /Applications"
            echo "  --no-launch  Do not open Zuddy after installing"
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg"
            exit 1
            ;;
    esac
done

echo "==> 1. Checking prerequisites..."
command -v xcodegen >/dev/null 2>&1 || { echo "error: xcodegen not found. Install via: brew install xcodegen" >&2; exit 1; }
command -v xcodebuild >/dev/null 2>&1 || { echo "error: xcodebuild not found. Install Xcode command line tools." >&2; exit 1; }

echo "==> 2. Regenerating Xcode project with xcodegen..."
cd "$REPO_ROOT/Zuddy"
xcodegen >/dev/null
cd "$REPO_ROOT"

BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/zuddy-install-build.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT

echo "==> 3. Building Zuddy (Debug configuration)..."
xcodebuild -destination "platform=macOS" \
    -project "$REPO_ROOT/Zuddy/Zuddy.xcodeproj" \
    -scheme Zuddy \
    -configuration Debug \
    -derivedDataPath "$BUILD_DIR" \
    build 

BUILT_APP="$BUILD_DIR/Build/Products/Debug/Zuddy.app"
if [ ! -d "$BUILT_APP" ]; then
    echo "error: Build output not found at $BUILT_APP" >&2
    exit 1
fi

TARGET_APP="$DEST_DIR/Zuddy.app"

# Quit running Zuddy if active
if pgrep -x "Zuddy" >/dev/null 2>&1; then
    echo "==> 4. Closing running instance of Zuddy..."
    pkill -x "Zuddy" || true
    sleep 0.5
fi

echo "==> 5. Installing to $TARGET_APP..."
rm -rf "$TARGET_APP"
cp -R "$BUILT_APP" "$TARGET_APP"

echo "==> 6. Signing ad-hoc and resetting quarantine..."
codesign --force --deep --sign - "$TARGET_APP" 2>/dev/null || true
xattr -cr "$TARGET_APP" 2>/dev/null || true

echo "✅ Zuddy successfully installed to $TARGET_APP"
echo "ℹ️  Zuddy runs in your MacBook notch / top bar (no Dock icon)."

if [ "$AUTO_LAUNCH" = true ]; then
    echo "==> 7. Launching Zuddy..."
    open "$TARGET_APP"
fi
