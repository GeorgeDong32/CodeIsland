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

# Resolve signing identity: SIGN_ID env → Developer ID → any non-revoked → ad-hoc
find_signing_identity() {
    local identities
    identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"

    local developer_id
    developer_id="$(printf '%s\n' "$identities" | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)".*/\1/' || true)"
    if [ -n "$developer_id" ]; then
        printf '%s\n' "$developer_id"
        return 0
    fi

    local any_identity
    any_identity="$(printf '%s\n' "$identities" | grep -v "REVOKED" | grep '"' | head -1 | sed 's/.*"\(.*\)".*/\1/' || true)"
    if [ -n "$any_identity" ]; then
        printf '%s\n' "$any_identity"
        return 0
    fi

    printf '%s\n' "-"
}

if [ -z "${SIGN_ID:-}" ]; then
    SIGN_ID="$(find_signing_identity)"
fi

if [ "$SIGN_ID" = "-" ]; then
    echo "No developer certificate found, using ad-hoc signing..."
fi

# Signing graph paths
SPARKLE_FRAMEWORK="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
SPARKLE_VERSION_B="$SPARKLE_FRAMEWORK/Versions/B"
SPARKLE_BINARY="$SPARKLE_VERSION_B/Sparkle"
SPARKLE_AUTOUPDATE="$SPARKLE_VERSION_B/Autoupdate"
SPARKLE_INSTALLER_XPC="$SPARKLE_VERSION_B/XPCServices/Installer.xpc"
SPARKLE_INSTALLER_BINARY="$SPARKLE_INSTALLER_XPC/Contents/MacOS/Installer"
SPARKLE_DOWNLOADER_XPC="$SPARKLE_VERSION_B/XPCServices/Downloader.xpc"
SPARKLE_DOWNLOADER_BINARY="$SPARKLE_DOWNLOADER_XPC/Contents/MacOS/Downloader"
SPARKLE_UPDATER_APP="$SPARKLE_VERSION_B/Updater.app"
SPARKLE_UPDATER_BINARY="$SPARKLE_UPDATER_APP/Contents/MacOS/Updater"
BRIDGE_BINARY="$APP_BUNDLE/Contents/Helpers/codeisland-bridge"
MAIN_APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Remove upstream Sparkle signatures to avoid Team ID mismatch
remove_signature_if_present() {
    local target="$1"
    if [ -e "$target" ]; then
        codesign --remove-signature "$target" 2>/dev/null || true
    fi
}

echo "Removing existing Sparkle signatures..."
remove_signature_if_present "$SPARKLE_INSTALLER_BINARY"
remove_signature_if_present "$SPARKLE_INSTALLER_XPC"
remove_signature_if_present "$SPARKLE_DOWNLOADER_BINARY"
remove_signature_if_present "$SPARKLE_DOWNLOADER_XPC"
remove_signature_if_present "$SPARKLE_UPDATER_BINARY"
remove_signature_if_present "$SPARKLE_UPDATER_APP"
remove_signature_if_present "$SPARKLE_AUTOUPDATE"
remove_signature_if_present "$SPARKLE_BINARY"
remove_signature_if_present "$SPARKLE_FRAMEWORK"

echo "Code signing ($SIGN_ID)..."

if [ "$SIGN_ID" = "-" ]; then
    # Ad-hoc: --deep signs all nested code in one pass to ensure consistent Team ID
    codesign --force --deep --sign "$SIGN_ID" "$APP_BUNDLE"
