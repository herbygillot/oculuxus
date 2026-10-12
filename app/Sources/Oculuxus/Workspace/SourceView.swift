import AppKit
import SwiftUI

/// Read-only source viewer backed by a TextKit 2 NSTextView. It shows one
/// file, highlights the selected declaration and scrolls to it.
struct SourceView: NSViewRepresentable {
    var file: OcxFileSourceResponse?
    var highlightedDeclarationID: String?
    var theme: CodeTheme
    var font: NSFont
    /// Called when a reference is clicked; the flag is true for Command-click.
    var openReference: (WorkspaceLocation, Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        // Long lines scroll instead of wrapping, as in an editor.
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        textView.delegate = context.coordinator

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let coordinator = context.coordinator
        coordinator.openReference = openReference

        let key = Coordinator.ContentKey(file: file, theme: theme.id, font: font)
        if key != coordinator.content {
            coordinator.content = key
            coordinator.highlighted = nil
            let text = file.map { CodeText.attributed($0.source, theme: theme, font: font) } ?? NSMutableAttributedString()
            textView.textStorage?.setAttributedString(text)
            textView.backgroundColor = theme.background
            textView.insertionPointColor = theme.text
            scrollView.backgroundColor = theme.background
            textView.scroll(.zero)
        }

        guard highlightedDeclarationID != coordinator.highlighted else { return }
        coordinator.highlighted = highlightedDeclarationID
        guard let file, let storage = textView.textStorage else { return }
        storage.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: storage.length))
        guard let id = highlightedDeclarationID,
              let range = file.declarations.first(where: { $0.declarationID == id })?.range,
              let nsRange = CodeText.nsRange(range, in: file.source.text)
        else { return }
        let highlight = NSColor.selectedTextBackgroundColor.withAlphaComponent(theme.isDark ? 0.35 : 0.25)
        storage.addAttribute(.backgroundColor, value: highlight, range: nsRange)
        DispatchQueue.main.async {
            textView.scrollRangeToVisible(NSRange(location: nsRange.location, length: 0))
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        struct ContentKey: Equatable {
            var file: OcxFileSourceResponse?
            var theme: String
            var font: NSFont
        }

        var content: ContentKey?
        var highlighted: String?
        var openReference: ((WorkspaceLocation, Bool) -> Void)?

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL, let location = CodeText.location(from: url) else { return false }
            openReference?(location, ClickModifiers.opensNewWorkspace)
            return true
        }
    }
}
