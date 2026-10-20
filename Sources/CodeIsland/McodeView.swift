import SwiftUI

/// Mcode — MiniMax Code CLI mascot: the official MiniMax Agent icon
/// (CherryDev `packages/ui/icons/providers/light/minimax-agent.svg`)
/// with its blue background removed — a bold black outline with the original
/// diagonal top-left / bottom-right bevels, white window, and TWO black
/// bottom stems. The outline and window are always transformed together;
/// there are no additional eyes or detached parts.
struct McodeView: View {
    let status: MascotAgentStatus
    var size: CGFloat = 27
    @State private var alive = false

    // Official icon palette: black ink on white, brand blue glow.
    private static let ink     = Color(red: 26.0 / 255, green: 26.0 / 255, blue: 26.0 / 255) // #1A1A1A
    private static let face    = Color.white
    private static let brand   = Color(red: 0.494, green: 0.780, blue: 1.0) // #7EC7FF
    private static let alertC  = Color(red: 1.0, green: 107.0 / 255, blue: 31.0 / 255) // #FF6B1F
    private static let kbBase  = Color(red: 0.18, green: 0.18, blue: 0.20)
    private static let kbKey   = Color(red: 0.40, green: 0.40, blue: 0.42)
    private static let kbHi    = Color.white

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

    // ── 16×15 SVG coordinates; use the full viewBox, without a y offset ──
    private struct V {
        let ox: CGFloat, oy: CGFloat, s: CGFloat

        init(_ sz: CGSize, svgW: CGFloat = 16, svgH: CGFloat = 15) {
            s = min(sz.width / svgW, sz.height / svgH)
            ox = (sz.width - svgW * s) / 2
            oy = (sz.height - svgH * s) / 2
        }
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, dy: CGFloat = 0) -> CGRect {
            CGRect(x: ox + x * s, y: oy + (y + dy) * s, width: w * s, height: h * s)
        }
        func p(_ x: CGFloat, _ y: CGFloat, dy: CGFloat = 0) -> CGPoint {
            CGPoint(x: ox + x * s, y: oy + (y + dy) * s)
        }
        var unit: CGFloat { s }
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

