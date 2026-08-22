import AppKit
import SwiftUI

struct NativeComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var measuredHeight: CGFloat
    let isEnabled: Bool
    let onSubmit: () -> Void
    let onPasteImages: ([NSImage]) -> Void

    private static let placeholder = "Describe what you want to build or change"

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder

        let textView = ComposerTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.onSubmit = onSubmit
        textView.onPasteImages = onPasteImages
        textView.placeholder = Self.placeholder
        textView.setAccessibilityPlaceholderValue(Self.placeholder)
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 2, height: 7)
        textView.font = .systemFont(ofSize: 14.5)
        textView.textColor = .labelColor
        textView.insertionPointColor = .controlAccentColor
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.isEditable = isEnabled
        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        context.coordinator.parent = self
        textView.onSubmit = onSubmit
        textView.onPasteImages = onPasteImages
        textView.placeholder = Self.placeholder
        textView.isEditable = isEnabled
        if textView.string != text {
            textView.string = text
            textView.needsDisplay = true
            context.coordinator.updateHeight()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeComposerTextView
        fileprivate weak var textView: ComposerTextView?

        init(parent: NativeComposerTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            updateHeight()
        }

        func updateHeight() {
            guard let textView, let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            layoutManager.ensureLayout(for: textContainer)
            let contentHeight = ceil(layoutManager.usedRect(for: textContainer).height) + 18
            let newHeight = min(200, max(42, contentHeight))
            guard abs(parent.measuredHeight - newHeight) > 1 else { return }
            DispatchQueue.main.async { [weak self] in
                self?.parent.measuredHeight = newHeight
            }
        }
    }
}

fileprivate final class ComposerTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onPasteImages: (([NSImage]) -> Void)?
    var placeholder = "" {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 14.5),
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        NSString(string: placeholder).draw(
            at: NSPoint(x: textContainerInset.width + 1, y: textContainerInset.height),
            withAttributes: attributes
        )
    }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, !event.modifierFlags.contains(.shift) {
            onSubmit?()
            return
        }
        super.keyDown(with: event)
    }


    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }
    override func paste(_ sender: Any?) {
        if let images = NSPasteboard.general.readObjects(
            forClasses: [NSImage.self],
            options: nil
        ) as? [NSImage], !images.isEmpty {
            onPasteImages?(images)
            return
        }
        super.pasteAsPlainText(sender)
    }
}
