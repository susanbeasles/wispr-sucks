import AppKit

// The menu-bar control panel (the NSPopover shown when the mic is clicked).
//
// Built entirely in code (no nib - this app is a SwiftPM executable). The
// centerpiece is live vocabulary management: it holds the SAME DictionaryStore
// instance the Dictator reads at each session start, so a word added here takes
// effect on the next dictation with no restart.
//
// Pure UI: it only calls existing store methods. It never touches the audio or
// dictation path.

final class ControlPanelController: NSViewController {
    private let store: SecureStore
    private let workflows: WorkflowStore
    private let rag: RAGIndex
    private let dictionary: DictionaryStore

    // Wired by StatusItemController after construction.
    var history: HistoryWindow?
    var onReset: (() -> Void)?
    var onQuit: (() -> Void)?

    private let stateLabel = NSTextField(labelWithString: "Idle")
    private let statsLabel = NSTextField(labelWithString: "")
    private let wordField = NSTextField()
    private let vocabList = NSStackView()
    private var cleanupToggle: NSButton!
    private var listening = false   // last known state; applied when the view loads

    private let panelWidth: CGFloat = 340

    init(store: SecureStore, workflows: WorkflowStore, rag: RAGIndex, dictionary: DictionaryStore) {
        self.store = store
        self.workflows = workflows
        self.rag = rag
        self.dictionary = dictionary
        super.init(nibName: nil, bundle: nil)
    }

    // Never loaded from a nib; this path is unreachable.
    required init?(coder: NSCoder) { fatalError("ControlPanelController is code-only") }

    // MARK: - View

