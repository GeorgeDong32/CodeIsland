import XCTest
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
@testable import CodeIsland

/// Offscreen render harness for mascot animation review (#15).
///
/// Not a pass/fail test of pixels — it renders each mascot's scenes at a
/// series of timeline instants into contact-sheet PNGs so animation changes
/// can be reviewed without launching the app. Sheets land in
/// `$MASCOT_SHEET_DIR` (skipped entirely when the variable is unset, so CI
/// never pays for it).
@MainActor
final class MascotRenderHarness: XCTestCase {

    /// One-frame icon export for cli-icons assets: renders each source's
    /// mascot at a fixed instant on a transparent background. Opt-in like the
    /// contact sheets (`MASCOT_ICON_DIR` + `MASCOT_ICON_SOURCES=kiro,openclaw`).
    func testRenderCliIcons() throws {
        guard let outDir = ProcessInfo.processInfo.environment["MASCOT_ICON_DIR"] else {
            throw XCTSkip("MASCOT_ICON_DIR not set — harness is opt-in")
        }
        let sources = (ProcessInfo.processInfo.environment["MASCOT_ICON_SOURCES"] ?? "kiro,openclaw")
            .split(separator: ",").map(String.init)
        let status: MascotAgentStatus = switch ProcessInfo.processInfo.environment["MASCOT_ICON_STATUS"] {
        case "idle": .idle
        case "waitingApproval": .waitingApproval
        case "waitingQuestion": .waitingQuestion
        default: .processing
        }
        let time = Double(ProcessInfo.processInfo.environment["MASCOT_ICON_TIME"] ?? "") ?? 0.0

        try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        for source in sources {
            let icon = MascotIconFrame(source: source, status: status, time: time)
            let renderer = ImageRenderer(content: icon)
            renderer.scale = 2  // 64pt frame → 128px asset
            guard let cgImage = renderer.cgImage,
                  let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
            else {
                XCTFail("icon render failed for \(source)"); continue
            }
            try png.write(to: URL(fileURLWithPath: "\(outDir)/\(source).png"))
        }
    }

    /// Sprite strips for the T2 playback engine (spec:
    /// animation-performance.md). Renders each source's idle and work
    /// cycles — the SAME SwiftUI views, at their designed cadences — into
    /// grid-layout PNG strips plus a manifest JSON. `MASCOT_SPRITE_DIR`
    /// gates it (opt-in like the sheets); `MASCOT_SPRITE_SOURCES` limits the
    /// sources (comma-separated); `MASCOT_SPRITE_SCENES` limits scenes
    /// (idle,work). Alert stays live-rendered (short event-driven bursts).
    func testRenderSpriteStrips() throws {
        guard let outDir = ProcessInfo.processInfo.environment["MASCOT_SPRITE_DIR"] else {
            throw XCTSkip("MASCOT_SPRITE_DIR not set — harness is opt-in")
        }
        let sources = (ProcessInfo.processInfo.environment["MASCOT_SPRITE_SOURCES"] ?? SpriteStripConfig.defaultSources)
            .split(separator: ",").map(String.init)
        let scenes = (ProcessInfo.processInfo.environment["MASCOT_SPRITE_SCENES"] ?? "idle,work")
            .split(separator: ",").map(String.init)

        try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let fm = FileManager.default
        let manifestPath = outDir + "/manifest.json"
        var manifest: [String: Any] = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: manifestPath))) as? [String: Any]) ?? [:]

        for source in sources {
            for sceneName in scenes {
                let cfg = SpriteStripConfig(scene: sceneName)
                let status: MascotAgentStatus = cfg.scene == .work ? .processing : .idle
                let cols = SpriteStripConfig.gridCols
                let rows = (cfg.frames + cols - 1) / cols

                // Compose the grid with CoreGraphics: each cell one frame.
                let cell = SpriteStripConfig.cellPixels
                let gridW = cols * cell, gridH = rows * cell
                let space = CGColorSpace(name: CGColorSpace.sRGB)!
                guard let ctx = CGContext(data: nil, width: gridW, height: gridH,
                                          bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                    XCTFail("grid context failed for \(source)/\(sceneName)"); continue
                }
                ctx.clear(CGRect(x: 0, y: 0, width: gridW, height: gridH))

                var rendered = 0
                for frame in 0..<cfg.frames {
                    let t = Double(frame) * cfg.frameInterval
                    let view = SpriteStripFrame(source: source, status: status, time: t)
                    let renderer = ImageRenderer(content: view)
                    renderer.scale = CGFloat(SpriteStripConfig.renderScale)
                    guard let image = renderer.cgImage else {
                        XCTFail("frame \(frame) failed for \(source)/\(sceneName)"); continue
                    }
                    let col = frame % cols, row = frame / cols
                    // Row 0 at the TOP of the PNG: flip y accordingly.
                    let x = CGFloat(col * cell), y = CGFloat(gridH - (row + 1) * cell)
                    let cs = CGFloat(cell)
                    ctx.draw(image, in: CGRect(x: x, y: y, width: cs, height: cs))
                    rendered += 1
                }
                guard let gridImage = ctx.makeImage(),
                      let png = NSBitmapImageRep(cgImage: gridImage).representation(using: .png, properties: [:])
                else { XCTFail("encode failed for \(source)/\(sceneName)"); continue }
                let file = "\(source)-\(sceneName).png"
                try png.write(to: URL(fileURLWithPath: outDir + "/" + file))

                manifest[file]
                print("strip: \(file) \(gridW)x\(gridH) frames=\(rendered)")
            }
        }
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: manifestPath))
    }

    func testRenderContactSheets() throws {
        guard let outDir = ProcessInfo.processInfo.environment["MASCOT_SHEET_DIR"] else {
            throw XCTSkip("MASCOT_SHEET_DIR not set — harness is opt-in")
        }
        let sources = (ProcessInfo.processInfo.environment["MASCOT_SHEET_SOURCES"] ?? "claude,codex")
            .split(separator: ",").map(String.init)
        let statuses: [(String, MascotAgentStatus)] = [
            ("idle", .idle),
            ("processing", .processing),
            ("waitingApproval", .waitingApproval),
            ("waitingQuestion", .waitingQuestion),
        ]
        // Sample instants chosen to catch blink/quirk windows, not just phase 0.
        // `MASCOT_SHEET_TIMES` overrides them (comma-separated) so quirk windows
        // outside the default span can be inspected without editing the file.
        let times: [Double] = ProcessInfo.processInfo.environment["MASCOT_SHEET_TIMES"]
            .map { $0.split(separator: ",").compactMap { Double($0) } }
            ?? [0.0, 0.6, 1.3, 2.1, 2.9, 3.6, 4.4, 5.2, 6.1, 7.0, 7.8, 8.5]

        try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        for source in sources {
            for (label, status) in statuses {
                let sheet = MascotContactSheet(source: source, status: status, times: times)
                let renderer = ImageRenderer(content: sheet)
                renderer.scale = 4  // 4x for crisp pixel inspection
                guard let cgImage = renderer.cgImage else {
                    XCTFail("render failed for \(source)/\(label)"); continue
                }
                let rep = NSBitmapImageRep(cgImage: cgImage)
                guard let png = rep.representation(using: .png, properties: [:]) else {
                    XCTFail("png encode failed for \(source)/\(label)"); continue
                }
                let path = "\(outDir)/\(source)-\(label).png"
                try png.write(to: URL(fileURLWithPath: path))
            }
        }
    }

    /// Animated mascot GIFs for the README "Supported Tools" table: one
    /// seamless working-state loop per distinct mascot, on a transparent
    /// background, all on the same square canvas. Opt-in like the sheets:
    /// `MASCOT_GIF_DIR=docs/images/mascots` (+ optional
    /// `MASCOT_GIF_SOURCES=claude,kiro` to limit to some file names).
    func testRenderReadmeGifs() throws {
        guard let outDir = ProcessInfo.processInfo.environment["MASCOT_GIF_DIR"] else {
            throw XCTSkip("MASCOT_GIF_DIR not set — harness is opt-in")
        }
        let only = ProcessInfo.processInfo.environment["MASCOT_GIF_SOURCES"]
            .map { Set($0.split(separator: ",").map(String.init)) }
        try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        for spec in ReadmeGifSpec.all where only?.contains(spec.name) ?? true {
            let t0 = try XCTUnwrap(spec.loopStart(), "no calm \(spec.period)s window for \(spec.name)")
            var frames: [[UInt8]] = []
            for k in 0..<spec.frames {
                let t = t0 + spec.period * Double(k) / Double(spec.frames)
                let frame = MascotGifFrame(spec: spec, time: t)
                guard var pixels = ReadmeGif.rasterize(frame, size: Int(spec.viewSize)) else {
                    XCTFail("render failed for \(spec.name) @ \(t)"); break
                }
                if spec.contour { ReadmeGif.addContour(&pixels, size: Int(spec.viewSize)) }
                frames.append(pixels)
            }
            guard frames.count == spec.frames else { continue }
            let images = try ReadmeGif.centerOnCanvas(frames, size: Int(spec.viewSize), name: spec.name)
            let url = URL(fileURLWithPath: "\(outDir)/\(spec.name).gif")
            try ReadmeGif.writeGif(images, delays: spec.delays, to: url)
        }
    }
