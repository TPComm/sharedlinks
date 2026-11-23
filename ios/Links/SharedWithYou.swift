import SharedWithYou
import SwiftUI

@MainActor @Observable
final class SharedHighlights: NSObject, SWHighlightCenterDelegate {
    @ObservationIgnored private(set) lazy var center: SWHighlightCenter = {
        let center = SWHighlightCenter()
        center.delegate = self
        return center
    }()
    private(set) var revision = 0

    nonisolated func highlightCenterHighlightsDidChange(_ highlightCenter: SWHighlightCenter) {
        Task { @MainActor in revision += 1 }
    }
}

struct SharedAttributionView: UIViewRepresentable {
    let highlight: SWHighlight

    func makeUIView(context: Context) -> SWAttributionView {
        let view = SWAttributionView()
        view.displayContext = .detail
        view.horizontalAlignment = .leading
        view.accessibilityIdentifier = "linkPage.attribution"
        return view
    }

    func updateUIView(_ view: SWAttributionView, context: Context) {
        view.highlight = highlight
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: SWAttributionView, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        uiView.preferredMaxLayoutWidth = width
        return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }
}
