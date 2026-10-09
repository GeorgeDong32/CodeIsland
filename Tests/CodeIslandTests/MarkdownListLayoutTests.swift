import AppKit
import SwiftUI
import XCTest
@testable import CodeIsland
import CodeIslandCore

@MainActor
final class MarkdownListLayoutTests: XCTestCase {
    private let settings = [
        SettingsKey.contentFontSize, SettingsKey.aiMessageLines, SettingsKey.maxVisibleSessions,
        SettingsKey.maxPanelHeight, SettingsKey.showUsageStats,
    ]
    private var savedSettings: [String: Any] = [:]
    private var savedPanelVisibility = true

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        for key in settings {
            savedSettings[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
        UserDefaults.standard.set(false, forKey: SettingsKey.showUsageStats)
        savedPanelVisibility = MascotAnimationGate.shared.isPanelVisible
        MascotAnimationGate.shared.setPanelVisible(false)
    }

    override func tearDown() {
        for key in settings {
            if let value = savedSettings[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        MascotAnimationGate.shared.setPanelVisible(savedPanelVisibility)
        super.tearDown()
    }

    func testNestedCompletionReplyDoesNotStallLayout() {
        // 363 items across five levels: recursive HStack flexibility probes
        // took over 20 seconds here, despite this being a small reply.
        let markdown = nestedList(depth: 5)
        let start = ProcessInfo.processInfo.systemUptime
        let view = HStack(alignment: .top, spacing: 4) {
            Text("$")
            AssistantReplyText(text: markdown, fontSize: 12, lineLimit: nil, isCompletionReply: true)
        }
        withHost(view, width: 560) { host in
            settle(host)
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        print("Nested completion reply layout: \(elapsed) seconds (363 items)")
        XCTAssertLessThan(elapsed, 5,
                          "nested completion replies must not block the main thread for seconds")
    }

    func testNestedReplyStaysResponsiveWhenOpeningAndUpdatingThePanel() {
        let markdown = nestedList(depth: 5)
        var session = SessionSnapshot()
        session.source = "claude"
        session.cwd = "/Users/dev/code/layout-test"
        session.status = .idle
        session.lastAssistantMessage = markdown
        session.addRecentMessage(ChatMessage(isUser: true, text: "Explain the changes"))
        session.addRecentMessage(ChatMessage(isUser: false, text: markdown))
        let state = AppState()
        state.sessions = ["layout-test": session]
        state.activeSessionId = "layout-test"
        state.surface = .collapsed
        let panel = NotchPanelView(appState: state, hasNotch: true, notchHeight: 32, notchW: 185, screenWidth: 1512)
            .environment(\.mascotStaticTime, 5.2)
        withHost(panel, width: 620) { host in
            settle(host)
            let opened = ProcessInfo.processInfo.systemUptime
            withAnimation(NotchAnimation.open) {
                state.surface = .completionCard(sessionId: "layout-test")
            }
            settle(host, passes: 6, interval: 0.1)
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - opened, 5, "opening the real card stalled")

            let updated = ProcessInfo.processInfo.systemUptime
            let reply = markdown.replacingOccurrences(of: "item", with: "updated item")
            session.lastAssistantMessage = reply
            session.recentMessages[1] = ChatMessage(isUser: false, text: reply)
            state.sessions["layout-test"] = session
            settle(host)
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - updated, 5, "updating the open card stalled")
        }
    }

    func testRowHasFiniteGeometryForMinimumIdealAndUnboundedProposals() {
        let marker = MarkdownListMarker(label: "10.", checkbox: .checked)
        let ideal = rowGeometry(proposal: .unspecified, marker: marker)
        for proposal in [ProposedViewSize.zero, .unspecified, .infinity,
                         ProposedViewSize(width: 1, height: 0), ProposedViewSize(width: 160, height: 30)] {
            let geometry = rowGeometry(proposal: proposal, marker: marker)
            for frame in [geometry.marker, geometry.content, geometry.row] {
                XCTAssertTrue(frame.origin.x.isFinite && frame.origin.y.isFinite)
                XCTAssertTrue(frame.width.isFinite && frame.height.isFinite)
                XCTAssertGreaterThanOrEqual(frame.width, 0)
                XCTAssertGreaterThan(frame.height, 0)
            }
            XCTAssertEqual(geometry.marker.size, ideal.marker.size, "markers must not wrap or shrink")
            XCTAssertEqual(geometry.marker.minY, geometry.content.minY, accuracy: 0.5)
            XCTAssertEqual(geometry.content.minX - geometry.marker.maxX, 5, accuracy: 0.5)
        }
        let unbounded = rowGeometry(proposal: .infinity, marker: marker)
        XCTAssertEqual(unbounded.row.size, ideal.row.size, "unbounded layout should use the natural content width")
    }

    func testBulletsOrderedAndTaskMarkersKeepStackGeometryAndNestedWrapping() {
        let markers = [
            MarkdownListMarker(label: "•", checkbox: nil),
            MarkdownListMarker(label: " 9.", checkbox: nil),
            MarkdownListMarker(label: "10.", checkbox: .checked),
            MarkdownListMarker(label: nil, checkbox: .unchecked),
        ]
        for marker in markers {
            var heights: [CGFloat] = []
            for width: CGFloat in [140, 420] {
                let proposal = ProposedViewSize(width: width, height: nil)
                let actual = rowGeometry(proposal: proposal, marker: marker)
                let previous = rowGeometry(proposal: proposal, marker: marker, usesStack: true)
                XCTAssertEqual(actual.row.width, previous.row.width, accuracy: 1)
                XCTAssertEqual(actual.row.height, previous.row.height, accuracy: 1)
                XCTAssertEqual(actual.content.width, previous.content.width, accuracy: 1)
                XCTAssertEqual(actual.content.height, previous.content.height, accuracy: 1)
                XCTAssertEqual(actual.content.minX - actual.marker.minX,
                               previous.content.minX - previous.marker.minX, accuracy: 0.5)
                heights.append(actual.content.height)
            }
            XCTAssertGreaterThan(heights[0], heights[1], "nested prose should wrap at narrow widths")
        }
    }

    func testShortRowsKeepIntrinsicWidthAndLeadingMarkerInBothLayoutDirections() {
        let marker = MarkdownListMarker(label: "10.", checkbox: .checked)
        for direction in [LayoutDirection.leftToRight, .rightToLeft] {
            let proposal = ProposedViewSize(width: 420, height: nil)
            let actual = rowGeometry(proposal: proposal, marker: marker, text: "Short", direction: direction)
            let previous = rowGeometry(
                proposal: proposal, marker: marker, usesStack: true, text: "Short", direction: direction
            )
            XCTAssertLessThan(actual.row.width, 420, "short rows must keep their intrinsic width")
            XCTAssertEqual(actual.row.width, previous.row.width, accuracy: 1)
            XCTAssertEqual(actual.row.height, previous.row.height, accuracy: 1)
            XCTAssertEqual(actual.content.minX - actual.marker.minX,
                           previous.content.minX - previous.marker.minX, accuracy: 0.5)
        }
    }

    private func rowGeometry(
        proposal: ProposedViewSize, marker: MarkdownListMarker, usesStack: Bool = false,
        text: String = "A paragraph with **bold**, `code`, and enough words to wrap.\n\n- A nested item that also wraps over several lines.",
        direction: LayoutDirection = .leftToRight
    ) -> RowGeometry {
        let geometry = RowGeometry()
        let layout = usesStack
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 5))
            : AnyLayout(MarkdownListRowLayout())
        let view = ProposalLayout(childProposal: proposal) {
            layout {
                MarkdownListMarkerView(marker: marker, fontSize: 12)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { geometry.marker = $0 }
                AssistantReplyText(
                    text: text,
                    fontSize: 12, lineLimit: nil
                )
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { geometry.content = $0 }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { geometry.row = $0 }
        }
        .environment(\.layoutDirection, direction)
        withHost(view, width: 800) { settle($0) }
        return geometry
    }

    private func nestedList(depth: Int, level: Int = 0) -> String {
        guard depth > 0 else { return "" }
        let indent = String(repeating: "  ", count: level)
        return (1...3).map { index in
            "\(indent)- item \(level).\(index) with **bold** and `code` and enough prose to wrap onto another line\n"
                + nestedList(depth: depth - 1, level: level + 1)
        }.joined()
    }

    private func withHost<V: View>(_ view: V, width: CGFloat, body: (NSView) -> Void) {
        let host = NSHostingView(rootView: view.frame(width: width, alignment: .leading))
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: width, height: 510)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil }
        body(host)
    }

    private func settle(_ host: NSView, passes: Int = 3, interval: TimeInterval = 0.01) {
        for _ in 0..<passes {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(interval))
        }
    }
}

private final class RowGeometry {
    var marker = CGRect.zero
    var content = CGRect.zero
    var row = CGRect.zero
}

/// A parent that exercises SwiftUI's real minimum/ideal/maximum proposals,
/// independent of the offscreen window's finite dimensions.
private struct ProposalLayout: Layout {
    let childProposal: ProposedViewSize

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews[0].sizeThatFits(childProposal)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: childProposal)
    }
}