/// C6 visual acceptance (spec: animation-performance.md): every migrated
/// mascot's strips stay faithful — deterministic PROPERTY assertions on the
/// committed strips, not a re-render comparison (ImageRenderer output is not
/// bit-stable across runs for translucent edge elements, which made the
/// earlier compare-based version flap). Catches the regression classes that
/// matter: wrong cell geometry (the 54-in-64 vs full-cell bug shrank every
/// bbox envelope by ~16%), static/broken animation loops (zero inter-frame
/// delta), clipped poses (bbox escaping the cell), and missing frames.
func testSpriteStripFaithfulness() throws {
    guard let manifestPath = Bundle.appModule.path(forResource: "manifest", ofType: "json", inDirectory: "Resources/mascot-sprites") else {
        throw XCTSkip("bundled mascot-sprites not present in this test context")
    }
    let stripDir = (manifestPath as NSString).deletingLastPathComponent
    let manifestData = try Data(contentsOf: URL(fileURLWithPath: manifestPath))
    let manifestObj = try JSONSerialization.jsonObject(with: manifestData)
    guard let manifest = manifestObj as? [String: [String: Any]] else {
        throw XCTSkip("malformed manifest")
    }

    print("DBG stripDir=\(stripDir) manifest entries=\(manifest.count)")
    var checkedStrips = 0
    for (file, info) in manifest.sorted(by: { $0.key < $1.key }) {
        let cols = info["cols"] as! Int
        let rows = info["rows"] as! Int
        let frames = info["frames"] as! Int
        let cell = info["cell"] as! Int
        guard let stripSrc = CGImageSourceCreateWithURL(URL(fileURLWithPath: stripDir + "/" + file) as CFURL, nil),
              let stripImg = CGImageSourceCreateImageAtIndex(stripSrc, 0, nil) else {
            XCTFail("cannot load strip \(file)"); continue
        }
        XCTAssertEqual(stripImg.width, cols * cell, "\(file): width != cols*cell")
        XCTAssertEqual(stripImg.height, rows * cell, "\(file): height != rows*cell")

        var envMinX = Int.max, envMinY = Int.max, envMaxX = -1, envMaxY = -1
        var emptyFrames = 0
        var prevHash: UInt64? = nil
        var staticNeighbors = 0
        var frameHashes: Set<UInt64> = []
        var bboxYs: [Int] = []
        var coverage: [Int] = []

        for f in 0..<frames {
            let col = f % cols, row = f / cols
            // Crop the cell first (CGImage.cropping uses top-left origin,
            // matching the manifest's row/col layout), then scan the small
            // buffer whole — no region/stride arithmetic on the big strip.
            guard let cellCG = stripImg.cropping(to: CGRect(x: col * cell, y: row * cell, width: cell, height: cell)) else {
                XCTFail("\(file): crop failed frame \(f)"); continue
            }
            let buf = try Self.rgbaBuffer(of: cellCG)
            let px = [UInt8](buf.pixels)
            var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
            var hash: UInt64 = 1469598103934665603
            for y in 0..<cell {
                for x in 0..<cell {
                    let a = px[(y * cell + x) * 4 + 3]
                    if a > 64 {
                        minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
                    }
                    if x % 4 == 0 && y % 4 == 0 {  // sparse sample for the frame hash
                        hash = (hash ^ UInt64(a > 16 ? a : 0)) &* 1099511628211
                    }
                }
            }
            if maxX < 0 { emptyFrames += 1; continue }
            envMinX = min(envMinX, minX); envMinY = min(envMinY, minY)
            envMaxX = max(envMaxX, maxX + 1); envMaxY = max(envMaxY, maxY + 1)
            frameHashes.insert(hash)
            if let p = prevHash, p == hash { staticNeighbors += 1 }
            prevHash = hash
            bboxYs.append(minY); coverage.append(Int(hash % 1024))
        }

        XCTAssertNotEqual(emptyFrames, frames, "\(file): all frames empty")
        XCTAssertEqual(emptyFrames, 0, "\(file): \(emptyFrames) empty frames")
        // Animation must actually animate: the pose bbox or the frame hash
        // varies across the cycle. (Neighbor equality is legal — breathing
        // moves sub-pixel between adjacent 50ms frames.)
        let ySpread = (bboxYs.max() ?? 0) - (bboxYs.min() ?? 0)
        // Grok's mark is a deliberate static trademark (see GrokView) — its
        // strips are motionless BY DESIGN, same as the live view.
        let staticByDesign = file.hasPrefix("grok-")
        XCTAssertTrue(staticByDesign || frameHashes.count >= 2 || ySpread > 2,
            "\(file): \(frameHashes.count) distinct hashes, bbox-y spread \(ySpread) — loop may be static")
        // Geometry: per-source envelope baselines measured from the full-cell
        // strips. A 54-in-64 style regression multiplies every value by
        // 54/64 ≈ 0.844, pushing ALL of them below baseline-0.06; genuine
        // view changes update the baseline deliberately (regen + this table).
        let envW = Double(envMaxX - envMinX), envH = Double(envMaxY - envMinY)
        let occ = max(envW, envH) / Double(cell)
        let baseline = Self.stripEnvelopeBaselines[file] ?? 0.969
        XCTAssertGreaterThan(occ, baseline - 0.06,
            "\(file): envelope \(String(format: "%.3f", occ)) vs baseline \(baseline) — inner-margin geometry regression (54-in-64 scales everything by ~0.844)?")
        // Poses must stay inside their cell (no bleed into neighbors).
        XCTAssertGreaterThanOrEqual(envMinX, 0); XCTAssertLessThanOrEqual(envMaxX, cell)
        XCTAssertGreaterThanOrEqual(envMinY, 0); XCTAssertLessThanOrEqual(envMaxY, cell)
        if ProcessInfo.processInfo.environment["MASCOT_ENVELOPE_DUMP"] != nil {
            print("ENVELOPE \(file) \(String(format: "%.3f", occ))")
        }
        checkedStrips += 1
    }
    XCTAssertGreaterThanOrEqual(checkedStrips, 50, "expected the full fleet (27 sources x 2 scenes), got \(checkedStrips)")
}