else
    # Developer ID: explicit nested-first graph for notarization compatibility
    codesign --force --options runtime --sign "$SIGN_ID" "$BRIDGE_BINARY"
    codesign --force --sign "$SIGN_ID" "$SPARKLE_INSTALLER_BINARY"
    codesign --force --sign "$SIGN_ID" "$SPARKLE_DOWNLOADER_BINARY"
    codesign --force --sign "$SIGN_ID" "$SPARKLE_UPDATER_BINARY"
    codesign --force --sign "$SIGN_ID" "$SPARKLE_AUTOUPDATE"
    codesign --force --sign "$SIGN_ID" "$SPARKLE_BINARY"
    codesign --force --sign "$SIGN_ID" "$SPARKLE_INSTALLER_XPC"
    codesign --force --sign "$SIGN_ID" "$SPARKLE_DOWNLOADER_XPC"
    codesign --force --sign "$SIGN_ID" "$SPARKLE_UPDATER_APP"
    codesign --force --options runtime --sign "$SIGN_ID" "$SPARKLE_FRAMEWORK"
    codesign --force --options runtime --sign "$SIGN_ID" --entitlements "$ENTITLEMENTS" "$APP_BUNDLE"
fi

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

# Path existence checks
for required_path in \
    "$APP_BUNDLE/Contents/Info.plist" \
    "$MAIN_APP_BINARY" \
    "$BRIDGE_BINARY" \
    "$SPARKLE_FRAMEWORK" \
    "$SPARKLE_BINARY" \
    "$SPARKLE_AUTOUPDATE" \
    "$SPARKLE_INSTALLER_XPC" \
    "$SPARKLE_INSTALLER_BINARY" \
    "$SPARKLE_DOWNLOADER_XPC" \
    "$SPARKLE_DOWNLOADER_BINARY" \
    "$SPARKLE_UPDATER_APP" \
    "$SPARKLE_UPDATER_BINARY"
do
    if [ ! -e "$required_path" ]; then
        echo "MISSING: $required_path"
        verify_fail=1
    fi
done

# rpath check
if ! otool -l "$MAIN_APP_BINARY" | grep -q "@executable_path/../Frameworks"; then
    echo "MISSING: rpath for Frameworks"
    verify_fail=1
fi

# Signature validity checks
verify_signature() {
    local target="$1"
    if ! codesign --verify --verbose=2 "$target" >/dev/null 2>&1; then
        echo "INVALID SIGNATURE: $target"
        verify_fail=1
    fi
}

for signed_target in \
    "$BRIDGE_BINARY" \
    "$SPARKLE_INSTALLER_BINARY" \
    "$SPARKLE_INSTALLER_XPC" \
    "$SPARKLE_DOWNLOADER_BINARY" \
    "$SPARKLE_DOWNLOADER_XPC" \
    "$SPARKLE_UPDATER_BINARY" \
    "$SPARKLE_UPDATER_APP" \
    "$SPARKLE_AUTOUPDATE" \
    "$SPARKLE_BINARY" \
    "$SPARKLE_FRAMEWORK" \
    "$APP_BUNDLE"
do
    verify_signature "$signed_target"
done

# TeamIdentifier consistency check
team_identifier() {
    codesign -dv "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p'
}

APP_TEAM_ID="$(team_identifier "$APP_BUNDLE")"
if [ -z "$APP_TEAM_ID" ]; then
    echo "MISSING TeamIdentifier: $APP_BUNDLE"
    verify_fail=1
fi

for team_target in \
    "$SPARKLE_BINARY" \
    "$SPARKLE_AUTOUPDATE" \
    "$SPARKLE_INSTALLER_BINARY" \
    "$SPARKLE_INSTALLER_XPC" \
    "$SPARKLE_DOWNLOADER_BINARY" \
    "$SPARKLE_DOWNLOADER_XPC" \
    "$SPARKLE_UPDATER_BINARY" \
    "$SPARKLE_UPDATER_APP" \
    "$SPARKLE_FRAMEWORK"
do
    TARGET_TEAM_ID="$(team_identifier "$team_target")"
    if [ "$TARGET_TEAM_ID" != "$APP_TEAM_ID" ]; then
        echo "TEAM ID MISMATCH: $team_target has TeamIdentifier='$TARGET_TEAM_ID', app has TeamIdentifier='$APP_TEAM_ID'"
        verify_fail=1
    fi
done

if [ $verify_fail -eq 1 ]; then
    echo "ERROR: Bundle verification failed"
    exit 1
fi

echo "✓ Bundle verification passed"
echo "Done: $APP_BUNDLE"
echo "Run: open $APP_BUNDLE"