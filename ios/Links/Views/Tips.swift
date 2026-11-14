import SwiftUI
import TipKit

// Tips for the features that hide behind gestures (#10). They sit on the first row of To Watch,
// one at a time and in this order, and each goes away for good once it's closed or the gesture
// is used.

nonisolated struct ReactTip: Tip {
    var title: Text { Text("React to a Link") }
    var message: Text? { Text("Tap \(Image(systemName: "face.smiling")) to let them know what you thought.") }
}

nonisolated struct SwipeToWatchTip: Tip {
    var title: Text { Text("Swipe Right to Mark Watched") }
    var message: Text? { Text("Swipe left to share or delete.") }
}

nonisolated struct HoldForMoreTip: Tip {
    var title: Text { Text("Touch and Hold for More") }
    var message: Text? { Text("Add a note, pick a reaction, share or copy the link.") }
}

enum LinkTips {
    static let group = TipGroup(.ordered) {
        ReactTip()
        SwipeToWatchTip()
        HoldForMoreTip()
    }

    /// Call once at launch, before any tip is shown.
    static func configure() {
        if AppModel.resetsOnboarding { try? Tips.resetDatastore() }
        if AppModel.isUITesting { Tips.hideAllTipsForTesting() }
        try? Tips.configure([.displayFrequency(.immediate)])
    }
}

extension View {
    /// A gesture tip as a popover below this view, clear of the title above the first row.
    func gestureTip(_ tip: (any Tip)?) -> some View {
        modifier(GestureTipPopover(tip: tip))
    }
}

private struct GestureTipPopover: ViewModifier {
    let tip: (any Tip)?

    func body(content: Content) -> some View {
        // Both name the tip's edge that carries the arrow. iOS 26 and later ignore arrowEdge
        // (the tip landed beside or above the row), hence arrowEdges there.
        if #available(iOS 26, *) {
            content.popoverTip(tip, arrowEdges: .top)
        } else {
            content.popoverTip(tip, arrowEdge: .top)
        }
    }
}

extension EnvironmentValues {
    /// The link whose row carries the gesture tips: the first in To Watch.
    @Entry var gestureTipsLinkID: Int? = nil
}
