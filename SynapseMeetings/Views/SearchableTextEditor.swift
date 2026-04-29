import SwiftUI
import AppKit

struct FindState: Equatable {
    var isVisible: Bool = false
    var showReplace: Bool = false
    var query: String = ""
    var replacement: String = ""
    var matches: [NSRange] = []
    var currentIndex: Int = 0
    /// Which field should grab focus when the bar appears.
    var focusTarget: FocusTarget = .find
    /// Bumped to request focus.
    var focusRequest: Int = 0
    /// Bumped to request "next match" navigation.
    var nextRequest: Int = 0
    /// Bumped to request "previous match" navigation.
    var prevRequest: Int = 0
    /// Bumped to replace the current match.
    var replaceRequest: Int = 0
    /// Bumped to replace all matches.
    var replaceAllRequest: Int = 0

    enum FocusTarget: Equatable { case find, replace }

    mutating func reset() {
        isVisible = false
        showReplace = false
        query = ""
        replacement = ""
        matches = []
        currentIndex = 0
    }

    /// Recomputes `matches` for `query` against `text`. Resets `currentIndex` to
    /// the first match at/after `caret` if provided, otherwise to 0.
    mutating func recompute(in text: String, caret: Int? = nil) {
        guard !query.isEmpty else {
            matches = []
            currentIndex = 0
            return
        }
        let haystack = text as NSString
        var ranges: [NSRange] = []
        var searchRange = NSRange(location: 0, length: haystack.length)
        while searchRange.location < haystack.length {
            let r = haystack.range(of: query, options: [.caseInsensitive], range: searchRange)
            if r.location == NSNotFound { break }
            ranges.append(r)
            let nextLoc = r.location + max(r.length, 1)
            searchRange = NSRange(location: nextLoc, length: max(0, haystack.length - nextLoc))
        }
        matches = ranges
        if let caret, let firstAfter = ranges.firstIndex(where: { $0.location >= caret }) {
            currentIndex = firstAfter
        } else {
            currentIndex = 0
        }
    }
}

struct FindBar: View {
    @Binding var state: FindState
    @FocusState private var focusedField: FindState.FocusTarget?