    override func loadView() {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 8
        root.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        root.translatesAutoresizingMaskIntoConstraints = false

        // Header: title + live state.
        let title = NSTextField(labelWithString: "SonarDictate")
        title.font = .boldSystemFont(ofSize: 13)
        stateLabel.font = .systemFont(ofSize: 11)
        stateLabel.textColor = .secondaryLabelColor
        let header = row([title, flexibleSpace(), stateLabel])
        root.addArrangedSubview(header)

        statsLabel.font = .systemFont(ofSize: 11)
        statsLabel.textColor = .secondaryLabelColor
        root.addArrangedSubview(statsLabel)

        root.addArrangedSubview(separator())

        // Vocabulary section.
        let vocabHeader = NSTextField(labelWithString: "Vocabulary - words the recognizer should know")
        vocabHeader.font = .systemFont(ofSize: 11, weight: .semibold)
        vocabHeader.textColor = .secondaryLabelColor
        root.addArrangedSubview(vocabHeader)

        wordField.placeholderString = "Add a word or phrase, then Return"
        wordField.font = .systemFont(ofSize: 12)
        wordField.target = self
        wordField.action = #selector(handleAddWord)
        wordField.bezelStyle = .roundedBezel
        let addButton = NSButton(title: "Add", target: self, action: #selector(handleAddWord))
        addButton.bezelStyle = .rounded
        let addRow = row([wordField, addButton])
        wordField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        root.addArrangedSubview(addRow)
        addRow.widthAnchor.constraint(equalToConstant: panelWidth - 28).isActive = true

        // Scrollable list of current words.
        vocabList.orientation = .vertical
        vocabList.alignment = .leading
        vocabList.spacing = 2
        vocabList.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = vocabList
        root.addArrangedSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: panelWidth - 28),
            scroll.heightAnchor.constraint(equalToConstant: 150),
            vocabList.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            vocabList.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            vocabList.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        root.addArrangedSubview(separator())

        // Cleanup toggle.
        cleanupToggle = NSButton(checkboxWithTitle: "Clean up dictation (LLM punctuation)", target: self, action: #selector(handleToggleCleanup))
        if #available(macOS 26.0, *) {
            cleanupToggle.state = Cleanup.isEnabled ? .on : .off
        } else {
            cleanupToggle.isEnabled = false
        }
        root.addArrangedSubview(cleanupToggle)

        root.addArrangedSubview(separator())

        // Actions.
        root.addArrangedSubview(actionButton("Dictation History...", #selector(handleHistory)))
        root.addArrangedSubview(actionButton("Show Storage in Finder", #selector(handleOpenDir)))
        root.addArrangedSubview(actionButton("Reset Storage...", #selector(handleReset)))
        root.addArrangedSubview(actionButton("Quit SonarDictate", #selector(handleQuit)))

        root.widthAnchor.constraint(equalToConstant: panelWidth).isActive = true
        self.view = root
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
    }

    // MARK: - Public

    func setState(listening: Bool) {
        self.listening = listening
        // The view (and its outlets) only exist after the popover is first opened.
        // Until then there is nothing to update - just remember the state.
        guard isViewLoaded else { return }
        applyState()
    }

    func refresh() {
        // Same guard: refreshCounts() fires after every dictation, which can be
        // long before the user ever opens the panel. Touching cleanupToggle (an
        // implicitly-unwrapped outlet) before loadView() ran is what crashed the
        // app. No view -> nothing to refresh.
        guard isViewLoaded else { return }
        applyState()
        refreshStatsOnly()
        if #available(macOS 26.0, *) { cleanupToggle.state = Cleanup.isEnabled ? .on : .off }
        rebuildVocab()
    }

    private func applyState() {
        stateLabel.stringValue = listening ? "Listening" : "Idle"
        stateLabel.textColor = listening ? .systemGreen : .secondaryLabelColor
    }

    // MARK: - Vocabulary

    private func rebuildVocab() {
        for v in vocabList.arrangedSubviews { v.removeFromSuperview() }
        let entries = dictionary.list()
        if entries.isEmpty {
            let empty = NSTextField(labelWithString: "No words yet. Add your jargon above.")
            empty.font = .systemFont(ofSize: 11)
            empty.textColor = .tertiaryLabelColor
            vocabList.addArrangedSubview(empty)
            return
        }
        for entry in entries {
            let label = NSTextField(labelWithString: entry.term)
            label.font = .systemFont(ofSize: 12)
            label.lineBreakMode = .byTruncatingTail
            let remove = NSButton(title: "x", target: self, action: #selector(handleRemoveWord(_:)))
            remove.bezelStyle = .circular
            remove.font = .systemFont(ofSize: 10)
            remove.identifier = NSUserInterfaceItemIdentifier(entry.term)
            remove.toolTip = "Remove \"\(entry.term)\""
            let r = row([label, flexibleSpace(), remove])
            r.widthAnchor.constraint(equalToConstant: panelWidth - 50).isActive = true
            vocabList.addArrangedSubview(r)
        }
    }

    @objc private func handleAddWord() {
        let word = wordField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }
        // weight 2 matches a manual CLI add; shared instance => live next session.
        dictionary.add(word, weight: 2, source: .manual)
        wordField.stringValue = ""
        NSLog("SonarDictate: vocabulary word added from panel (\(word.count) chars)")
        rebuildVocab()
        refreshStatsOnly()
    }

    @objc private func handleRemoveWord(_ sender: NSButton) {
        guard let term = sender.identifier?.rawValue else { return }
        dictionary.remove(term)
        rebuildVocab()
        refreshStatsOnly()
    }

    private func refreshStatsOnly() {
        let n = (try? store.list().count) ?? 0
        statsLabel.stringValue = "\(n) recordings  -  \(dictionary.count) words  -  \(rag.count) indexed\(rag.assetsReady ? "" : " (loading)")"
    }

    // MARK: - Actions

    @objc private func handleToggleCleanup() {
        if #available(macOS 26.0, *) {
            Cleanup.isEnabled.toggle()
            cleanupToggle.state = Cleanup.isEnabled ? .on : .off
            NSLog("SonarDictate: cleanup pass \(Cleanup.isEnabled ? "ENABLED" : "DISABLED") from panel")
        }
    }

    @objc private func handleHistory() { history?.show() }

    @objc private func handleOpenDir() {
        NSWorkspace.shared.activateFileViewerSelecting([SecureStore.baseDir])
    }

    @objc private func handleReset() { onReset?() }
    @objc private func handleQuit() { onQuit?() }

    // MARK: - Layout helpers

    private func row(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.alignment = .centerY
        s.spacing = 6
        return s
    }

    private func flexibleSpace() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return v
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: panelWidth - 28).isActive = true
        return box
    }

    private func actionButton(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.alignment = .left
        b.widthAnchor.constraint(equalToConstant: panelWidth - 28).isActive = true
        return b
    }
}
