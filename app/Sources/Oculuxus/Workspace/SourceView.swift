import AppKit
import SwiftUI

/// Read-only source viewer backed by a TextKit 2 NSTextView. It shows one
/// file, highlights the selected declaration and scrolls to it.
struct SourceView: NSViewRepresentable {
    var file: OcxFileSourceResponse?
    /// Identifies what is shown. New text for the same document (after a
    /// reload) keeps the scroll position; another document starts at the top.
    var document: String?
    var highlightedDeclarationID: String?
    var theme: CodeTheme
    var font: NSFont
    /// The file and line the text starts at, for Open in Editor.
    var firstLine: EditorTarget?
    /// Called when a reference is clicked; the flag is true for Command-click.
    var openReference: (WorkspaceLocation, Bool) -> Void
    var openInEditor: (EditorTarget) -> Void
    /// Called when a reference is double-clicked, which selects it.
    var linkDoubleClicked: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = SourceTextView(usingTextLayoutManager: true)
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
        if let textView = textView as? SourceTextView {
            textView.firstLine = firstLine
            textView.openInEditor = openInEditor
            textView.linkDoubleClicked = linkDoubleClicked
        }

        let key = Coordinator.ContentKey(file: file, theme: theme.id, font: font)
        var keepScroll = false
        if key != coordinator.content {
            keepScroll = document != nil && document == coordinator.document && file != nil
            let origin = scrollView.contentView.bounds.origin
            coordinator.content = key
            coordinator.document = document
            coordinator.highlighted = nil
            let text = file.map { CodeText.attributed($0.source, theme: theme, font: font) } ?? NSMutableAttributedString()
            textView.textStorage?.setAttributedString(text)
            textView.backgroundColor = theme.background
            textView.insertionPointColor = theme.text
            scrollView.backgroundColor = theme.background
            if keepScroll {
                textView.layoutSubtreeIfNeeded()
                scrollView.contentView.scroll(to: origin)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            } else {
                textView.scroll(.zero)
            }
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
        if keepScroll { return }
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
        var document: String?
        var highlighted: String?
        var openReference: ((WorkspaceLocation, Bool) -> Void)?

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let url = link as? URL, let location = CodeText.location(from: url) else { return false }
            openReference?(location, ClickModifiers.opensNewWorkspace)
            return true
        }
    }
}

/// The source text view, with Open in Editor at the clicked line in its
/// context menu.
final class SourceTextView: NSTextView {
    var firstLine: EditorTarget?
    var openInEditor: ((EditorTarget) -> Void)?
    var linkDoubleClicked: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2, isOnLink(event) { linkDoubleClicked?() }
        super.mouseDown(with: event)
    }

    /// Whether the press is on a character of a reference.
    private func isOnLink(_ event: NSEvent) -> Bool {
        guard let storage = textStorage, let window else { return false }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        // The insertion point is on either side of the character pressed.
        for i in [index - 1, index] where i >= 0 && i < storage.length {
            guard storage.attribute(.link, at: i, effectiveRange: nil) != nil else { continue }
            if firstRect(forCharacterRange: NSRange(location: i, length: 1), actualRange: nil).contains(point) { return true }
        }
        return false
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard let firstLine else { return menu }
        let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        let target = Self.target(at: index, in: string, firstLine: firstLine)
        let item = NSMenuItem(title: "Open in Editor at Line \(target.line)", action: #selector(openClickedLine(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = target
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }

    @objc private func openClickedLine(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? EditorTarget else { return }
        openInEditor?(target)
    }

    /// The file line of the character at `index` (UTF-16) in `text`, which
    /// starts at `firstLine`.
    static func target(at index: Int, in text: String, firstLine: EditorTarget) -> EditorTarget {
        let ns = text as NSString
        let end = min(max(index, 0), ns.length)
        var newlines = 0
        var i = 0
        while i < end {
            let range = ns.range(of: "\n", range: NSRange(location: i, length: end - i))
            if range.location == NSNotFound { break }
            newlines += 1
            i = range.location + 1
        }
        return EditorTarget(file: firstLine.file, line: firstLine.line + newlines)
    }
}
