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
    /// A line of the text (1-based) to select, for a reference; it wins
    /// over the declaration.
    var selectedLine: Int?
    var theme: CodeTheme
    var font: NSFont
    /// The file and line the text starts at, for Open in Editor.
    var firstLine: EditorTarget?
    /// Called when a reference is clicked; the flag is true for Command-click.
    var openReference: (WorkspaceLocation, Bool) -> Void
    var openInEditor: (EditorTarget) -> Void
    /// Called when a reference is double-clicked, which selects it.
    var linkDoubleClicked: () -> Void = {}
    /// Hover cards and Find References for identifiers.
    var tokenActions: SourceTokenActions?

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
            textView.tokenActions = tokenActions
            tokenActions?.register { [weak textView] in textView?.tokenAtInsertionPoint() }
        }

        let key = Coordinator.ContentKey(file: file, theme: theme.id, font: font)
        var keepScroll = false
        if key != coordinator.content {
            keepScroll = document != nil && document == coordinator.document && file != nil
            let origin = scrollView.contentView.bounds.origin
            coordinator.content = key
            coordinator.document = document
            coordinator.highlighted = nil
            let text = file.map { CodeText.attributed($0.source, theme: theme, font: font, markTokens: true) } ?? NSMutableAttributedString()
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

        let highlight: Coordinator.Highlight? = selectedLine.map { .line($0) } ?? highlightedDeclarationID.map { .declaration($0) }
        guard highlight != coordinator.highlighted else { return }
        coordinator.highlighted = highlight
        guard let file, let storage = textView.textStorage else { return }
        storage.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: storage.length))
        let nsRange: NSRange
        switch highlight {
        case let .declaration(id):
            guard let range = file.declarations.first(where: { $0.declarationID == id })?.range,
                  let r = CodeText.nsRange(range, in: file.source.text)
            else { return }
            nsRange = r
        case let .line(line):
            guard let r = Self.lineRange(line, in: storage.string) else { return }
            nsRange = r
        case nil:
            return
        }
        let color = NSColor.selectedTextBackgroundColor.withAlphaComponent(theme.isDark ? 0.35 : 0.25)
        storage.addAttribute(.backgroundColor, value: color, range: nsRange)
        if keepScroll { return }
        if case .line = highlight {
            DispatchQueue.main.async { Self.center(nsRange, in: textView) }
        } else {
            DispatchQueue.main.async {
                textView.scrollRangeToVisible(NSRange(location: nsRange.location, length: 0))
            }
        }
    }

    /// The range of a 1-based line in `text`, without its newline.
    static func lineRange(_ line: Int, in text: String) -> NSRange? {
        guard line >= 1 else { return nil }
        let ns = text as NSString
        var start = 0
        for _ in 1..<line {
            let newline = ns.range(of: "\n", range: NSRange(location: start, length: ns.length - start))
            if newline.location == NSNotFound { return nil }
            start = newline.location + 1
        }
        let rest = NSRange(location: start, length: ns.length - start)
        let newline = ns.range(of: "\n", range: rest)
        return NSRange(location: start, length: (newline.location == NSNotFound ? ns.length : newline.location) - start)
    }

    /// Scrolls so that `range` is in the middle of the visible text.
    private static func center(_ range: NSRange, in textView: NSTextView) {
        textView.scrollRangeToVisible(range)
        guard let window = textView.window, let clip = textView.enclosingScrollView?.contentView else { return }
        let screen = textView.firstRect(forCharacterRange: range, actualRange: nil)
        guard screen != .zero else { return }
        let rect = textView.convert(window.convertFromScreen(screen), from: nil)
        let y = max(0, min(rect.midY - clip.bounds.height / 2, textView.frame.height - clip.bounds.height))
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        textView.enclosingScrollView?.reflectScrolledClipView(clip)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        struct ContentKey: Equatable {
            var file: OcxFileSourceResponse?
            var theme: String
            var font: NSFont
        }

        enum Highlight: Equatable {
            case declaration(String)
            case line(Int)
        }

        var content: ContentKey?
        var document: String?
        var highlighted: Highlight?
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
    var tokenActions: SourceTokenActions?
    /// The identifier under the pointer, with its range.
    private var hovered: (token: SourceToken, range: NSRange)?
    private var hoverTracking: NSTrackingArea?

    override func mouseDown(with event: NSEvent) {
        endHover(dismiss: true)
        if event.clickCount >= 2, isOnLink(event) { linkDoubleClicked?() }
        super.mouseDown(with: event)
    }

    // MARK: Hover cards

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard let tokenActions, let found = token(at: event) else {
            endHover(dismiss: false)
            return
        }
        if let hovered, hovered.token === found.token { return }
        hovered = found
        let name = (string as NSString).substring(with: found.range)
        tokenActions.hover(found.token, name, firstRect(forCharacterRange: found.range, actualRange: nil), self)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        endHover(dismiss: false)
    }

    override func scrollWheel(with event: NSEvent) {
        endHover(dismiss: true)
        super.scrollWheel(with: event)
    }

    private func endHover(dismiss: Bool) {
        if let hovered {
            self.hovered = nil
            tokenActions?.endHover(hovered.token)
        }
        if dismiss { HoverCardPresenter.shared.dismiss() }
    }

    /// The identifier whose characters are under the pointer.
    private func token(at event: NSEvent) -> (token: SourceToken, range: NSRange)? {
        guard let storage = textStorage, let window else { return nil }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        let index = characterIndexForInsertion(at: convert(event.locationInWindow, from: nil))
        for i in [index - 1, index] where i >= 0 && i < storage.length {
            var range = NSRange()
            guard let token = storage.attribute(.sourceToken, at: i, effectiveRange: &range) as? SourceToken else { continue }
            if firstRect(forCharacterRange: NSRange(location: i, length: 1), actualRange: nil).contains(point) { return (token, range) }
        }
        return nil
    }

    /// The identifier at or just before the insertion point, with its
    /// name, while the text view has focus.
    func tokenAtInsertionPoint() -> (SourceToken, String)? {
        guard window?.firstResponder === self, let storage = textStorage else { return nil }
        let index = selectedRange().location
        for i in [index, index - 1] where i >= 0 && i < storage.length {
            var range = NSRange()
            if let token = storage.attribute(.sourceToken, at: i, effectiveRange: &range) as? SourceToken {
                return (token, (string as NSString).substring(with: range))
            }
        }
        return nil
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
        endHover(dismiss: true)
        if tokenActions != nil, let found = token(at: event) {
            let name = (string as NSString).substring(with: found.range)
            var items = [findItem("Find References to “\(name)”", found.token, name, .references)]
            if found.token.isCallable {
                items.append(findItem("Find Callers of “\(name)”", found.token, name, .callers))
                items.append(findItem("Find Callees of “\(name)”", found.token, name, .callees))
            }
            for (i, item) in items.enumerated() { menu.insertItem(item, at: i) }
            menu.insertItem(.separator(), at: items.count)
        }
        return menu
    }

    private final class FindRequest: NSObject {
        let token: SourceToken
        let name: String
        let tab: ReferencesTab
        init(_ token: SourceToken, _ name: String, _ tab: ReferencesTab) {
            self.token = token
            self.name = name
            self.tab = tab
        }
    }

    private func findItem(_ title: String, _ token: SourceToken, _ name: String, _ tab: ReferencesTab) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(findReferences(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = FindRequest(token, name, tab)
        return item
    }

    @objc private func findReferences(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? FindRequest else { return }
        tokenActions?.find(request.token, request.name, request.tab)
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

/// What the source viewer does with identifiers, supplied by the pane that
/// knows the file, package and session behind the text.
struct SourceTokenActions {
    /// The pointer rests on an identifier, `rect` on screen, in `view`.
    var hover: (SourceToken, _ name: String, _ rect: NSRect, _ view: NSView) -> Void
    var endHover: (SourceToken) -> Void
    var find: (SourceToken, _ name: String, ReferencesTab) -> Void
    /// Hands over a closure that returns the identifier at the insertion
    /// point, for Go ▸ Find References.
    var register: (@escaping () -> (SourceToken, String)?) -> Void
}
