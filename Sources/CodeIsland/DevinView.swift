import SwiftUI

/// Devin — Cognition mascot, pixel-art deep-navy tile with a mint
/// terminal-chevron face (`›_`). The Devin CLI brand reads dark-terminal
/// with a mint/teal accent; no official mark asset ships with the CLI, so
/// this is a brand-toned original in the island's pixel style.
struct DevinView: View {
    let status: MascotAgentStatus
    var size: CGFloat = 27
    @State private var alive = false

    private static let tileC    = Color(red: 0.08, green: 0.13, blue: 0.19)   // deep navy
    private static let tileEdge = Color(red: 0.22, green: 0.30, blue: 0.40)
    private static let faceC    = Color(red: 0.50, green: 0.90, blue: 0.77)   // mint
    private static let legC     = Color(red: 0.25, green: 0.32, blue: 0.40)
    private static let alertC   = Color(red: 1.0, green: 0.55, blue: 0.0)
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

        init(_ sz: CGSize, svgW: CGFloat = 15, svgH: CGFloat = 10, svgY0: CGFloat = 6) {
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

    // ── Tile body: rounded navy square ──
    private func drawTile(_ c: GraphicsContext, v: V, dy: CGFloat,
                          squashX: CGFloat = 1, squashY: CGFloat = 1) {
        let x: CGFloat = 2, y: CGFloat = 3.5, w: CGFloat = 12, h: CGFloat = 8.5
        let cx = x + w / 2, cy = y + h / 2
        let rx = cx + (x - cx) * squashX
        let rw = w * squashX
        let ry = cy + (y - cy) * squashY
        let rh = h * squashY
        let rows: [(CGFloat, CGFloat, CGFloat)] = [
            (ry + 1, rx + 0.5, rw - 1),
            (ry, rx, rw),
            (ry, rx, rw),
            (ry, rx, rw),
            (ry, rx, rw),
            (ry, rx, rw),
            (ry, rx, rw),
            (ry + rh - 1, rx + 0.5, rw - 1),
        ]
        let step = rh / 8
        for (i, row) in rows.enumerated() {
            c.fill(Path(v.r(row.1, row.0 + CGFloat(i) * step, row.2, step + 0.02, dy: dy)),
                   with: .color(Self.tileC))
        }
        c.fill(Path(v.r(rx + 0.5, ry + 1, rw - 1, 0.5, dy: dy)),
               with: .color(Self.tileEdge.opacity(0.8)))
    }

    // ── Mint terminal face: `›` chevron + `_` cursor. The cursor doubles as
    // the blink element; `chevron` can be dropped for a closed-eye sleep. ──
    private func drawFace(_ c: GraphicsContext, v: V, dy: CGFloat,
                          color: Color = DevinView.faceC,
                          chevron: Bool = true, cursorOn: Bool = true) {
        if chevron {
            // `›` — bold stacked steps, centered on the tile.
            c.fill(Path(v.r(3.6, 5.0, 2.0, 1.3, dy: dy)), with: .color(color))
            c.fill(Path(v.r(5.6, 6.6, 2.0, 1.3, dy: dy)), with: .color(color))
            c.fill(Path(v.r(3.6, 8.2, 2.0, 1.3, dy: dy)), with: .color(color))
        }
        if cursorOn {
            c.fill(Path(v.r(8.6, 10.0, 3.6, 1.4, dy: dy)), with: .color(color))
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
    // SLEEP — hover, dim cursor breathing
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
                let cycle = 2.8 + ci * 0.3
                let delay = ci * 0.9
                let phase = max(0, ((t - delay).truncatingRemainder(dividingBy: cycle)) / cycle)
                let fontSize = max(6, size * CGFloat(0.18 + phase * 0.10))
                let baseOpacity = 0.7 - ci * 0.1
                let opacity = phase < 0.8 ? baseOpacity : (1.0 - phase) * 3.5 * baseOpacity
                let wave = sin(phase * Double.pi * 2.0) * 0.03
                let xOffsetRatio = 0.08 + ci * 0.06 + wave
                let xOff = size * CGFloat(xOffsetRatio)
                let yOff = -size * CGFloat(0.15 + phase * 0.38)
                Text("z")
                    .font(.system(size: fontSize, weight: .black, design: .monospaced))
                    .foregroundStyle(Self.faceC.opacity(opacity))
                    .offset(x: xOff, y: yOff)
            }
        }
    }

