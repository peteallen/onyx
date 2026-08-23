import AppKit
import SwiftUI

struct NativeComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var measuredHeight: CGFloat
    let isEnabled: Bool
    /// Separating eligibility from the submit callback keeps an invalid Return
    /// key from stealing focus. This matters while a task is locked, while a
    /// side-chat fork is still being created, or when the composer is empty.
    var canSubmit: () -> Bool = { true }
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
        textView.canSubmit = canSubmit
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
        textView.canSubmit = canSubmit
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

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        guard let textView = coordinator.textView else { return }
        if textView.window?.firstResponder === textView {
            textView.window?.makeFirstResponder(nil)
        }
        textView.delegate = nil
        textView.canSubmit = { false }
        textView.onSubmit = nil
        textView.onPasteImages = nil
        coordinator.textView = nil
        scrollView.documentView = nil
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

/// Kept internal so the native paste path can be exercised without replacing
/// the user's process-wide clipboard in tests.
final class ComposerTextView: NSTextView {
    var canSubmit: () -> Bool = { true }
    var onSubmit: (() -> Void)?
    var onPasteImages: (([NSImage]) -> Void)?
    var pastedImagesProvider: () -> [NSImage]? = {
        ComposerPasteboardImages.images(from: .general)
    }
    var placeholder = "" {
        didSet { needsDisplay = true }
    }
    private var consumedSubmitKeyCodes = Set<UInt16>()
    private var hasPendingSubmit = false

    /// The placeholder follows TextKit's insertion geometry instead of using
    /// a separately tuned inset. That keeps the empty-field caret just before
    /// the first placeholder glyph, including when AppKit changes the default
    /// line-fragment padding.
    var placeholderOrigin: NSPoint {
        let containerOrigin = textContainerOrigin
        return NSPoint(
            x: containerOrigin.x + (textContainer?.lineFragmentPadding ?? 0),
            y: containerOrigin.y
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 14.5),
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        NSString(string: placeholder).draw(
            at: placeholderOrigin,
            withAttributes: attributes
        )
    }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn, !event.modifierFlags.contains(.shift) {
            // Do not dismiss the native editor for a request that the model
            // will reject. Keeping focus makes Return in an empty/locked
            // composer a no-op instead of a surprising focus jump.
            guard canSubmit() else {
                consumedSubmitKeyCodes.insert(event.keyCode)
                return
            }
            consumedSubmitKeyCodes.insert(event.keyCode)
            guard !hasPendingSubmit else { return }
            hasPendingSubmit = true
            // Submitting can immediately replace this representable with the
            // compact busy strip. If the text view remains first responder,
            // AppKit sends the matching key-up through a responder chain whose
            // SwiftUI hosting node has already been removed. On current macOS
            // that can crash in NSHostingView/ObservationTracking. End editing
            // while the native view is still mounted, then submit after this
            // key-down has completely unwound.
            let submit = onSubmit
            window?.makeFirstResponder(nil)
            DispatchQueue.main.async { [weak self] in
                self?.hasPendingSubmit = false
                submit?()
            }
            return
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if consumedSubmitKeyCodes.remove(event.keyCode) != nil {
            return
        }
        super.keyUp(with: event)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }
    override func paste(_ sender: Any?) {
        if let images = pastedImagesProvider(), !images.isEmpty {
            onPasteImages?(images)
            return
        }
        super.pasteAsPlainText(sender)
    }
}

/// Normalizes the image representations macOS applications commonly put on
/// the clipboard. `readObjects(forClasses: [NSImage.self])` alone misses
/// screenshots and browser images that expose only TIFF/PNG data or a file
/// URL, which made paste appear to do nothing even though the clipboard
/// visibly contained an image.
enum ComposerPasteboardImages {
    static func images(from pasteboard: NSPasteboard) -> [NSImage]? {
        if let images = pasteboard.readObjects(
            forClasses: [NSImage.self],
            options: nil
        ) as? [NSImage], !images.isEmpty {
            return images
        }

        if let fileURLs = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [NSURL] {
            let images = fileURLs
                .compactMap { value -> URL? in
                    guard value.isFileURL else { return nil }
                    return value as URL
                }
                .compactMap { NSImage(contentsOf: $0) }
            if !images.isEmpty { return images }
        }

        return images(from: pasteboard.pasteboardItems ?? [])
    }

    static func images(from items: [NSPasteboardItem]) -> [NSImage]? {
        let imageTypes: [NSPasteboard.PasteboardType] = [
            .png,
            .tiff,
            .init("public.jpeg"),
            .init("public.heic"),
            .init("org.webmproject.webp"),
        ]
        var images: [NSImage] = []
        for item in items {
            if let rawFileURL = item.string(forType: .fileURL),
               let url = URL(string: rawFileURL),
               url.isFileURL,
               let image = NSImage(contentsOf: url) {
                images.append(image)
                continue
            }
            for type in imageTypes where item.types.contains(type) {
                if let data = item.data(forType: type),
                   let image = NSImage(data: data) {
                    images.append(image)
                    break
                }
            }
        }
        return images.isEmpty ? nil : images
    }
}
