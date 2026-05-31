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
The build script MUST sign components in order: bridge → framework → app bundle.

#### Scenario: All components signed after build
- **WHEN** `./build.sh` completes successfully
- **THEN** `codesign -dv $APP_BUNDLE/Contents/Helpers/codeisland-bridge` shows valid signature
- **AND** `codesign -dv $APP_BUNDLE/Contents/Frameworks/Sparkle.framework` shows valid signature
- **AND** `codesign -dv $APP_BUNDLE` shows valid signature

### Requirement: Bundle verification before exit
The build script MUST verify bundle completeness before exiting successfully.

#### Scenario: Verification passes for complete bundle
- **WHEN** all required components are present
- **THEN** script outputs "✓ Bundle verification passed"
- **AND** script exits with code 0

#### Scenario: Verification fails for incomplete bundle
- **WHEN** any required component is missing
- **THEN** script outputs "ERROR: Bundle verification failed" with missing items listed
- **AND** script exits with code 1