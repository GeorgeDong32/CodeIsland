import SwiftUI

/// Pi — Earendil Works' pi.dev mascot: pixel-art cream tile with the official
/// 4×4 "Pi" monogram (chunky square P + dotless i, from pi.dev's favicon.svg).
/// Near-black glyph on warm off-white — the brand carries it, monochrome like
/// ZcodeView/DexView. The mark is never dismembered; sleep breathes via
/// opacity, and the standby quirk lets the dotless i briefly find its tittle.
struct PiView: View {
    let status: MascotAgentStatus
    var size: CGFloat = 27
    @State private var alive = false

    // pi.dev favicon palette — warm off-white tile, near-black monogram.
    // (favicon.svg draws #111111 on transparent; the cream ground is the app
    // bitmap's rendering — kept here so the mark reads on the dark island.)
    private static let tileC    = Color(red: 0.94, green: 0.935, blue: 0.925) // #F0EFEC
    private static let tileEdge = Color(red: 1.00, green: 1.00, blue: 0.99)
    private static let piC      = Color(red: 0.04, green: 0.04, blue: 0.043)  // #0A0A0B
    private static let legC     = Color(red: 0.35, green: 0.33, blue: 0.31)
    private static let alertC   = Color(red: 1.0, green: 0.42, blue: 0.12)
    private static let kbBase   = Color(red: 0.18, green: 0.18, blue: 0.20)
    private static let kbKey    = Color(red: 0.40, green: 0.40, blue: 0.42)
    private static let kbHi     = Color.white