/// Measured full-cell envelope occupancy per strip (idle+work). Update
/// alongside `scripts/gen-mascot-sprites.sh` regenerations.
private static let stripEnvelopeBaselines: [String: Double] = [
    "aiwork-idle.png": 0.867,
    "aiwork-work.png": 0.875,
    "antigravity-idle.png": 0.922,
    "antigravity-work.png": 0.938,
    "claude-idle.png": 0.969,
    "claude-work.png": 0.969,
    "cline-idle.png": 0.891,
    "cline-work.png": 0.938,
    "codebuddy-idle.png": 0.938,
    "codebuddy-work.png": 0.938,
    "codex-idle.png": 0.898,
    "codex-work.png": 0.938,
    "copilot-idle.png": 0.898,
    "copilot-work.png": 0.938,
    "cursor-idle.png": 0.906,
    "cursor-work.png": 0.938,
    "droid-idle.png": 0.875,
    "droid-work.png": 0.938,
    "gemini-idle.png": 0.922,
    "gemini-work.png": 0.938,
    "grok-idle.png": 0.664,
    "grok-work.png": 0.664,
    "hermes-idle.png": 0.922,
    "hermes-work.png": 0.938,
    "kimi-idle.png": 0.891,
    "kimi-work.png": 0.938,
    "kiro-idle.png": 0.891,
    "kiro-work.png": 0.859,
    "minimax-idle.png": 0.938,
    "minimax-work.png": 0.938,
    "openclaw-idle.png": 0.828,
    "openclaw-work.png": 0.812,
    "opencode-idle.png": 0.836,
    "opencode-work.png": 0.938,
    "pi-idle.png": 0.648,
    "pi-work.png": 0.938,
    "qoder-cli-idle.png": 0.969,
    "qoder-cli-work.png": 0.969,
    "qoder-idle.png": 0.906,
    "qoder-work.png": 0.938,
    "qwen-idle.png": 0.922,
    "qwen-work.png": 0.938,
    "stepfun-idle.png": 0.922,
    "stepfun-work.png": 0.938,
    "trae-idle.png": 0.922,
    "trae-work.png": 0.938,
    "traecli-idle.png": 0.969,
    "traecli-work.png": 0.969,
    "traecn-idle.png": 0.969,
    "traecn-work.png": 0.969,
    "workbuddy-idle.png": 0.922,
    "workbuddy-work.png": 0.938,
    "zcode-idle.png": 0.969,
    "zcode-work.png": 0.969,
]

