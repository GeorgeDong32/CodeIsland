# Journal - George·Dong (Part 1)

> AI development session journal
> Started: 2026-08-31

---



## Session 1: Fix Markdown layout hangs and install 1.2.12

**Date**: 2026-10-09
**Task**: Fix Markdown layout hangs and install 1.2.12
**Branch**: `main`

### Summary

Continued Devin investigation; fixed nested-list layout stall (22.429s to 0.233s), verified 2000 tests with 4 skips, bumped to 1.2.12, built arm64 release, replaced and relaunched local app, and prepared verified APFS DMG.

### Main Changes

- Use bounded Markdown list-row measurement; preserve content, formatting and panel heights.
- Bump both bundle versions and bilingual changelog to 1.2.12; native git explicitly authorized.
- Install /Applications/CodeIsland.app; retain rollback at .build/install-backups/pre-1.2.12-zicb7lj0/; deliver ~/Downloads/CodeIsland-1.2.12-arm64.dmg.

### Git Commits

| Hash | Message |
|------|---------|
| `627ba5d` | (see git log) |
| `e4c9c2e` | (see git log) |

### Testing

- [OK] Full swift test: 2000 executed, 4 optional rendering-tool skips, 0 failures; swift build and release build passed.
- [OK] DMG checksum, mounted and installed nested signatures, version/architecture and executable hashes passed; launched PID 96950 and hook socket reachable.
- [OK] Repacked verified app as APFS after create-dmg HFS FinderInfo caused mounted signature failure; local artifact is ad-hoc signed and not notarized.

### Status

[OK] **Completed**
