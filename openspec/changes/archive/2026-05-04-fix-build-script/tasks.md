## 1. Phase 2: Bundle Assembly

- [x] 1.1 Add `mkdir -p "$APP_BUNDLE/Contents/Frameworks"` after other mkdirs
- [x] 1.2 Add `cp Info.plist "$APP_BUNDLE/Contents/Info.plist"` after mkdirs
- [x] 1.3 Verify Info.plist copy by checking file exists

## 2. Phase 3: Framework Embedding (New)

- [x] 2.1 Add Sparkle.framework copy step
- [x] 2.2 Add existence check for Sparkle.framework source
- [x] 2.3 Add `install_name_tool -add_rpath "@executable_path/../Frameworks"` step
- [x] 2.4 Place rpath step before any signing

## 3. Phase 4: Code Signing

- [x] 3.1 Reorder signing: bridge first, then Sparkle.framework, then app bundle
- [x] 3.2 Add Sparkle.framework signing command
- [x] 3.3 Ensure app signing includes entitlements

## 4. Verification

- [x] 4.1 Add verification section at script end
- [x] 4.2 Check Info.plist exists
- [x] 4.3 Check Sparkle.framework exists
- [x] 4.4 Check rpath configured via otool
- [x] 4.5 Exit with code 1 if verification fails

## 5. Structure and Comments

- [x] 5.1 Add phase markers: `# ============== Phase X: Name ==============`
- [x] 5.2 Reorganize existing code into appropriate phases
- [x] 5.3 Remove duplicate/redundant code if any

## 6. Testing

- [x] 6.1 Run `./build.sh` and verify app launches
- [x] 6.2 Check app displays correct version in Settings
- [x] 6.3 Verify Sparkle auto-update check works