private static func rgbaBuffer(of cg: CGImage) throws -> RGBABuffer {
    let w = cg.width, h = cg.height, bytes = w * h * 4
    let raw = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 64)
    defer { raw.deallocate() }
    memset(raw, 0, bytes)  // deterministic buffer if draw no-ops
    // Pin the byte order: without order32Big, ARM macs hand back 32Little
    // (A,R,G,B in memory) and every "+3" alpha read silently picks BLUE —
    // which produced phantom bboxes and flapping parity for hours.
    guard let ctx = CGContext(data: raw, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGImageByteOrderInfo.order32Big.rawValue) else {
        throw XCTSkip("bitmap context failed")
    }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    // CGImage data lands top-left first — same convention as PNG/PIL, which
    // every region/bbox helper here relies on. (Verified empirically: an
    // extra row-flip made region reads pick mirrored cells.)
    return RGBABuffer(pixels: Data(bytes: raw, count: bytes), width: w, height: h)
}

// MARK: - T2 playback capture (offline visual check of SpriteLoopPlayer)

/// Captures what SpriteLoopPlayer's layer actually SHOWS (model-state frame)
/// next to the live render at the same instant — catches flip/scale/margin
/// bugs that CPU sampling cannot see. Opt-in via MASCOT_PLAYER_CAPTURE_DIR.
func testCaptureSpritePlayback() async throws {
    // Other suites toggle the global animation gate; routed mascot views
    // observe it directly, which would switch our "live" reference into the
    // animated branch and break determinism. Pin it off, restore after.
    let savedVisibility = MascotAnimationGate.shared.isPanelVisible
    MascotAnimationGate.shared.setPanelVisible(false)
    defer { MascotAnimationGate.shared.setPanelVisible(savedVisibility) }
    // Assertions always run; MASCOT_PLAYER_CAPTURE_DIR additionally exports
    // the PNGs for offline inspection.
    let outDir = ProcessInfo.processInfo.environment["MASCOT_PLAYER_CAPTURE_DIR"]
    if let outDir { try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true) }
    try await MainActor.run {
    for (source, scene) in [("claude", SpriteLoopPlayer.Scene.idle), ("pi", SpriteLoopPlayer.Scene.work)] {
        guard let strip = SpriteLoopPlayer.strip(source: source, scene: scene) else {
            XCTFail("no strip for \(source)/\(scene)"); continue
        }
        let view = SpriteLoopPlayer.PlayerView(frame: NSRect(x: 0, y: 0, width: 27, height: 27))
        view.play(strip, size: 27, speed: 1, animate: false)
        view.layoutSubtreeIfNeeded()
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        let png = rep.representation(using: .png, properties: [:])!
        if let outDir { try png.write(to: URL(fileURLWithPath: outDir + "/player-\(source)-\(scene.rawValue).png")) }

        // ASSERTION, not just export: what the player layer shows must match
        // the live view's alpha silhouette at app geometry, to the pixel
        // (bbox within 3px on every axis). This is the guard that FAILS on
        // inner-margin geometry regressions (54-in-64 shrank playback to 84%).
        guard let playerBuf = rep.bitmapData.map({
            var b = RGBABuffer(pixels: Data(bytes: $0, count: rep.bytesPerRow * rep.pixelsHigh), width: rep.pixelsWide, height: rep.pixelsHigh)
            b.strideOverride = rep.bytesPerRow
            return b
        }) else {
            XCTFail("no bitmap data for \(source)"); continue
        }

        // Reference: frame-0 cell decoded from the SAME strip the player
        // loaded — pixel-identical source, so this isolates the playback
        // path (contentsRect math, contents scaling, flip) with zero
        // renderer nondeterminism. (A live re-render as reference flapped
        // under full-suite ordering: earlier layout suites leave SwiftUI
        // transaction state that changes ImageRenderer/NSHostingView
        // capture; shape-only assertions were not stable across orders.)
        // Strip-content geometry itself (full-cell vs inner-margin) is
        // guarded by testSpriteStripFaithfulness's envelope assertions and
        // the human visual sign-off on release.
        let cp = strip.cellPixels
        guard let cell0CG = strip.image.cropping(to: CGRect(x: 0, y: 0, width: cp, height: cp)) else {
            XCTFail("crop frame0 failed for \(source)"); continue
        }
        let cellBuf = try Self.rgbaBuffer(of: cell0CG)
        let cellBox = Self.alphaBBoxOf(cellBuf)
        // Downscale expectations: player shows the cell at 27pt backing;
        // compare RELATIVE silhouette (bbox position/size as fraction of the
        // cell) so scale never matters — only geometry drift does.
        let pb = Self.alphaBBoxOf(playerBuf)
        guard let pBox = pb, let cBox = cellBox else {
            XCTFail("\(source)/\(scene): empty render player=\(String(describing: pb)) cell=\(String(describing: cellBox))"); continue
        }
        // Sparse boolean alpha grid (n x n, threshold 64) on both sides —
        // catches wrong-row contentsRect (adjacent frames differ in pattern
        // even when their bboxes are close) as well as flips and scaling.
        let n = 13
        let playerGrid = Self.alphaGrid(playerBuf, n: n)
        var cellCrop = RGBABuffer(pixels: Data(count: cp * cp * 4), width: cp, height: cp)
        cellCrop.pixels.withUnsafeMutableBytes { dst in
            cellBuf.pixels.withUnsafeBytes { src in
                for row in 0..<cp {
                    memcpy(dst.baseAddress! + row * cp * 4,
                           src.baseAddress! + row * cellBuf.stride,
                           cp * 4)
                }
            }
        }
        let cellGrid = Self.alphaGrid(cellCrop, n: n)
        let mismatches = zip(playerGrid, cellGrid).filter { $0.0 != $0.1 }.count
        let agreement = 1.0 - Double(mismatches) / Double(n * n)
        // bbox agreement as a coarse precondition, pattern as the strict one
        let playerW = Double(playerBuf.width), cellW = Double(cp)
        let relP = { (b: (Int, Int, Int, Int)) in
            [Double(b.0) / playerW, Double(b.1) / playerW, Double(b.2) / playerW, Double(b.3) / playerW]
        }
        let relC = { (b: (Int, Int, Int, Int)) in
            [Double(b.0) / cellW, Double(b.1) / cellW, Double(b.2) / cellW, Double(b.3) / cellW]
        }
        let pr = relP(pBox), cr = relC(cBox)
        let bboxOK = zip(pr, cr).allSatisfy { abs($0.0 - $0.1) <= 0.08 }
        XCTAssertTrue(bboxOK && agreement >= 0.93,
            "\(source)/\(scene): player pattern agreement \(String(format: "%.2f", agreement)), rel-bbox \(pr.map { String(format: "%.3f", $0) }) vs \(cr.map { String(format: "%.3f", $0) }) — playback geometry drift")
    }
    }
}