    // ── Official MiniMax mascot geometry ──
    // The two filled paths below are traced directly from the approved
    // mcode-idle.svg, transformed to its native 16×15 coordinate system.
    // They contain exactly TWO bottom black stems and no additional eyes.
    // Drawing both paths with the SAME dy keeps the bevels, border thickness,
    // and bottom stems rigid and aligned during the animations.
    private func drawBody(_ c: GraphicsContext, v: V, dy: CGFloat,
                          ink: Color = McodeView.ink) {
        let outline = Path { path in
            path.move(to: v.p(12.9086, 2.5000, dy: dy))
            path.addCurve(to: v.p(13.6000, 3.1914, dy: dy),
                          control1: v.p(13.2904, 2.5000, dy: dy),
                          control2: v.p(13.6000, 2.8096, dy: dy))
            path.addLine(to: v.p(13.6000, 9.2019, dy: dy))
            path.addCurve(to: v.p(13.3291, 9.7730, dy: dy),
                          control1: v.p(13.6000, 9.4233, dy: dy),
                          control2: v.p(13.5005, 9.6329, dy: dy))
            path.addLine(to: v.p(11.2917, 11.4366, dy: dy))
            path.addCurve(to: v.p(10.8251, 11.6031, dy: dy),
                          control1: v.p(11.1600, 11.5441, dy: dy),
                          control2: v.p(10.9951, 11.6031, dy: dy))
            path.addLine(to: v.p(3.0914, 11.6031, dy: dy))
            path.addCurve(to: v.p(2.4000, 10.9117, dy: dy),
                          control1: v.p(2.7096, 11.6031, dy: dy),
                          control2: v.p(2.4001, 11.2935, dy: dy))
            path.addLine(to: v.p(2.4000, 5.0810, dy: dy))
            path.addCurve(to: v.p(2.6721, 4.5087, dy: dy),
                          control1: v.p(2.4000, 4.8591, dy: dy),
                          control2: v.p(2.5000, 4.6488, dy: dy))
            path.addLine(to: v.p(4.9390, 2.6652, dy: dy))
            path.addCurve(to: v.p(5.4044, 2.5000, dy: dy),
                          control1: v.p(5.0705, 2.5583, dy: dy),
                          control2: v.p(5.2349, 2.5000, dy: dy))
            path.addLine(to: v.p(12.9086, 2.5000, dy: dy))
            path.closeSubpath()
        }
        c.fill(outline, with: .color(ink))

        let window = Path { path in
            path.move(to: v.p(5.7525, 3.8799, dy: dy))
            path.addLine(to: v.p(11.9873, 3.8828, dy: dy))
            path.addCurve(to: v.p(12.2173, 4.1128, dy: dy),
                          control1: v.p(12.1143, 3.8830, dy: dy),
                          control2: v.p(12.2172, 3.9858, dy: dy))
            path.addLine(to: v.p(12.2173, 8.7196, dy: dy))
            path.addCurve(to: v.p(12.0812, 9.0057, dy: dy),
                          control1: v.p(12.2173, 8.8305, dy: dy),
                          control2: v.p(12.1673, 8.9357, dy: dy))
            path.addLine(to: v.p(10.6944, 10.1345, dy: dy))
            path.addCurve(to: v.p(10.4614, 10.2174, dy: dy),
                          control1: v.p(10.6286, 10.1880, dy: dy),
                          control2: v.p(10.5462, 10.2174, dy: dy))
            path.addLine(to: v.p(9.2217, 10.2174, dy: dy))
            path.addLine(to: v.p(9.2217, 7.8232, dy: dy))
            path.addCurve(to: v.p(8.8526, 7.4548, dy: dy),
                          control1: v.p(9.2215, 7.6197, dy: dy),
                          control2: v.p(9.0562, 7.4548, dy: dy))
            path.addLine(to: v.p(7.9773, 7.4548, dy: dy))
            path.addCurve(to: v.p(7.6083, 7.8232, dy: dy),
                          control1: v.p(7.7738, 7.4548, dy: dy),
                          control2: v.p(7.6084, 7.6197, dy: dy))
            path.addLine(to: v.p(7.6083, 10.2174, dy: dy))
            path.addLine(to: v.p(6.7785, 10.2174, dy: dy))
            path.addLine(to: v.p(6.7785, 7.8232, dy: dy))
            path.addCurve(to: v.p(6.4100, 7.4548, dy: dy),
                          control1: v.p(6.7783, 7.6197, dy: dy),
                          control2: v.p(6.6135, 7.4548, dy: dy))
            path.addLine(to: v.p(5.5341, 7.4548, dy: dy))
            path.addCurve(to: v.p(5.1656, 7.8232, dy: dy),
                          control1: v.p(5.3306, 7.4548, dy: dy),
                          control2: v.p(5.1658, 7.6197, dy: dy))
            path.addLine(to: v.p(5.1656, 10.2174, dy: dy))
            path.addLine(to: v.p(4.0240, 10.2174, dy: dy))
            path.addCurve(to: v.p(3.7933, 9.9867, dy: dy),
                          control1: v.p(3.8968, 10.2174, dy: dy),
                          control2: v.p(3.7934, 10.1140, dy: dy))
            path.addLine(to: v.p(3.7933, 5.5347, dy: dy))
            path.addCurve(to: v.p(3.9306, 5.2480, dy: dy),
                          control1: v.p(3.7933, 5.4234, dy: dy),
                          control2: v.p(3.8440, 5.3180, dy: dy))
            path.addLine(to: v.p(5.5207, 3.9616, dy: dy))
            path.addCurve(to: v.p(5.7525, 3.8799, dy: dy),
                          control1: v.p(5.5863, 3.9086, dy: dy),
                          control2: v.p(5.6681, 3.8799, dy: dy))
            path.closeSubpath()
        }
        c.fill(window, with: .color(Self.face))
    }