    var body: some View {
        VStack(spacing: 4) {
            findRow
            if state.showReplace {
                replaceRow
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .onAppear { focusedField = state.focusTarget }
        .onChange(of: state.focusRequest) { _, _ in focusedField = state.focusTarget }
    }

    private var findRow: some View {
        HStack(spacing: 8) {
            Button {
                state.showReplace.toggle()
                if state.showReplace {
                    state.focusTarget = .replace
                    state.focusRequest &+= 1
                }
            } label: {
                Image(systemName: state.showReplace ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
            }
            .buttonStyle(.borderless)
            .help(state.showReplace ? "Hide replace" : "Show replace")

            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            TextField("Find", text: $state.query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($focusedField, equals: .find)
                .onSubmit { state.nextRequest &+= 1 }

            Text(matchLabel)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Button { state.prevRequest &+= 1 } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .disabled(state.matches.isEmpty)
            .help("Previous match (⇧⌘G)")

            Button { state.nextRequest &+= 1 } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .disabled(state.matches.isEmpty)
            .help("Next match (⌘G)")

            Button {
                state.isVisible = false
                state.showReplace = false
                state.query = ""
                state.replacement = ""
                state.matches = []
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("Close (Esc)")
        }
    }

    private var replaceRow: some View {
        HStack(spacing: 8) {
            // Indent to visually align with the Find text field above.
            Color.clear.frame(width: 10, height: 1)

            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            TextField("Replace with", text: $state.replacement)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($focusedField, equals: .replace)
                .onSubmit { state.replaceRequest &+= 1 }

            Button("Replace") { state.replaceRequest &+= 1 }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(state.matches.isEmpty)
                .help("Replace current match (↵)")

            Button("Replace All") { state.replaceAllRequest &+= 1 }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(state.matches.isEmpty)
                .help("Replace all matches")
        }
    }

    private var matchLabel: String {
        if state.query.isEmpty { return "" }
        if state.matches.isEmpty { return "No results" }
        return "\(state.currentIndex + 1) of \(state.matches.count)"
    }
}

struct SearchableTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var findState: FindState

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        let contentSize = scroll.contentSize
        let layout = NSTextContainer(size: NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude))
        layout.widthTracksTextView = true
        let manager = NSLayoutManager()
        let storage = NSTextStorage()
        storage.addLayoutManager(manager)
        manager.addTextContainer(layout)

        let tv = InterceptingTextView(frame: .zero, textContainer: layout)
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]

        let coordinator = context.coordinator
        coordinator.textView = tv
        tv.coordinator = coordinator

        tv.delegate = coordinator
        tv.isRichText = false
        tv.isEditable = true
        tv.isSelectable = true
        tv.allowsUndo = true
        tv.usesFontPanel = false
        tv.usesFindBar = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        tv.textContainerInset = NSSize(width: 0, height: 4)
        tv.drawsBackground = false
        tv.string = text

        scroll.documentView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        let coordinator = context.coordinator
        coordinator.parent = self

        if tv.string != text {
            let selected = tv.selectedRange()
            tv.string = text
            tv.setSelectedRange(NSRange(location: min(selected.location, (text as NSString).length), length: 0))
        }

        coordinator.applyHighlights()

        // Handle navigation/replace requests issued from the FindBar.
        if coordinator.lastNextRequest != findState.nextRequest {
            coordinator.lastNextRequest = findState.nextRequest
            DispatchQueue.main.async { coordinator.advance(by: 1) }
        }
        if coordinator.lastPrevRequest != findState.prevRequest {
            coordinator.lastPrevRequest = findState.prevRequest
            DispatchQueue.main.async { coordinator.advance(by: -1) }
        }
        if coordinator.lastReplaceRequest != findState.replaceRequest {
            coordinator.lastReplaceRequest = findState.replaceRequest
            DispatchQueue.main.async { coordinator.replaceCurrent() }
        }
        if coordinator.lastReplaceAllRequest != findState.replaceAllRequest {
            coordinator.lastReplaceAllRequest = findState.replaceAllRequest
            DispatchQueue.main.async { coordinator.replaceAll() }
        }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.textView = nil
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SearchableTextEditor
        weak var textView: NSTextView?
        var lastNextRequest: Int = 0
        var lastPrevRequest: Int = 0
        var lastReplaceRequest: Int = 0
        var lastReplaceAllRequest: Int = 0

        init(_ parent: SearchableTextEditor) {
            self.parent = parent
            self.lastNextRequest = parent.findState.nextRequest
            self.lastPrevRequest = parent.findState.prevRequest
            self.lastReplaceRequest = parent.findState.replaceRequest
            self.lastReplaceAllRequest = parent.findState.replaceAllRequest
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            parent.text = tv.string
            // Matches will recompute on the SwiftUI side via onChange(of: text).
        }

        // MARK: - Find handling

        func openFindBar(showReplace: Bool = false) {
            if !parent.findState.isVisible {
                parent.findState.isVisible = true
            }
            if showReplace {
                parent.findState.showReplace = true
            }
            // Seed query from current selection if non-empty.
            if let tv = textView {
                let sel = tv.selectedRange()
                if sel.length > 0, let s = (tv.string as NSString?)?.substring(with: sel), !s.isEmpty, s.count < 200 {
                    parent.findState.query = s
                }
            }
            parent.findState.focusTarget = .find
            parent.findState.focusRequest &+= 1
        }

        func closeFindBar() {
            parent.findState.isVisible = false
            parent.findState.showReplace = false
            parent.findState.query = ""
            parent.findState.replacement = ""
            parent.findState.matches = []
            applyHighlights()
            textView?.window?.makeFirstResponder(textView)
        }

        func nextMatch() {
            if !parent.findState.isVisible || parent.findState.query.isEmpty {
                openFindBar()
                return
            }
            parent.findState.nextRequest &+= 1
        }

        func prevMatch() {
            if !parent.findState.isVisible || parent.findState.query.isEmpty {
                openFindBar()
                return
            }
            parent.findState.prevRequest &+= 1
        }

        /// Replace the currently-highlighted match with `findState.replacement`,
        /// then advance to the next match.
        func replaceCurrent() {
            let matches = parent.findState.matches
            guard !matches.isEmpty, let tv = textView else { return }
            let idx = parent.findState.currentIndex
            guard matches.indices.contains(idx) else { return }
            let target = matches[idx]
            let replacement = parent.findState.replacement

            // Use the text view's edit machinery so undo works.
            if tv.shouldChangeText(in: target, replacementString: replacement) {
                tv.replaceCharacters(in: target, with: replacement)
                tv.didChangeText() // posts textDidChange → updates binding → onChange recomputes matches
            }

            // After mutation, move toward the same logical position.
            // The recompute on the SwiftUI side will refresh `matches`; we let
            // the next `advance` handle scrolling once the new state arrives.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let newMatches = self.parent.findState.matches
                guard !newMatches.isEmpty, let tv = self.textView else {
                    self.applyHighlights()
                    return
                }
                let caret = tv.selectedRange().location
                if let firstAfter = newMatches.firstIndex(where: { $0.location >= caret }) {
                    self.parent.findState.currentIndex = firstAfter
                } else {
                    self.parent.findState.currentIndex = 0
                }
                let next = newMatches[self.parent.findState.currentIndex]
                tv.setSelectedRange(next)
                tv.scrollRangeToVisible(next)
                self.applyHighlights()
            }
        }

        /// Replace every match in one undoable edit.
        func replaceAll() {
            let matches = parent.findState.matches
            guard !matches.isEmpty, let tv = textView else { return }
            let replacement = parent.findState.replacement

            // Apply replacements right-to-left so earlier ranges stay valid.
            tv.undoManager?.beginUndoGrouping()
            for range in matches.reversed() {
                if tv.shouldChangeText(in: range, replacementString: replacement) {
                    tv.replaceCharacters(in: range, with: replacement)
                }
            }
            tv.didChangeText()
            tv.undoManager?.endUndoGrouping()
            tv.undoManager?.setActionName("Replace All")
        }

        func advance(by step: Int) {
            let matches = parent.findState.matches
            guard !matches.isEmpty, let tv = textView else { return }
            var idx = parent.findState.currentIndex + step
            if idx < 0 { idx = matches.count - 1 }
            if idx >= matches.count { idx = 0 }
            parent.findState.currentIndex = idx
            let target = matches[idx]
            tv.setSelectedRange(target)
            tv.scrollRangeToVisible(target)
            applyHighlights()
        }

        func applyHighlights() {
            guard let tv = textView, let storage = tv.textStorage else { return }
            let full = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.removeAttribute(.backgroundColor, range: full)
            let matches = parent.findState.matches
            let current = parent.findState.currentIndex
            for (i, range) in matches.enumerated() where range.location + range.length <= storage.length {
                let color: NSColor = (i == current)
                    ? NSColor.systemOrange.withAlphaComponent(0.55)
                    : NSColor.systemYellow.withAlphaComponent(0.45)
                storage.addAttribute(.backgroundColor, value: color, range: range)
            }
            storage.endEditing()
        }
    }
}

/// Custom NSTextView subclass that intercepts Cmd-F / Cmd-G / Cmd-Shift-G / Esc.
final class InterceptingTextView: NSTextView {
    weak var coordinator: SearchableTextEditor.Coordinator?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let coordinator, event.type == .keyDown {
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if mods == .command, chars == "f" {
                coordinator.openFindBar()
                return true
            }
            if mods == [.command, .option], chars == "f" {
                coordinator.openFindBar(showReplace: true)
                return true
            }
            if mods == .command, chars == "g" {
                coordinator.nextMatch()
                return true
            }
            if mods == [.command, .shift], chars == "g" {
                coordinator.prevMatch()
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if coordinator?.parent.findState.isVisible == true {
            coordinator?.closeFindBar()
        } else {
            super.cancelOperation(sender)
        }
    }
}