/// n x n boolean alpha(>64) grid sampled across a whole buffer.
private static func alphaGrid(_ buf: RGBABuffer, n: Int) -> [Bool] {
    let px = [UInt8](buf.pixels)
    var grid: [Bool] = []
    for gy in 0..<n {
        for gx in 0..<n {
            let x = (gx * buf.width) / n, y = (gy * buf.height) / n
            grid.append(px[y * buf.stride + x * 4 + 3] > 64)
        }
    }
    return grid
}

/// Alpha(>64) bounding box over a sub-region (top-left origin, w x h).
private static func alphaBBox(_ buf: RGBABuffer, regionX: Int, regionY: Int, w: Int, h: Int) -> (Int, Int, Int, Int)? {
    let px = [UInt8](buf.pixels)
    var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
    for y in 0..<h {
        for x in 0..<w where px[(regionY + y) * buf.stride + (regionX + x) * 4 + 3] > 64 {
            minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
        }
    }
    return maxX >= 0 ? (minX, minY, maxX + 1, maxY + 1) : nil
}

/// Alpha(>64) bounding box over a whole buffer.
private static func alphaBBoxOf(_ buf: RGBABuffer) -> (Int, Int, Int, Int)? {
    let px = [UInt8](buf.pixels)
    var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
    for y in 0..<buf.height {
        for x in 0..<buf.width where px[y * buf.stride + x * 4 + 3] > 64 {
            minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
        }
    }
    return maxX >= 0 ? (minX, minY, maxX + 1, maxY + 1) : nil
}

}

// MARK: - README GIF export

/// One README GIF: which mascot, which scene, and how to loop it.
private struct ReadmeGifSpec {
    /// Output file name (`<name>.gif`) — the key the README links.
    let name: String
    /// Routing key for `routedMascot` (e.g. Factory's mascot is `droid`).
    let source: String
    var status: MascotAgentStatus = .processing
    /// Loop length in seconds: a common multiple of the scene's periodic
    /// motions (bounce, key sweep…) so the last frame flows into the first.
    let period: Double
    let frames: Int
    /// Mascot frame side in points (rendered 1pt = 1px). Chosen as the scene
    /// viewport's unit count × a whole number so the art sits on an integer
    /// pixel grid: 16-unit viewports × 7 → 112; Kiro's 14-unit one × 8 → 112
    /// (the keyboard-less ghost would look undersized at 7).
    var viewSize: CGFloat = 112
    /// White / near-white silhouettes (Codex's cloud, Kiro's ghost, Grok's
    /// mark) would vanish on a light page: give their light edges a dark
    /// contour, which disappears again on a dark page.
    var contour = false
    /// False at instants holding a one-off beat (blink, thinking pause,
    /// signal flash) that would stutter if replayed every loop.
    var isCalm: (Double) -> Bool = { _ in true }
    /// Extra constraint on the loop's start instant, for secondary motions
    /// whose period doesn't divide `period` (keeps their seam jump invisible).
    var startOK: (Double) -> Bool = { _ in true }

    /// Per-frame GIF delays (seconds, centisecond-quantised with error
    /// carried forward so the loop keeps its exact length).
    var delays: [Double] {
        (0..<frames).map { k in
            let a = (period * Double(k) / Double(frames) * 100).rounded()
            let b = (period * Double(k + 1) / Double(frames) * 100).rounded()
            return (b - a) / 100
        }
    }

    /// First start instant (on a 50 ms grid) whose sampled frames are all calm.
    func loopStart() -> Double? {
        for step in 0..<4000 {
            let t0 = Double(step) * 0.05
            guard startOK(t0) else { continue }
            let calm = (0..<frames).allSatisfy { k in
                isCalm(t0 + period * Double(k) / Double(frames))
            }
            if calm { return t0 }
        }
        return nil
    }

    /// Calm = eyes fully open and outside the mascot's work-pause quirk.
    /// Seeds/cycles mirror the mascot's `workCanvas`.
    static func calm(blinkSeed: UInt64?, pause: (cycle: Double, duration: Double, seed: UInt64)?)
        -> (Double) -> Bool {
        { t in
            if let blinkSeed, MascotMotion.blink(t, seed: blinkSeed) < 0.999 { return false }
            if let pause, MascotMotion.quirk(t, cycle: pause.cycle, duration: pause.duration, seed: pause.seed) > 0 {
                return false
            }
            return true
        }
    }

    /// True when `t`'s phase within `cycle` falls inside `window` (fractions).
    static func phase(_ t: Double, cycle: Double, in window: ClosedRange<Double>) -> Bool {
        window.contains(t.truncatingRemainder(dividingBy: cycle) / cycle)
    }

