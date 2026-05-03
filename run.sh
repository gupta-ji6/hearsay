#!/bin/bash
set -e

cd "$(dirname "$0")"

APP_NAME="Hearsay"
BUNDLE_ID="com.swair.hearsay"
APP_PATH="build/Build/Products/Debug/Hearsay.app"
BINARY_SRC="$HOME/work/misc/qwen-asr/qwen_asr"
PARAKEET_HELPER_PATH="build/Build/Products/Debug/HearsayParakeetHelper"
RESET_PERMISSIONS=true

for arg in "$@"; do
    case "$arg" in
        --no-reset)
            RESET_PERMISSIONS=false
            ;;
        --reset)
            RESET_PERMISSIONS=true
            ;;
        *)
            echo "Unknown flag: $arg"
            echo "Usage: ./run.sh [--no-reset|--reset]"
            exit 1
            ;;
    esac
done

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Hearsay Build & Run ===${NC}"

# Kill existing instance
pkill -f "Hearsay.app" 2>/dev/null || true

# Generate Xcode project if needed
if [ ! -d "Hearsay.xcodeproj" ] || [ "project.yml" -nt "Hearsay.xcodeproj" ]; then
    echo -e "${YELLOW}Generating Xcode project...${NC}"
    xcodegen generate
fi

# Remove old qwen_asr from bundle (prevents codesign failure)
rm -f "$APP_PATH/Contents/MacOS/qwen_asr" 2>/dev/null || true
rm -f "$APP_PATH/Contents/MacOS/HearsayParakeetHelper" 2>/dev/null || true

# Build the Apple Silicon-only Parakeet helper separately so the app can stay universal.
echo -e "${YELLOW}Building Parakeet helper...${NC}"
xcodebuild -project Hearsay.xcodeproj \
    -scheme HearsayParakeetHelper \
    -configuration Debug \
    -derivedDataPath build \
    -destination 'platform=macOS,arch=arm64' \
    -skipMacroValidation \
    build \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=NO \
    2>&1 | tee /tmp/hearsay-parakeet-helper-build.log | grep -E "^(Build|error:|warning:|\*\*)" || true
HELPER_BUILD_STATUS=${PIPESTATUS[0]}
if [ "$HELPER_BUILD_STATUS" -ne 0 ]; then
    echo -e "${RED}Parakeet helper build failed! Full log: /tmp/hearsay-parakeet-helper-build.log${NC}"
    exit "$HELPER_BUILD_STATUS"
fi

# Build the main app as a universal binary.
echo -e "${YELLOW}Building Hearsay...${NC}"
xcodebuild -project Hearsay.xcodeproj \
    -scheme Hearsay \
    -configuration Debug \
    -derivedDataPath build \
    -skipMacroValidation \
    ONLY_ACTIVE_ARCH=NO \
    build 2>&1 | tee /tmp/hearsay-build.log | grep -E "^(Build|error:|warning:|\*\*)" || true
BUILD_STATUS=${PIPESTATUS[0]}
if [ "$BUILD_STATUS" -ne 0 ]; then
    echo -e "${RED}Build failed! Full log: /tmp/hearsay-build.log${NC}"
    exit "$BUILD_STATUS"
fi

# Check build succeeded
if [ ! -d "$APP_PATH" ]; then
    echo -e "${RED}Build failed!${NC}"
    exit 1
fi

# Copy helper binaries into app bundle and re-sign.
if [ -f "$PARAKEET_HELPER_PATH" ]; then
    echo -e "${YELLOW}Bundling Parakeet helper...${NC}"
    cp "$PARAKEET_HELPER_PATH" "$APP_PATH/Contents/MacOS/"
    chmod 755 "$APP_PATH/Contents/MacOS/HearsayParakeetHelper"
    codesign --force --sign - "$APP_PATH/Contents/MacOS/HearsayParakeetHelper"
else
    echo -e "${RED}Warning: Parakeet helper not found at $PARAKEET_HELPER_PATH${NC}"
fi

if [ -f "$BINARY_SRC" ]; then
    echo -e "${YELLOW}Bundling qwen_asr binary...${NC}"
    cp "$BINARY_SRC" "$APP_PATH/Contents/MacOS/"
    codesign --force --sign - "$APP_PATH/Contents/MacOS/qwen_asr"
else
    echo -e "${RED}Warning: qwen_asr binary not found at $BINARY_SRC${NC}"
    echo "Build it first: cd ~/work/misc/qwen-asr && make blas"
fi

codesign --force --sign - "$APP_PATH"

if [ "$RESET_PERMISSIONS" = true ]; then
    # Reset permissions (clears stale entries from previous builds)
    echo -e "${YELLOW}Resetting permissions...${NC}"
    tccutil reset Accessibility "$BUNDLE_ID" 2>/dev/null || true
    tccutil reset ScreenCapture "$BUNDLE_ID" 2>/dev/null || true

    # Check if we need to prompt for accessibility
    echo ""
    echo -e "${YELLOW}NOTE: After rebuild, you may need to re-grant Accessibility permission.${NC}"
    echo -e "If hotkey doesn't work:"
    echo -e "  1. Open System Settings → Privacy & Security → Accessibility"
    echo -e "  2. Click + and add: ${GREEN}$(pwd)/$APP_PATH${NC}"
    echo ""

    # Ask user if they want to open settings
    read -p "Open Accessibility Settings now? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        echo -e "${YELLOW}Add Hearsay.app, then press Enter to launch...${NC}"
        read
    fi
else
    echo -e "${GREEN}Skipping permission reset (--no-reset).${NC}"
fi

# Launch
echo -e "${GREEN}Launching Hearsay...${NC}"
open "$APP_PATH"

echo -e "${GREEN}Done! Hold RIGHT OPTION (⌥) to record.${NC}"
