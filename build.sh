#!/bin/bash
set -e

APP_NAME="CodeIsland"
BUILD_DIR=".build/release"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
ICON_CATALOG="Assets.xcassets"
ICON_SOURCE="AppIcon.icon"
ICON_INFO_PLIST=".build/AppIcon.partial.plist"
ENTITLEMENTS="CodeIsland.entitlements"

# ============== Phase 1: Build ==============

echo "Building $APP_NAME (universal)..."
swift build -c release --arch arm64
swift build -c release --arch x86_64

echo "Creating universal binaries..."
ARM_DIR=".build/arm64-apple-macosx/release"
X86_DIR=".build/x86_64-apple-macosx/release"

# ============== Phase 2: Bundle Assembly ==============

echo "Creating app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Helpers"
mkdir -p "$APP_BUNDLE/Contents/Resources"
mkdir -p "$APP_BUNDLE/Contents/Frameworks"

# Copy Info.plist early (before binaries)
cp Info.plist "$APP_BUNDLE/Contents/Info.plist"

# Merge binaries with lipo
lipo -create "$ARM_DIR/$APP_NAME" "$X86_DIR/$APP_NAME" \
     -output "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
lipo -create "$ARM_DIR/codeisland-bridge" "$X86_DIR/codeisland-bridge" \
     -output "$APP_BUNDLE/Contents/Helpers/codeisland-bridge"

echo "Compiling app icon assets..."
xcrun actool \
    --output-format human-readable-text \
    --warnings \
    --errors \
    --notices \
    --platform macosx \
    --target-device mac \
    --minimum-deployment-target 14.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "$ICON_INFO_PLIST" \
    --compile "$APP_BUNDLE/Contents/Resources" \
    "$ICON_CATALOG" \
    "$ICON_SOURCE"

# Copy SPM resource bundles into Contents/Resources/ (required for code signing)
for bundle in .build/*/release/*.bundle; do
    if [ -e "$bundle" ]; then
        cp -R "$bundle" "$APP_BUNDLE/Contents/Resources/"
        break
    fi
done

# ============== Phase 3: Framework Embedding ==============

echo "Embedding Sparkle.framework..."
SPARKLE_SRC="$ARM_DIR/Sparkle.framework"
if [ ! -d "$SPARKLE_SRC" ]; then
    echo "ERROR: Sparkle.framework not found at $SPARKLE_SRC"
    exit 1
fi
cp -R "$SPARKLE_SRC" "$APP_BUNDLE/Contents/Frameworks/"

echo "Configuring rpath for framework loading..."
install_name_tool -add_rpath "@executable_path/../Frameworks" \
    "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# ============== Phase 4: Code Signing ==============

# Use SIGN_ID env var, or auto-detect: prefer "Developer ID Application" for distribution,
# fall back to any valid identity, then ad-hoc
if [ -z "$SIGN_ID" ]; then
    SIGN_ID=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)".*/\1/' 2>/dev/null || true)
fi
if [ -z "$SIGN_ID" ]; then
    SIGN_ID=$(security find-identity -v -p codesigning | grep -v "REVOKED" | head -1 | sed 's/.*"\(.*\)".*/\1/' 2>/dev/null || true)
fi
if [ -z "$SIGN_ID" ]; then
    echo "No developer certificate found, using ad-hoc signing..."
    SIGN_ID="-"
fi

echo "Code signing ($SIGN_ID)..."
# Sign in order: nested components first, then parent
codesign --force --options runtime --sign "$SIGN_ID" "$APP_BUNDLE/Contents/Helpers/codeisland-bridge"
# Sparkle nested binaries (must match app signature to avoid Team ID mismatch)
codesign --force --sign "$SIGN_ID" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
codesign --force --sign "$SIGN_ID" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc"
codesign --force --sign "$SIGN_ID" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc"
codesign --force --sign "$SIGN_ID" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app"
codesign --force --options runtime --sign "$SIGN_ID" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
codesign --force --options runtime --sign "$SIGN_ID" --entitlements "$ENTITLEMENTS" "$APP_BUNDLE"

# ============== Phase 5: Optional Notarization + DMG ==============

if [[ "$*" == *"--notarize"* ]] && [[ "$SIGN_ID" == *"Developer ID"* ]]; then
    echo "Creating ZIP for notarization..."
    ZIP_PATH="$BUILD_DIR/$APP_NAME.zip"
    ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"

    echo "Submitting for notarization..."
    if xcrun notarytool submit "$ZIP_PATH" --keychain-profile "CodeIsland" --wait 2>&1 | tee /dev/stderr | grep -q "status: Accepted"; then
        echo "Stapling notarization ticket..."
        xcrun stapler staple "$APP_BUNDLE"
    else
        echo "ERROR: Notarization failed. Run 'xcrun notarytool log <submission-id> --keychain-profile CodeIsland' for details."
        rm -f "$ZIP_PATH"
        exit 1
    fi
    rm -f "$ZIP_PATH"

    echo "Creating DMG..."
    DMG_PATH="$BUILD_DIR/$APP_NAME.dmg"
    rm -f "$DMG_PATH"
    create-dmg \
        --volname "$APP_NAME" \
        --window-pos 200 120 \
        --window-size 600 400 \
        --icon-size 100 \
        --icon "$APP_NAME.app" 150 185 \
        --app-drop-link 450 185 \
        --no-internet-enable \
        "$DMG_PATH" "$APP_BUNDLE"

    # Sign and notarize the DMG too
    codesign --force --sign "$SIGN_ID" "$DMG_PATH"
    echo "Notarizing DMG..."
    if xcrun notarytool submit "$DMG_PATH" --keychain-profile "CodeIsland" --wait 2>&1 | tee /dev/stderr | grep -q "status: Accepted"; then
        xcrun stapler staple "$DMG_PATH"
        echo "DMG ready: $DMG_PATH"
    else
        echo "WARNING: DMG notarization failed, but app is notarized."
    fi
fi

# ============== Bundle Verification ==============

echo "Verifying bundle completeness..."
verify_fail=0

if [ ! -f "$APP_BUNDLE/Contents/Info.plist" ]; then
    echo "MISSING: Info.plist"
    verify_fail=1
fi

if [ ! -f "$APP_BUNDLE/Contents/MacOS/$APP_NAME" ]; then
    echo "MISSING: Main binary"
    verify_fail=1
fi

if [ ! -d "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework" ]; then
    echo "MISSING: Sparkle.framework"
    verify_fail=1
fi

if ! otool -l "$APP_BUNDLE/Contents/MacOS/$APP_NAME" | grep -q "@executable_path/../Frameworks"; then
    echo "MISSING: rpath for Frameworks"
    verify_fail=1
fi

if [ $verify_fail -eq 1 ]; then
    echo "ERROR: Bundle verification failed"
    exit 1
fi

echo "✓ Bundle verification passed"
echo "Done: $APP_BUNDLE"
echo "Run: open $APP_BUNDLE"