    /// Every distinct mascot, named by its README key. Aliases that share a
    /// mascot (cursor-cli, qoder-cli/qoderwork, traecn/traecli, codybuddycn,
    /// google-antigravity → Gemini, omp → Pi, aiwork-cli, dsh/zcode → Clawd)
    /// get no GIF of their own.
    static let all: [ReadmeGifSpec] = [
        // Clawd: 0.35s bounce ×3; typing arms are stroke-randomised anyway.
        ReadmeGifSpec(name: "claude", source: "claude", period: 1.05, frames: 15,
                      isCalm: { t in
                          let scan = t.truncatingRemainder(dividingBy: 10.0)
                          return !(scan > 5.6 && scan < 7.0)
                              && calm(blinkSeed: 0xB1, pause: (11.0, 1.4, 0x7A9))(t)
                      }),
        // Shared keyboard template: 0.4s bounce × 0.6s key sweep → 1.2s.
        ReadmeGifSpec(name: "codex", source: "codex", period: 1.2, frames: 15, contour: true,
                      isCalm: calm(blinkSeed: nil, pause: (12.0, 1.2, 0xDE2))),
        ReadmeGifSpec(name: "gemini", source: "gemini", period: 1.2, frames: 15,
                      isCalm: calm(blinkSeed: 0x40E, pause: (12.9, 1.2, 0x40D))),
        // Shimmer (1.5s) doesn't divide 1.2s: start where it reads the same
        // at both ends of the loop (phase .35 / .85).
        ReadmeGifSpec(name: "cursor", source: "cursor", period: 1.2, frames: 15,
                      isCalm: calm(blinkSeed: 0xE2F, pause: (11.0, 1.2, 0xE2E)),
                      startOK: { phase($0, cycle: 1.5, in: 0.33...0.37) || phase($0, cycle: 1.5, in: 0.83...0.87) }),
        ReadmeGifSpec(name: "trae", source: "trae", period: 1.2, frames: 15,
                      isCalm: calm(blinkSeed: 0x9C8, pause: (12.9, 1.2, 0x9C7))),
        // Copilot's blink (3.2s) and ear signal (2.5s) are fixed windows.
        ReadmeGifSpec(name: "copilot", source: "copilot", period: 1.2, frames: 15,
                      isCalm: { t in
                          !phase(t, cycle: 3.2, in: (1.45 / 3.2)...(1.65 / 3.2))
                              && !phase(t, cycle: 2.5, in: (1.95 / 2.5)...(2.35 / 2.5))
                              && calm(blinkSeed: nil, pause: (11.6, 1.2, 0x8F8))(t)
                      }),
        ReadmeGifSpec(name: "qoder", source: "qoder", period: 1.2, frames: 15,
                      isCalm: calm(blinkSeed: 0x1BD, pause: (11.4, 1.2, 0x1BC))),
        // Droid: 0.5s bounce ×2 (its 0.12s key sweep just restarts a row).
        ReadmeGifSpec(name: "factory", source: "droid", period: 1.0, frames: 12,
                      isCalm: calm(blinkSeed: 0x297, pause: (10.6, 1.2, 0x296))),
        ReadmeGifSpec(name: "codebuddy", source: "codebuddy", period: 1.2, frames: 15,
                      isCalm: calm(blinkSeed: 0x132, pause: (10.2, 1.2, 0x131))),
        ReadmeGifSpec(name: "stepfun", source: "stepfun", period: 1.2, frames: 15,
                      isCalm: calm(blinkSeed: 0x100E, pause: (12.6, 1.2, 0x100D))),
        ReadmeGifSpec(name: "opencode", source: "opencode", period: 1.2, frames: 15,
                      isCalm: calm(blinkSeed: 0xC89, pause: (11.1, 1.2, 0xC88))),
        ReadmeGifSpec(name: "qwen", source: "qwen", period: 1.2, frames: 15,
                      isCalm: calm(blinkSeed: 0x7F6, pause: (9.6, 1.2, 0x7F5))),
        ReadmeGifSpec(name: "antigravity", source: "antigravity", period: 1.2, frames: 15,
                      isCalm: calm(blinkSeed: 0xAEF, pause: (11.6, 1.2, 0xAEE))),
        ReadmeGifSpec(name: "workbuddy", source: "workbuddy", period: 1.2, frames: 15,
                      isCalm: calm(blinkSeed: 0x89F, pause: (12.3, 1.2, 0x89E))),
        ReadmeGifSpec(name: "hermes", source: "hermes", period: 1.2, frames: 15,
                      isCalm: calm(blinkSeed: 0xCDD, pause: (11.3, 1.2, 0xCDC))),
        ReadmeGifSpec(name: "kimi", source: "kimi", period: 1.2, frames: 15,
                      isCalm: calm(blinkSeed: 0x35F, pause: (10.8, 1.2, 0x35E))),
        // AiWork's caret pulses every 0.9s: start in its dark half so the
        // loop seam lands while it's off at both ends.
        ReadmeGifSpec(name: "aiwork", source: "aiwork", period: 1.2, frames: 15,
                      isCalm: calm(blinkSeed: 0xD7C2, pause: (10.7, 1.2, 0xD7C1)),
                      startOK: { phase($0, cycle: 0.9, in: 0.5...0.66) }),
        // Cline: 0.5s bounce ×2.
        ReadmeGifSpec(name: "cline", source: "cline", period: 1.0, frames: 12,
                      isCalm: calm(blinkSeed: 0xFE3, pause: (11.1, 1.2, 0xFE2))),
        // 0.42s bounce ×3.
        ReadmeGifSpec(name: "openclaw", source: "openclaw", period: 1.26, frames: 15,
                      isCalm: calm(blinkSeed: 0xC1A7, pause: (10.5, 1.2, 0xC1A4))),
        ReadmeGifSpec(name: "pi", source: "pi", period: 1.2, frames: 15,
                      isCalm: calm(blinkSeed: 0x9BB, pause: nil)),
        // Kiro: 0.45s hover-bob ×4 on a 14-unit viewport.
        ReadmeGifSpec(name: "kiro", source: "kiro", period: 1.8, frames: 20, viewSize: 112, contour: true,
                      isCalm: calm(blinkSeed: 0x419C, pause: (11.5, 1.2, 0x419B))),
        // Grok's mark is deliberately static — a single frame. Vector art, so
        // no unit grid: sized to match the others' visual weight.
        ReadmeGifSpec(name: "grok", source: "grok", period: 1.0, frames: 1, viewSize: 132, contour: true),
    ]
}

