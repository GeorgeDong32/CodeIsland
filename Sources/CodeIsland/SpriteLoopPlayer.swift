import SwiftUI
import AppKit

/// T2 playback engine (spec: animation-performance.md): plays a pre-rendered
/// sprite strip — generated from the SAME SwiftUI mascot views by
/// `MascotRenderHarness/testRenderSpriteStrips` — with a discrete
/// `CAKeyframeAnimation` on `contentsRect`. Core Animation composites every
/// frame on the render server; the app does zero per-frame work. Pixel- and
/// cadence-identical to the live render, forever looping, never paused.
struct SpriteLoopPlayer: NSViewRepresentable {
    enum Scene: String {
        case idle
        case work

        init?(status: MascotAgentStatus) {
            switch status {
            case .idle: self = .idle
            case .processing, .running: self = .work
            case .waitingApproval, .waitingQuestion: return nil
            }
        }
    }

    let source: String
    let scene: Scene
    let size: CGFloat
    /// Global mascot speed setting (1.0 = normal); scales playback duration.
    var speed: Double = 1.0
    /// Gate parity with MascotTimeline: when animations are off, frame 0.
    var animationsActive: Bool = true

    // MARK: - Resource lookup

    struct Strip {
        let image: CGImage
        let cols: Int
        let rows: Int
        let frames: Int
        let frameInterval: Double
        let cellPixels: Int

        /// Rect of frame `i` in strip coordinates (row 0 at the TOP of the
        /// PNG, which is how the harness composes grids).
        func contentsRect(frame: Int) -> CGRect {
            let col = frame % cols
            let row = frame / cols
            let w = 1.0 / CGFloat(cols)
            let h = 1.0 / CGFloat(rows)
            // CALayer contentsRect uses a unit coordinate space with origin
            // at the BOTTOM-left; PNG row 0 is at the top.
            let x = CGFloat(col) / CGFloat(cols)
            let y = 1.0 - CGFloat(row + 1) / CGFloat(rows)
            return CGRect(x: x, y: y, width: w, height: h)
        }
    }

    private static var cache: [String: Strip] = [:]
    private static let cacheLock = NSLock()

    /// Supported sources whose resolved name has no strip of its own but whose
    /// MascotView routing lands on the SAME view as a striped sibling
    /// (e.g. "cursor-cli" -> CursorView == "cursor"). Without this map those
    /// sources silently fell back to live per-frame rendering.
    static let stripAliases: [String: String] = [
        "cursor-cli": "cursor",
        "qoderwork": "qoder",
        "codybuddycn": "codebuddy",
        "aiwork-cli": "aiwork",
        "google-antigravity": "gemini",
        "dsh": "claude",  // routes to the default ClawdView, same as "claude"
    ]

    static func strip(source: String, scene: Scene) -> Strip? {
        let canonical = stripAliases[source] ?? source
        let key = "\(canonical)-\(scene.rawValue)"
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let hit = cache[key] { return hit }
        guard let url = Bundle.appModule.url(
            forResource: key, withExtension: "png", subdirectory: "Resources/mascot-sprites"),
            let image = CGImageSourceCreateImageAtIndex(
                CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil)
        else { return nil }
        // Manifest lives next to the strips; entries keyed by file name.
        guard let manifestURL = Bundle.appModule.url(
            forResource: "manifest", withExtension: "json", subdirectory: "Resources/mascot-sprites"),
            let data = try? Data(contentsOf: manifestURL),
            let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let info = manifest["\(key).png"] as? [String: Any],
            let cols = info["cols"] as? Int,
            let rows = info["rows"] as? Int,
            let frames = info["frames"] as? Int,
            let interval = info["frameInterval"] as? Double
        else { return nil }
        let strip = Strip(image: image, cols: cols, rows: rows, frames: frames,
                          frameInterval: interval, cellPixels: image.width / cols)
        cache[key] = strip
        return strip
    }

    // MARK: - NSViewRepresentable

    final class PlayerView: NSView {
        var layerHost = CALayer()
        var animationKey = "sprite-loop"

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer = layerHost
            layerHost.masksToBounds = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        func play(_ strip: Strip, size: CGFloat, speed: Double, animate: Bool) {
            layerHost.frame = NSRect(origin: .zero, size: NSSize(width: size, height: size))
            layerHost.contents = strip.image
            layerHost.contentsGravity = .resize
            guard animate, speed > 0 else {
                layerHost.removeAnimation(forKey: animationKey)
                layerHost.contentsRect = strip.contentsRect(frame: 0)
                return
            }
            let anim = CAKeyframeAnimation(keyPath: "contentsRect")
            anim.values = (0..<strip.frames).map { strip.contentsRect(frame: $0) }
            anim.keyTimes = (0..<strip.frames).map { NSNumber(value: Double($0) / Double(strip.frames)) }
            anim.duration = Double(strip.frames) * strip.frameInterval / speed
            anim.calculationMode = .discrete
            anim.repeatCount = .infinity
            anim.fillMode = .forwards
            anim.isRemovedOnCompletion = false
            layerHost.removeAnimation(forKey: animationKey)
            layerHost.add(anim, forKey: animationKey)
        }
    }

    func makeNSView(context: Context) -> PlayerView {
        PlayerView(frame: NSRect(x: 0, y: 0, width: size, height: size))
    }

    func updateNSView(_ view: PlayerView, context: Context) {
        guard let strip = Self.strip(source: source, scene: scene) else { return }
        view.play(strip, size: size, speed: speed, animate: animationsActive)
    }
}
