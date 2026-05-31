## Why

The current `build.sh` script produces incomplete app bundles that fail to launch. Three critical components are missing: Info.plist not copied to Contents/, Sparkle.framework not embedded in Frameworks/, and rpath not configured for dynamic library loading. These gaps require manual fixes after each build, blocking proper distribution and testing.

## What Changes

- Copy `Info.plist` to `Contents/Info.plist` during app bundle creation
- Embed `Sparkle.framework` in `Contents/Frameworks/` for auto-update support
- Add `@executable_path/../Frameworks` rpath to the main binary
- Properly sign nested components (framework, bridge, app) in correct order
- Validate app bundle completeness before exiting

## Capabilities

### New Capabilities

- `build-bundle-integrity`: Ensures produced app bundles are complete and launchable without manual intervention

### Modified Capabilities

(None — this is a build tooling fix, not a spec-level behavior change)

## Impact

- **Files**: `build.sh` (complete rewrite of bundle assembly logic)
- **Dependencies**: Sparkle.framework (already in SPM dependencies)
- **Systems**: macOS app bundle structure, code signing workflow
- **Users**: Developers can run `./build.sh` and immediately test the result