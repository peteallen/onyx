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
        context.coordinator.textView = textView
        textView.onTextContainerWidthChange = { [weak coordinator = context.coordinator] in
            coordinator?.updateHeight()
        }
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
        textView.font = .systemFont(ofSize: OnyxTypography.reading)
        textView.textColor = .labelColor
        textView.insertionPointColor = .controlAccentColor
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        // Keep the editor itself pane-wide so its complete visible surface is
        // easy to click, while capping only the line measure inside it.
        textView.maximumTextContainerWidth = OnyxWorkspaceMetrics.maximumConversationTextWidth
        textView.isEditable = isEnabled
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        context.coordinator.parent = self
        textView.canSubmit = canSubmit
        textView.onSubmit = onSubmit
        textView.onPasteImages = onPasteImages
        textView.placeholder = Self.placeholder
        textView.maximumTextContainerWidth = OnyxWorkspaceMetrics.maximumConversationTextWidth
        textView.isEditable = isEnabled
        if textView.string != text {
            textView.string = text
            textView.needsDisplay = true
            context.coordinator.updateHeight()
        }
        // A successful Return submission deliberately ends native editing
        // before it calls into SwiftUI. If this same editor survives the
        // resulting state update, give it the caret back now that SwiftUI has
        // confirmed it is still present and enabled.
        textView.restoreFocusAfterSubmitIfAvailable()
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
        textView.onTextContainerWidthChange = nil
        textView.cancelFocusRestorationAfterSubmit()
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
    /// Limits line length without shrinking the NSTextView hit surface. A
    /// narrow editor continues to use every available point; only unusually
    /// wide panes leave quiet space after the readable text container.
    var maximumTextContainerWidth: CGFloat? {
        didSet { updateTextContainerWidth() }
    }
    var onTextContainerWidthChange: (() -> Void)?
    private var consumedSubmitKeyCodes = Set<UInt16>()
    private var hasPendingSubmit = false
    private var pendingSubmitKeyCode: UInt16?
    private var submitCallbackCompleted = false
    private var submitKeyWasReleased = false
    private var focusRestorationScheduled = false
    private var submitKeyUpMonitor: Any?

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateTextContainerWidth()
    }

    private func updateTextContainerWidth() {
        guard let maximumTextContainerWidth,
              maximumTextContainerWidth.isFinite,
              maximumTextContainerWidth > 0,
              let textContainer else { return }
        let availableWidth = max(1, bounds.width - textContainerInset.width * 2)
        let resolvedWidth = min(maximumTextContainerWidth, availableWidth)
        let widthChanged = abs(textContainer.containerSize.width - resolvedWidth) > 0.5
            || textContainer.widthTracksTextView
        guard widthChanged else { return }

        textContainer.widthTracksTextView = false
        textContainer.containerSize = NSSize(
            width: resolvedWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
        onTextContainerWidthChange?()
    }

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
            .font: font ?? NSFont.systemFont(ofSize: OnyxTypography.reading),
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
            let submitKeyCode = event.keyCode
            beginSubmitKeySequence(keyCode: submitKeyCode)
            // Submitting can immediately replace this representable with the
            // compact busy strip. If the text view remains first responder,
            // AppKit sends the matching key-up through a responder chain whose
            // SwiftUI hosting node has already been removed. On current macOS
            // that can crash in NSHostingView/ObservationTracking. End editing
            // while the native view is still mounted, then submit after this
            // key-down has completely unwound. The following SwiftUI update
            // either dismantles this editor or restores its focus if the
            // composer remains available.
            let submit = onSubmit
            window?.makeFirstResponder(nil)
            DispatchQueue.main.async { [weak self] in
                self?.hasPendingSubmit = false
                submit?()
                self?.completeSubmitCallback(for: submitKeyCode)
            }
            return
        }
        super.keyDown(with: event)
    }

    private func beginSubmitKeySequence(keyCode: UInt16) {
        cancelFocusRestorationAfterSubmit()
        pendingSubmitKeyCode = keyCode
        submitKeyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) {
            [weak self] event in
            self?.observeSubmitKeyUp(keyCode: event.keyCode)
            return event
        }
    }

    private func completeSubmitCallback(for keyCode: UInt16) {
        guard pendingSubmitKeyCode == keyCode else { return }
        // If submission explicitly focused another control, that choice wins
        // even if the control later resigns before the Return key is released.
        if let window,
           window.firstResponder != nil,
           window.firstResponder !== window,
           window.firstResponder !== self {
            cancelFocusRestorationAfterSubmit()
            return
        }
        submitCallbackCompleted = true
        scheduleFocusRestorationIfSafe()
    }

    private func observeSubmitKeyUp(keyCode: UInt16) {
        guard pendingSubmitKeyCode == keyCode else { return }
        submitKeyWasReleased = true
        consumedSubmitKeyCodes.remove(keyCode)
        removeSubmitKeyUpMonitor()
        scheduleFocusRestorationIfSafe()
    }

    private func scheduleFocusRestorationIfSafe() {
        guard submitCallbackCompleted,
              submitKeyWasReleased,
              !focusRestorationScheduled else { return }
        focusRestorationScheduled = true
        // A local event monitor runs before AppKit dispatches key-up. Wait for
        // that dispatch to unwind before putting the editor back into the
        // responder chain.
        DispatchQueue.main.async { [weak self] in
            self?.restoreFocusAfterSubmitIfAvailable()
        }
    }

    /// Restores the caret only when submission left this exact editor mounted
    /// and available. If another control acquired focus while the submission
    /// unwound, that explicit focus change wins.
    func restoreFocusAfterSubmitIfAvailable() {
        guard pendingSubmitKeyCode != nil,
              submitCallbackCompleted,
              submitKeyWasReleased else { return }
        guard let window, isEditable else {
            cancelFocusRestorationAfterSubmit()
            return
        }
        guard window.firstResponder == nil || window.firstResponder === window else {
            cancelFocusRestorationAfterSubmit()
            return
        }

        cancelFocusRestorationAfterSubmit()
        window.makeFirstResponder(self)
    }

    func cancelFocusRestorationAfterSubmit() {
        pendingSubmitKeyCode = nil
        submitCallbackCompleted = false
        submitKeyWasReleased = false
        focusRestorationScheduled = false
        removeSubmitKeyUpMonitor()
    }

    private func removeSubmitKeyUpMonitor() {
        guard let submitKeyUpMonitor else { return }
        NSEvent.removeMonitor(submitKeyUpMonitor)
        self.submitKeyUpMonitor = nil
    }

    override func keyUp(with event: NSEvent) {
        if consumedSubmitKeyCodes.remove(event.keyCode) != nil {
            observeSubmitKeyUp(keyCode: event.keyCode)
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