/// A mascot pinned to one timeline instant, sized for GIF export.
private struct MascotGifFrame: View {
    let spec: ReadmeGifSpec
    let time: Double

    var body: some View {
        MascotContactSheet.routedMascot(source: spec.source, status: spec.status, size: spec.viewSize)
            .environment(\.mascotAnimationsActive, false)
            .environment(\.mascotStaticTime, time)
            .frame(width: spec.viewSize, height: spec.viewSize)
    }
}

private enum ReadmeGif {
    /// Uniform output canvas (px) for every README GIF.
    static let canvas = 128
    /// Supersampling factor; each output pixel takes the sample nearest its
    /// centre, i.e. aliased point sampling — hard edges, no AA fringe.
    static let supersample = 4

    /// Renders `view` (a `size`×`size` pt frame) and returns straight-alpha
    /// RGBA8 at `size`×`size` px with alpha forced to 0 or 255 — GIF
    /// transparency is 1-bit, and point sampling + un-premultiplying keeps
    /// edge pixels from turning into a dark halo. Soft drop shadows (< 50%
    /// alpha) fall away, which is what we want on arbitrary page colours.
    @MainActor
    static func rasterize<V: View>(_ view: V, size: Int) -> [UInt8]? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = CGFloat(supersample)
        guard let cg = renderer.cgImage,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: cg.width, height: cg.height,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard let data = ctx.data else { return nil }
        let hi = data.assumingMemoryBound(to: UInt8.self)
        let rowBytes = ctx.bytesPerRow