    private func drawShadow(_ c: GraphicsContext, v: V, width: CGFloat = 8, opacity: Double = 0.25) {
        c.fill(Path(ellipseIn: v.r(8 - width / 2, 13.7, width, 0.9)),
               with: .color(.black.opacity(opacity)))
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // SLEEP — hovering frame breathing via opacity, brand-blue glow
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    private var sleepScene: some View {
        ZStack {
            Circle()
                .fill(Self.brand.opacity(alive ? 0.16 : 0.06))
                .frame(width: size * 0.9)
                .blur(radius: size * 0.08)
                .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: alive)

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
                let xOff = size * CGFloat(0.16 + ci * 0.06 + wave)
                let yOff = -size * CGFloat(0.48 + phase * 0.30)
                Text("z")
                    .font(.system(size: fontSize, weight: .black, design: .monospaced))
                    .foregroundStyle(Self.ink.opacity(opacity))
                    .offset(x: xOff, y: yOff)
            }
        }
    }

    private func sleepCanvas(t: Double) -> some View {
        // Two incommensurate sines — the hover never quite repeats (#15).
        let float = sin(t * 2 * .pi / 4.2) * 0.7 + sin(t * 2 * .pi / 6.6) * 0.35
        let breathe = t.truncatingRemainder(dividingBy: 1.4) < 0.7

        return Canvas { c, sz in
            let v = V(sz)
            drawShadow(c, v: v, width: 8 + abs(float) * 0.3, opacity: 0.18)
            let breatheOp: Double = breathe ? 0.9 : 0.55
            drawBody(c, v: v, dy: float, ink: Self.ink.opacity(breatheOp))
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // WORK — bouncing frame typing on a keyboard
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    private var workScene: some View {
        MascotTimeline(interval: 0.03) { t in
            workCanvas(t: t)
        }
    }

    private func workCanvas(t: Double) -> some View {
        // Compile-wait pause every ~12s — output scrolling (#15).
        let pause = MascotMotion.quirk(t, cycle: 12.0, duration: 1.2, seed: 0x4D3A1)
        let intensity = 1.0 - Double(pause)
        // A vertical hop: rise, land, brief rest. X never changes, no tilt.
        // At 27pt the 1.25-grid-unit hop is ~2.1pt high.
        let hop = max(0, sin(t * 2 * .pi / 0.40)) * 1.25 * intensity

        // Key flash with humanized stroke cadence.
        let stroke = MascotMotion.typingStroke(t, cadence: 0.1, seed: 0x4D3B1)
        let keyPhase = min(11, Int(MascotMotion.hash01(stroke.slot, seed: 0x4D3C1) * 12))

        return Canvas { c, sz in
            let v = V(sz)
            // Negative dy is upward. No rotation, x-translation, or shear.
            let dy = -0.45 - hop

            let shadowW: CGFloat = 8 - hop * 0.6
            c.fill(Path(ellipseIn: v.r(8 - shadowW / 2, 13.7, shadowW, 0.9)),
                   with: .color(.black.opacity(max(0.10, 0.28 - hop * 0.07))))

            // Keyboard
            c.fill(Path(v.r(0.5, 12.9, 15, 2.6)), with: .color(Self.kbBase))
            for row in 0..<2 {
                let ky = 13.35 + CGFloat(row) * 1.1
                for col in 0..<6 {
                    let kx = 1.0 + CGFloat(col) * 2.35
                    c.fill(Path(v.r(kx, ky, 1.75, 0.65)), with: .color(Self.kbKey))
                }
            }
            if stroke.active && pause < 0.3 {
                let flashRow = keyPhase / 6
                let flashCol = keyPhase % 6
                let fkx = 1.0 + CGFloat(flashCol) * 2.35
                let fky = 13.35 + CGFloat(flashRow) * 1.1
                c.fill(Path(v.r(fkx, fky, 1.75, 0.65)), with: .color(Self.kbHi.opacity(0.9)))
            }

            let inkOp: Double = pause > 0.3 ? 0.6 : 1.0
            drawBody(c, v: v, dy: dy, ink: Self.ink.opacity(inkOp))
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // ALERT — jump, shake, mark flashing warm orange
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
            (0, 0), (0.03, 0), (0.10, -0.6), (0.15, 0.7),
            (0.175, -2.0), (0.20, -2.0), (0.25, 0.7),
            (0.275, -1.6), (0.30, -1.6), (0.35, 0.6),
            (0.375, -1.2), (0.40, -1.2), (0.45, 0.4),
            (0.475, -0.6), (0.50, -0.6), (0.55, 0.2),
            (0.62, 0), (1.0, 0),
        ], at: pct)

        let shakeX: CGFloat = (pct > 0.15 && pct < 0.55) ? sin(pct * 80) * 0.6 : 0
        let flash = (pct > 0.03 && pct < 0.55) ? sin(pct * 25) * 0.5 + 0.5 : 0.0
        let ink = flash > 0.5 ? Self.alertC : Self.ink

        let bangOp = lerp([(0, 0), (0.03, 1), (0.10, 1), (0.55, 1), (0.62, 0), (1.0, 0)], at: pct)
        let bangScale = lerp([(0, 0.3), (0.03, 1.3), (0.10, 1.0), (0.55, 1.0), (0.62, 0.6), (1.0, 0.6)], at: pct)

        return Canvas { c, sz in
            let v = V(sz)

            let shadowW: CGFloat = 8 * (1.0 - abs(min(0, jumpY)) * 0.04)
            let shadowOp = max(0.08, 0.3 - abs(min(0, jumpY)) * 0.03)
            c.fill(Path(ellipseIn: v.r(8 - shadowW / 2, 13.7, shadowW, 0.9)),
                   with: .color(.black.opacity(shadowOp)))

            // Match approved alert pose: a small -6.5° tilt and 0.97 scale.
            // Transform only the body, leaving the shadow and alert marker fixed.
            var mascot = c
            let pivot = v.p(8, 7.05, dy: jumpY)
            mascot.translateBy(x: pivot.x + shakeX * v.unit, y: pivot.y)
            mascot.rotate(by: .degrees(-6.5))
            mascot.scaleBy(x: 0.97, y: 0.97)
            mascot.translateBy(x: -pivot.x, y: -pivot.y)
            drawBody(mascot, v: v, dy: jumpY, ink: ink)

            if bangOp > 0.01 {
                let bw: CGFloat = 2 * bangScale
                let bx: CGFloat = 13
                let by: CGFloat = 4 + jumpY * 0.15
                c.fill(Path(v.r(bx, by, bw, 3.5 * bangScale)),
                       with: .color(Self.alertC.opacity(bangOp)))
                c.fill(Path(v.r(bx, by + 4.0 * bangScale, bw, 1.5 * bangScale)),
                       with: .color(Self.alertC.opacity(bangOp)))
            }
        }
    }
}
