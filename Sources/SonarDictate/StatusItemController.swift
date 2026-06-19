import AppKit

// Menu-bar (status item) controller.
//
// SonarDictate has LSUIElement=YES in its Info.plist, so it never gets a dock
// icon. This controller is the only persistent UI affordance. The icon flips
// between `mic.circle` (idle) and `mic.circle.fill` (listening). Clicking it
// opens the ControlPanel popover (state, stats, live vocabulary editing, the
// cleanup toggle, and actions). The destructive Reset still goes through a
// critical confirmation alert, owned here.

final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let store: SecureStore
    private let rag: RAGIndex

    private let popover = NSPopover()
    private let panel: ControlPanelController
    private var clickMonitor: Any?

    // Set after construction (wired in main, like the other UI affordances).
    var history: HistoryWindow? {
        didSet { panel.history = history }
    }

    // Right-click (or option-click) the menu-bar mic toggles the screen eyes.
    // Wired in main. A left-click still opens the control-panel popover.
    var onToggleEyes: (() -> Void)?

    init(store: SecureStore, workflows: WorkflowStore, rag: RAGIndex, dictionary: DictionaryStore) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.store = store
        self.rag = rag
        self.panel = ControlPanelController(store: store, workflows: workflows, rag: rag, dictionary: dictionary)
        super.init()

        // applicationDefined (not transient) so a click on the mic toggles the
        // popover instead of AppKit auto-dismissing it mid-click and reopening.
        // We close it ourselves on an outside click via a global monitor.
        popover.behavior = .applicationDefined
        popover.contentViewController = panel
        panel.onReset = { [weak self] in self?.handleReset() }
        panel.onQuit = { NSApp.terminate(nil) }

        setIcon(listening: false)
        if let button = statusItem.button {
            button.action = #selector(togglePanel)
            button.target = self
            // Receive right-clicks too, so we can route them to the eyes toggle.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    // Called by Dictator on every state change. Cheap; runs on main thread.
    func setListening(_ listening: Bool) {
        DispatchQueue.main.async {
            self.setIcon(listening: listening)
            self.panel.setState(listening: listening)
        }
    }

    // Called after any session finalize so the panel reflects current counts.
    func refreshCounts() {
        DispatchQueue.main.async { self.panel.refresh() }
    }

    // MARK: - Popover

    @objc private func togglePanel() {
        // Right-click or option-click -> toggle the screen eyes instead of the panel.
        if let event = NSApp.currentEvent,
           event.type == .rightMouseUp || event.modifierFlags.contains(.option) {
            onToggleEyes?()
            return
        }
        if popover.isShown { closePanel() } else { showPanel() }
    }

    private func showPanel() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // LSUIElement apps are not active by default; activate so the vocabulary
        // text field can take keyboard focus.
        NSApp.activate(ignoringOtherApps: true)
        panel.refresh()
        // Close when the user clicks in another app. Clicks inside the popover are
        // local events the global monitor never sees, so it stays open while used.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePanel()
        }
    }

    private func closePanel() {
        popover.performClose(nil)
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
    }

    // MARK: - Icon

    private func setIcon(listening: Bool) {
        guard let button = statusItem.button else { return }
        let name = listening ? "mic.circle.fill" : "mic.circle"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "SonarDictate")
        image?.isTemplate = true
        button.image = image
        button.toolTip = listening ? "SonarDictate - listening" : "SonarDictate - idle"
    }

    // MARK: - Reset (destructive; owned here, invoked from the panel)

    private func handleReset() {
        closePanel()
        let alert = NSAlert()
        alert.messageText = "Reset SonarDictate storage?"
        alert.informativeText = """
        Deletes every recording, transcript, RAG index entry, workflow \
        binding, and the Secure Enclave key. Anything in backups or \
        Time Machine snapshots becomes permanently unrecoverable because \
        the device key is destroyed.

        This cannot be undone.
        """
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try store.reset()
            try? rag.reset()
            NSLog("SonarDictate: storage reset by user from panel")
        } catch {
            let err = NSAlert()
            err.messageText = "Reset failed"
            err.informativeText = "\(error)"
            err.alertStyle = .warning
            err.runModal()
            return
        }

        let done = NSAlert()
        done.messageText = "Storage reset complete."
        done.informativeText = "SonarDictate needs to restart so it can re-create the encryption key. Quitting now."
        done.alertStyle = .informational
        done.addButton(withTitle: "Quit")
        done.runModal()
        NSApp.terminate(nil)
    }
}