    private func sleepCanvas(t: Double) -> some View {
        let float = sin(t * 2 * .pi / 4.0) * 0.7 + sin(t * 2 * .pi / 6.3) * 0.35
        let pulse = MascotMotion.quirk(t, cycle: 8.0, duration: 0.5, seed: 0x0DE7)
        let cursorPhase = t.truncatingRemainder(dividingBy: 1.2)
        let cursorOn = pulse > 0 ? (pulse * 4).truncatingRemainder(dividingBy: 1) < 0.5 : cursorPhase < 0.6

        return Canvas { c, sz in
            let v = V(sz, svgW: 16, svgH: 14, svgY0: 3)

            drawShadow(c, v: v, width: 9 + abs(float) * 0.3, opacity: 0.2)
            drawLegs(c, v: v)
            drawTile(c, v: v, dy: float)
            // Sleep: full face breathing; the pulse briefly lifts to full mint.
            let breatheOp: Double = pulse > 0 ? 0.95 : (cursorOn ? 0.8 : 0.55)
            drawFace(c, v: v, dy: float, color: Self.faceC.opacity(breatheOp),
                     cursorOn: cursorOn || pulse > 0)
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // WORK — bounce + keyboard typing
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    private var workScene: some View {
        MascotTimeline(interval: 0.03) { t in
            workCanvas(t: t)
        }
    }

    private func workCanvas(t: Double) -> some View {
        let pause = MascotMotion.quirk(t, cycle: 12.0, duration: 1.2, seed: 0x0DE8)
        let intensity = 1.0 - Double(pause)
        let bounce = sin(t * 2 * .pi / 0.4) * 1.0 * intensity

        let cursorPhase = t.truncatingRemainder(dividingBy: 0.3)
        let cursorOn = pause > 0.3 ? true : cursorPhase < 0.15

        let stroke = MascotMotion.typingStroke(t, cadence: 0.1, seed: 0x0DE9)
        let keyPhase = Int(MascotMotion.hash01(stroke.slot, seed: 0x0DEA) * 6)

        return Canvas { c, sz in
            let v = V(sz, svgW: 16, svgH: 14, svgY0: 3)
            let dy = bounce

            let shadowW: CGFloat = 8 - abs(dy) * 0.3
            c.fill(Path(v.r(4 + (8 - shadowW) / 2, 16, shadowW, 1)),
                   with: .color(.black.opacity(max(0.1, 0.35 - abs(dy) * 0.03))))

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
            drawFace(c, v: v, dy: dy, cursorOn: cursorOn)
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // ALERT — jump, shake, mint face flashing amber
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
        let faceColor = flash > 0.5 ? Self.alertC : Self.faceC

        let bangOp = lerp([(0, 0), (0.03, 1), (0.10, 1), (0.55, 1), (0.62, 0), (1.0, 0)], at: pct)
        let bangScale = lerp([(0, 0.3), (0.03, 1.3), (0.10, 1.0), (0.55, 1.0), (0.62, 0.6), (1.0, 0.6)], at: pct)

        return Canvas { c, sz in
            let v = V(sz, svgW: 16, svgH: 14, svgY0: 3)

            let shadowW: CGFloat = 8 * (1.0 - abs(min(0, jumpY)) * 0.04)
            let shadowOp = max(0.08, 0.4 - abs(min(0, jumpY)) * 0.04)
            c.fill(Path(v.r(4 + (8 - shadowW) / 2, 16, shadowW, 1)),
                   with: .color(.black.opacity(shadowOp)))

            c.translateBy(x: shakeX * v.s, y: 0)
            drawTile(c, v: v, dy: jumpY, squashX: squashX, squashY: squashY)
            drawFace(c, v: v, dy: jumpY, color: faceColor)
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