    var body: some View {
        ZStack {
            switch status {
            case .idle:                 sleepScene
            case .processing, .running: workScene
            case .waitingApproval, .waitingQuestion: alertScene
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .onAppear { alive = true }
        .onChange(of: status) {
            alive = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { alive = true }
        }
    }

    // ── Coordinate helper ──
    private struct V {
        let ox: CGFloat, oy: CGFloat, s: CGFloat
        let y0: CGFloat

        init(_ sz: CGSize, svgW: CGFloat = 16, svgH: CGFloat = 14, svgY0: CGFloat = 3) {
            s = min(sz.width / svgW, sz.height / svgH)
            ox = (sz.width - svgW * s) / 2
            oy = (sz.height - svgH * s) / 2
            y0 = svgY0
        }
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, dy: CGFloat = 0) -> CGRect {
            CGRect(x: ox + x * s, y: oy + (y - y0 + dy) * s, width: w * s, height: h * s)
        }
    }

    private func lerp(_ keyframes: [(CGFloat, CGFloat)], at pct: CGFloat) -> CGFloat {
        guard let first = keyframes.first else { return 0 }
        if pct <= first.0 { return first.1 }
        for i in 1..<keyframes.count {
            if pct <= keyframes[i].0 {
                let t = (pct - keyframes[i-1].0) / (keyframes[i].0 - keyframes[i-1].0)
                return keyframes[i-1].1 + (keyframes[i].1 - keyframes[i-1].1) * t
            }
        }
        return keyframes.last?.1 ?? 0
    }

    // ── Tile body: rounded cream square with an edge highlight ──
    private func drawTile(_ c: GraphicsContext, v: V, dy: CGFloat,
                          squashX: CGFloat = 1, squashY: CGFloat = 1) {
        let x: CGFloat = 2, y: CGFloat = 3.5, w: CGFloat = 12, h: CGFloat = 8.5
        let cx = x + w / 2, cy = y + h / 2
        let rx = cx + (x - cx) * squashX
        let rw = w * squashX
        let ry = cy + (y - cy) * squashY
        let rh = h * squashY
        // Rounded-rect tile (pixel-corner radius ≈ 1 unit). The row-stack
        // trick ZcodeView uses would spill the bottom row past the clip —
        // invisible on its near-black tile, glaring on cream.
        c.fill(Path(roundedRect: v.r(rx, ry, rw, rh, dy: dy), cornerRadius: 1.1 * v.s),
               with: .color(Self.tileC))
        // Edge highlight — one light line under the top rounding.
        c.fill(Path(v.r(rx + 0.5, ry + 1, rw - 1, 0.5, dy: dy)),
               with: .color(Self.tileEdge.opacity(0.8)))
    }

    // ── Official "Pi" monogram: 4×4 unit grid (pi.dev favicon.svg),
    // matrix [1110; 1010; 1101; 1001] — square P (stem col 0, bowl closing
    // inward at r2c1) + dotless i (col 3, rows 2-3). Structurally complete
    // at all times: breathing dims the whole mark, never a piece of it.
    // `tittle` lights the missing dot above the i (standby quirk only). ──
    private func drawPi(_ c: GraphicsContext, v: V, dy: CGFloat,
                        color: Color = PiView.piC, tittle: Bool = false) {
        let u: CGFloat = 1.7                       // monogram unit
        let mx: CGFloat = 2 + (12 - 4 * u) / 2     // centred in the tile
        let my: CGFloat = 3.5 + (8.5 - 4 * u) / 2
        let cells: [(Int, Int)] = [
            (0, 0), (0, 1), (0, 2),   // P top bar
            (1, 0), (1, 2),           // stem + bowl wall
            (2, 0), (2, 1), (2, 3),   // stem + bowl bottom + i stem top
            (3, 0), (3, 3),           // stem bottom + i stem bottom
        ]
        for (row, col) in cells {
            c.fill(Path(v.r(mx + CGFloat(col) * u + 0.01,
                            my + CGFloat(row) * u + 0.01,
                            u + 0.02, u + 0.02, dy: dy)),
                   with: .color(color))
        }
        if tittle {
            // The i finally finds its dot — a square tittle in the empty
            // top-right cell, above the i stem.
            let d = u * 0.8
            c.fill(Path(v.r(mx + 3 * u + (u - d) / 2, my + 1 * u + (u - d) / 2, d, d, dy: dy)),
                   with: .color(color))
        }
    }

    private func drawShadow(_ c: GraphicsContext, v: V, width: CGFloat = 9, opacity: Double = 0.3) {
        c.fill(Path(v.r(7.5 - width / 2, 15, width, 1)),
               with: .color(.black.opacity(opacity)))
    }

    private func drawLegs(_ c: GraphicsContext, v: V) {
        c.fill(Path(v.r(4.5, 12.2, 1.2, 1.6)), with: .color(Self.legC))
        c.fill(Path(v.r(10.3, 12.2, 1.2, 1.6)), with: .color(Self.legC))
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // SLEEP — hovering tile, the mark breathing via opacity
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    private var sleepScene: some View {
        ZStack {
            MascotTimeline(interval: 0.12) { t in
                sleepCanvas(t: t)
            }
            MascotTimeline(interval: 0.12) { t in
                floatingZs(t: t)
            }
        }
    }

    private func floatingZs(t: Double) -> some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                let ci = Double(i)
                let cycle = 2.9 + ci * 0.3
                let delay = ci * 0.9
                let phase = max(0, ((t - delay).truncatingRemainder(dividingBy: cycle)) / cycle)
                let fontSize = max(6, size * CGFloat(0.18 + phase * 0.10))
                let baseOpacity = 0.7 - ci * 0.1
                let opacity = phase < 0.8 ? baseOpacity : (1.0 - phase) * 3.5 * baseOpacity
                let wave = sin(phase * Double.pi * 2.0) * 0.03
                let xOff = size * CGFloat(0.08 + ci * 0.06 + wave)
                let yOff = -size * CGFloat(0.15 + phase * 0.38)
                Text("z")
                    .font(.system(size: fontSize, weight: .black, design: .monospaced))
                    .foregroundStyle(.white.opacity(opacity))
                    .offset(x: xOff, y: yOff)
            }
        }
    }

    private func sleepCanvas(t: Double) -> some View {
        // Two incommensurate sines — the hover never quite repeats (#15).
        let float = sin(t * 2 * .pi / 4.2) * 0.7 + sin(t * 2 * .pi / 6.6) * 0.35
        // Standby quirk: every ~8s the dotless i double-blinks its missing
        // tittle on — Pi briefly completes itself.
        let pulse = MascotMotion.quirk(t, cycle: 8.0, duration: 0.5, seed: 0x31415)
        let breathe = t.truncatingRemainder(dividingBy: 1.4) < 0.7
        let tittleOn = pulse > 0 && (pulse * 4).truncatingRemainder(dividingBy: 1) < 0.5

        return Canvas { c, sz in
            let v = V(sz)

            drawShadow(c, v: v, width: 9 + abs(float) * 0.3, opacity: 0.2)
            drawLegs(c, v: v)
            drawTile(c, v: v, dy: float)
            let breatheOp: Double = pulse > 0 ? 0.98 : (breathe ? 0.88 : 0.62)
            drawPi(c, v: v, dy: float, color: Self.piC.opacity(breatheOp), tittle: tittleOn)
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // WORK — bouncing tile typing on a keyboard, mark lit
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    private var workScene: some View {
        MascotTimeline(interval: 0.03) { t in
            workCanvas(t: t)
        }
    }

    private func workCanvas(t: Double) -> some View {
        // Compile-wait pause every ~12s — output scrolling (#15).
        let pause = MascotMotion.quirk(t, cycle: 12.0, duration: 1.2, seed: 0x31425)
        let intensity = 1.0 - Double(pause)
        let bounce = sin(t * 2 * .pi / 0.4) * 1.0 * intensity

        // The mark stays structurally complete at all times; the compile
        // pause dims the whole monogram instead of hiding pieces.

        // Key flash with humanized stroke cadence.
        let stroke = MascotMotion.typingStroke(t, cadence: 0.1, seed: 0x31435)
        let keyPhase = Int(MascotMotion.hash01(stroke.slot, seed: 0x31445) * 6)

        return Canvas { c, sz in
            let v = V(sz)
            let dy = bounce

            let shadowW: CGFloat = 8 - abs(dy) * 0.3
            c.fill(Path(v.r(4 + (8 - shadowW) / 2, 16, shadowW, 1)),
                   with: .color(.black.opacity(max(0.1, 0.35 - abs(dy) * 0.03))))

            // Keyboard
            c.fill(Path(v.r(0, 13, 15, 3)), with: .color(Self.kbBase))
            for row in 0..<2 {
                let ky = 13.5 + CGFloat(row) * 1.2
                for col in 0..<6 {
                    let kx = 0.5 + CGFloat(col) * 2.4
                    c.fill(Path(v.r(kx, ky, 1.8, 0.7)), with: .color(Self.kbKey))
                }
            }
            if stroke.active && pause < 0.3 {
                let flashRow = keyPhase / 3
                let flashCol = keyPhase % 6
                let fkx = 0.5 + CGFloat(flashCol) * 2.4
                let fky = 13.5 + CGFloat(flashRow) * 1.2
                c.fill(Path(v.r(fkx, fky, 1.8, 0.7)), with: .color(Self.kbHi.opacity(0.9)))
            }

            drawTile(c, v: v, dy: dy)
            let piOpacity: Double = pause > 0.3 ? 0.65 : 1.0
            drawPi(c, v: v, dy: dy, color: Self.piC.opacity(piOpacity))
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // ALERT — jump, shake, monogram flashing warm orange
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    private var alertScene: some View {
        ZStack {
            Circle()
                .fill(Self.alertC.opacity(alive ? 0.12 : 0))
                .frame(width: size * 0.8)
                .blur(radius: size * 0.05)
                .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: alive)

            MascotTimeline(interval: 0.03) { t in
                alertCanvas(t: t)
            }
        }
    }

    private func alertCanvas(t: Double) -> some View {
        let cycle = t.truncatingRemainder(dividingBy: 3.5)
        let pct = cycle / 3.5

        let jumpY = lerp([
            (0, 0), (0.03, 0), (0.10, -1), (0.15, 1.5),
            (0.175, -8), (0.20, -8), (0.25, 1.5),
            (0.275, -6), (0.30, -6), (0.35, 1.0),
            (0.375, -4), (0.40, -4), (0.45, 0.8),
            (0.475, -2), (0.50, -2), (0.55, 0.3),
            (0.62, 0), (1.0, 0),
        ], at: pct)

        let squashX: CGFloat = jumpY > 0.5 ? 1.0 + jumpY * 0.03 : 1.0
        let squashY: CGFloat = jumpY > 0.5 ? 1.0 - jumpY * 0.02 : 1.0
        let shakeX: CGFloat = (pct > 0.15 && pct < 0.55) ? sin(pct * 80) * 0.6 : 0
        let flash = (pct > 0.03 && pct < 0.55) ? sin(pct * 25) * 0.5 + 0.5 : 0.0
        let piColor = flash > 0.5 ? Self.alertC : Self.piC

        let bangOp = lerp([(0, 0), (0.03, 1), (0.10, 1), (0.55, 1), (0.62, 0), (1.0, 0)], at: pct)
        let bangScale = lerp([(0, 0.3), (0.03, 1.3), (0.10, 1.0), (0.55, 1.0), (0.62, 0.6), (1.0, 0.6)], at: pct)

        return Canvas { c, sz in
            let v = V(sz)

            let shadowW: CGFloat = 8 * (1.0 - abs(min(0, jumpY)) * 0.04)
            let shadowOp = max(0.08, 0.4 - abs(min(0, jumpY)) * 0.04)
            c.fill(Path(v.r(4 + (8 - shadowW) / 2, 16, shadowW, 1)),
                   with: .color(.black.opacity(shadowOp)))

            c.translateBy(x: shakeX * v.s, y: 0)
            drawTile(c, v: v, dy: jumpY, squashX: squashX, squashY: squashY)
            drawPi(c, v: v, dy: jumpY, color: piColor)
            c.translateBy(x: -shakeX * v.s, y: 0)

            if bangOp > 0.01 {
                let bw: CGFloat = 2 * bangScale
                let bx: CGFloat = 13
                let by: CGFloat = 4 + jumpY * 0.15
                c.fill(Path(v.r(bx, by, bw, 3.5 * bangScale, dy: 0)),
                       with: .color(Self.alertC.opacity(bangOp)))
                c.fill(Path(v.r(bx, by + 4.0 * bangScale, bw, 1.5 * bangScale, dy: 0)),
                       with: .color(Self.alertC.opacity(bangOp)))
            }
        }
    }
}
