import Combine
import Foundation

/// Window-local editing state for the primary task composer.
///
/// The composer is intentionally a separate observable object from
/// `OnyxAppModel`.  A native text view publishes on every keystroke; keeping
/// that publication on this small object means the sidebar, transcript, and
/// inspector do not all re-evaluate while somebody is typing.  The owning app
/// model still supplies the compatibility accessors and persistence callback,
/// so navigation and send/recovery code keep one source of truth.
@MainActor
final class OnyxComposerDraftModel: ObservableObject {
    @Published var text: String {
        didSet { onTextChanged?(text) }
    }

    @Published var images: [ComposerImageDraft]

    /// A request is an identity token rather than a counter.  Counters can
    /// collide when SwiftUI replaces a provider-bound model whose native
    /// editor coordinator has already consumed the same initial value.
    @Published private(set) var focusRequest: UUID?

    /// Set by `OnyxAppModel` after initialization.  The callback is deliberately
    /// weakly captured there so this child never retains its owner.
    var onTextChanged: ((String) -> Void)?

    init(
        text: String = "",
        images: [ComposerImageDraft] = [],
        focusRequest: UUID? = nil
    ) {
        self.text = text
        self.images = images
        self.focusRequest = focusRequest
    }

    func requestFocus() {
        focusRequest = UUID()
    }
}