        var out = [UInt8](repeating: 0, count: size * size * 4)
        let maxX = cg.width - 1, maxY = cg.height - 1
        for y in 0..<size {
            for x in 0..<size {
                let sx = min(maxX, x * supersample + supersample / 2)
                let sy = min(maxY, y * supersample + supersample / 2)
                let i = sy * rowBytes + sx * 4
                let a = Int(hi[i + 3])
                guard a >= 128 else { continue }
                let o = (y * size + x) * 4
                for c in 0..<3 {
                    out[o + c] = UInt8(min(255, (Int(hi[i + c]) * 255 + a / 2) / a))
                }
                out[o + 3] = 255
            }
        }
        return out
    }

    /// Paints transparent pixels within `radius` px of a light opaque pixel
    /// (luma ≥ 0.5) in near-black. Keyed on light pixels only, so dark parts
    /// such as the keyboard keep their exact size.
    static func addContour(_ f: inout [UInt8], size: Int, radius: Int = 3) {
        var light = [Bool](repeating: false, count: size * size)
        for i in 0..<(size * size) where f[i * 4 + 3] != 0 {
            let luma = 0.2126 * Double(f[i * 4]) + 0.7152 * Double(f[i * 4 + 1]) + 0.0722 * Double(f[i * 4 + 2])
            light[i] = luma >= 128
        }
        let src = f
        for y in 0..<size {
            for x in 0..<size where src[(y * size + x) * 4 + 3] == 0 {
                var near = false
                search: for oy in -radius...radius {
                    for ox in -radius...radius where ox * ox + oy * oy <= radius * radius {
                        let nx = x + ox, ny = y + oy
                        if nx >= 0, nx < size, ny >= 0, ny < size, light[ny * size + nx] {
                            near = true; break search
                        }
                    }
                }
                if near {
                    let o = (y * size + x) * 4
                    f[o] = 0x14; f[o + 1] = 0x16; f[o + 2] = 0x1A; f[o + 3] = 255
                }
            }
        }
    }

    /// Centres the union of all frames' opaque pixels on the shared canvas
    /// (whole-pixel shift, so nothing resamples) and returns CGImages.
    static func centerOnCanvas(_ frames: [[UInt8]], size: Int, name: String) throws -> [CGImage] {
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        for f in frames {
            for y in 0..<size {
                for x in 0..<size where f[(y * size + x) * 4 + 3] != 0 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard minX <= maxX else { throw GifError.blank(name) }
        let bw = maxX - minX + 1, bh = maxY - minY + 1
        guard bw <= canvas, bh <= canvas else { throw GifError.tooBig(name, bw, bh) }
        let dx = (canvas - bw) / 2 - minX, dy = (canvas - bh) / 2 - minY

        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw GifError.encode(name) }
        return try frames.map { f in
            var px = [UInt8](repeating: 0, count: canvas * canvas * 4)
            for y in minY...maxY {
                for x in minX...maxX {
                    let s = (y * size + x) * 4, d = ((y + dy) * canvas + (x + dx)) * 4
                    px[d..<(d + 4)] = f[s..<(s + 4)]
                }
            }
            // Alpha is 0/255 with RGB zeroed under 0, so straight == premultiplied.
            guard let provider = CGDataProvider(data: Data(px) as CFData),
                  let image = CGImage(width: canvas, height: canvas, bitsPerComponent: 8,
                                      bitsPerPixel: 32, bytesPerRow: canvas * 4, space: space,
                                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                      provider: provider, decode: nil, shouldInterpolate: false,
                                      intent: .defaultIntent)
            else { throw GifError.encode(name) }
            return image
        }
    }

    /// Infinite-loop GIF via ImageIO.
    static func writeGif(_ images: [CGImage], delays: [Double], to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, images.count, nil)
        else { throw GifError.encode(url.lastPathComponent) }
        CGImageDestinationSetProperties(dest, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        for (image, delay) in zip(images, delays) {
            CGImageDestinationAddImage(dest, image, [
                kCGImagePropertyGIFDictionary: [
                    kCGImagePropertyGIFDelayTime: delay,
                    kCGImagePropertyGIFUnclampedDelayTime: delay,
                ],
            ] as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { throw GifError.encode(url.lastPathComponent) }
    }

    enum GifError: Error {
        case blank(String)
        case tooBig(String, Int, Int)
        case encode(String)
    }
}

/// Single transparent-background frame sized for a cli-icons asset.
private struct MascotIconFrame: View {
    let source: String
    let status: MascotAgentStatus
    let time: Double

    var body: some View {
        MascotContactSheet.routedMascot(source: source, status: status, size: 58)
            .environment(\.mascotAnimationsActive, false)
            .environment(\.mascotStaticTime, time)
            .frame(width: 64, height: 64)
    }
}

/// One row of frames for a (source, status) pair, each frame rendered at a
/// fixed timeline instant via the static-frame path of MascotTimeline
/// (mascotAnimationsActive=false renders content(mascotStaticTime) once).
private struct MascotContactSheet: View {
    let source: String
    let status: MascotAgentStatus
    let times: [Double]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(times, id: \.self) { t in
                VStack(spacing: 2) {
                    mascot
                        .environment(\.mascotAnimationsActive, false)
                        .environment(\.mascotStaticTime, t)
                        .frame(width: 64, height: 64)
                        .background(Color.black)
                    Text(String(format: "%.1f", t))
                        .font(.system(size: 7, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .padding(6)
        .background(Color.black)
    }

    /// Direct routing (bypasses MascotView, which re-injects the live gate).
    private var mascot: some View {
        Self.routedMascot(source: source, status: status, size: 54)
    }

    @ViewBuilder
    static func routedMascot(source: String, status: MascotAgentStatus, size: CGFloat) -> some View {
        switch source {
        case "codex": DexView(status: status, size: size)
        case "grok": GrokView(status: status, size: size)
        case "gemini": GeminiView(status: status, size: size)
        case "cursor": CursorView(status: status, size: size)
        case "trae": TraeView(status: status, size: size)
        case "copilot": CopilotView(status: status, size: size)
        case "qoder": QoderView(status: status, size: size)
        case "droid": DroidView(status: status, size: size)
        case "codebuddy": BuddyView(status: status, size: size)
        case "stepfun": StepFunView(status: status, size: size)
        case "opencode": OpenCodeView(status: status, size: size)
        case "qwen": QwenView(status: status, size: size)
        case "antigravity": AntiGravityView(status: status, size: size)
        case "workbuddy": WorkBuddyView(status: status, size: size)
        case "hermes": HermesView(status: status, size: size)
        case "openclaw": OpenClawView(status: status, size: size)
        case "kiro": KiroView(status: status, size: size)
        case "kimi": KimiView(status: status, size: size)
        case "pi": PiView(status: status, size: size)
        case "cline": ClineView(status: status, size: size)
        case "aiwork", "aiwork-cli": AiWorkView(status: status, size: size)
        case "minimax": McodeView(status: status, size: size)
        default: ClawdView(status: status, size: size)
        }
    }
}

/// Frame/grid geometry for T2 sprite strips. Durations cover every quirk
/// cycle in the mascot fleet (7–12s); cadences match the views' designed
/// timeline intervals so playback is pixel-identical to the live render.
struct RGBABuffer {
    var pixels: Data
    let width: Int
    let height: Int
    /// Bytes per row — NSBitmapImageRep pads rows (54px -> 224 bytes).
    var strideOverride: Int?
    var stride: Int { strideOverride ?? width * 4 }
}

struct SpriteStripConfig {
    enum Scene { case idle, work }

    static let gridCols = 20
    static let renderScale = 2
    static let framePt: CGFloat = 64
    static var cellPixels: Int { Int(framePt) * renderScale }

    /// The full routed-source fleet (default sprite generation set).
    static let defaultSources = "claude,codex,grok,gemini,cursor,trae,traecn,traecli,copilot,qoder,qoder-cli,droid,codebuddy,stepfun,opencode,qwen,antigravity,workbuddy,hermes,openclaw,kiro,kimi,pi,cline,aiwork,zcode,minimax"

    static func scene(_ name: String) -> Scene? {
        switch name { case "idle": return .idle; case "work": return .work; default: return nil }
    }

    init(scene name: String) {
        let s = SpriteStripConfig.scene(name) ?? .idle
        self.scene = s
    }

    let scene: Scene

    /// Cadence = the views' own timeline interval (floored to 20fps in
    /// MascotTimeline); duration covers the longest quirk cycle in the fleet.
    var frameInterval: Double { scene == .idle ? 0.12 : 0.05 }
    var duration: Double { scene == .idle ? 12.0 : 13.0 }
    var frames: Int { Int((duration / frameInterval).rounded()) }
}

/// One sprite cell: the routed mascot at a fixed timeline instant, sized to
/// the strip cell (square framePt canvas, transparent background).
private struct SpriteStripFrame: View {
    let source: String
    let status: MascotAgentStatus
    let time: Double

    var body: some View {
        // FULL-CELL geometry: the live panel draws the mascot at exactly its
        // cell size (MascotView(size: 27) fills 27pt). The strip must mirror
        // that 1:1 — any inner margin (e.g. the sheet convention 54-in-64)
        // scales every mascot down and moves the clipping line on poses.
        MascotContactSheet.routedMascot(source: source, status: status, size: SpriteStripConfig.framePt)
            .environment(\.mascotAnimationsActive, false)
            .environment(\.mascotStaticTime, time)
            .frame(width: SpriteStripConfig.framePt, height: SpriteStripConfig.framePt)
    }
}
