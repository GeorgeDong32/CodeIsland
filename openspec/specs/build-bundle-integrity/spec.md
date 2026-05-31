## ADDED Requirements

### Requirement: App bundle contains Info.plist
The build script MUST copy Info.plist to `Contents/Info.plist` in the app bundle.

#### Scenario: Info.plist present after build
- **WHEN** `./build.sh` completes successfully
- **THEN** `$APP_BUNDLE/Contents/Info.plist` exists and contains valid plist XML

### Requirement: App bundle embeds Sparkle.framework
The build script MUST copy Sparkle.framework to `Contents/Frameworks/` for auto-update support.

#### Scenario: Sparkle.framework embedded after build
- **WHEN** `./build.sh` completes successfully
- **THEN** `$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/` directory exists

#### Scenario: Sparkle framework is universal binary
- **WHEN** Sparkle.framework is embedded
- **THEN** `Versions/B/Sparkle` binary contains both arm64 and x86_64 architectures

### Requirement: Main binary has correct rpath
The build script MUST add `@executable_path/../Frameworks` rpath to the main binary for framework loading.

#### Scenario: rpath configured after build
- **WHEN** `./build.sh` completes successfully
- **THEN** `otool -l $APP_BUNDLE/Contents/MacOS/CodeIsland` shows `LC_RPATH` with path `@executable_path/../Frameworks`

### Requirement: Code signing order respects nested components
The build script MUST remove existing signatures from Sparkle nested code before resigning. The signing strategy depends on the identity type:
- **Ad-hoc signing** (`SIGN_ID="-"`): Use `codesign --force --deep` to sign all nested code in one pass, ensuring a unified Team ID across the app bundle. Ad-hoc signing each nested code independently produces different implicit Team IDs, causing dyld to reject framework loading.
- **Developer ID signing**: Sign explicitly from the innermost executable to the outermost bundle (bridge → Sparkle Mach-O executables → Sparkle nested bundles → Sparkle.framework → app bundle) for notarization compatibility.

All Sparkle components — `Versions/B/Sparkle`, `Autoupdate`, `Installer.xpc`, `Downloader.xpc`, `Updater.app`, and their contained Mach-O executables — MUST be signed with the same identity as the app to avoid Team ID mismatch.

#### Scenario: All components signed after build
- **WHEN** `./build.sh` completes successfully
- **THEN** `codesign -dv $APP_BUNDLE/Contents/Helpers/codeisland-bridge` shows valid signature
- **AND** `codesign -dv $APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle` shows valid signature
- **AND** `codesign -dv $APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate` shows valid signature
- **AND** `codesign -dv $APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer` shows valid signature
- **AND** `codesign -dv $APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc` shows valid signature
- **AND** `codesign -dv $APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader` shows valid signature
- **AND** `codesign -dv $APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc` shows valid signature
- **AND** `codesign -dv $APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater` shows valid signature
- **AND** `codesign -dv $APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app` shows valid signature
- **AND** `codesign -dv $APP_BUNDLE/Contents/Frameworks/Sparkle.framework` shows valid signature
- **AND** `codesign -dv $APP_BUNDLE` shows valid signature

#### Scenario: Existing Sparkle signatures are removed before resigning
- **WHEN** `./build.sh` signs the app bundle
- **THEN** existing signatures on Sparkle.framework, `Versions/B/Sparkle`, Autoupdate, Installer.xpc, Downloader.xpc, Updater.app, and their contained executables are removed before resigning
- **AND** every Sparkle signing target is resigned with the selected `SIGN_ID`

#### Scenario: Sparkle TeamIdentifier matches the app
- **WHEN** `./build.sh` completes successfully
- **THEN** `codesign -dv $APP_BUNDLE` and `codesign -dv` for all Sparkle signing targets report the same `TeamIdentifier`
- **AND** ad-hoc signing reports `TeamIdentifier=not set` consistently for the app and Sparkle signing targets

#### Scenario: Ad-hoc signing also signs nested binaries consistently
- **WHEN** `SIGN_ID="-" bash build.sh` is used
- **THEN** Sparkle nested binaries are signed with the same ad-hoc identity
- **AND** no Team ID mismatch occurs at runtime

### Requirement: Bundle verification before exit
The build script MUST verify bundle completeness, rpath configuration, code signature validity, and TeamIdentifier consistency before exiting successfully.

#### Scenario: Verification passes for complete bundle
- **WHEN** all required components are present
- **THEN** script outputs "✓ Bundle verification passed"
- **AND** script exits with code 0

#### Scenario: Verification fails for incomplete bundle
- **WHEN** any required component is missing
- **THEN** script outputs "ERROR: Bundle verification failed" with missing items listed
- **AND** script exits with code 1