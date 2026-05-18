import AppKit

// Menu-bar (status item) controller.
//
// SonarDictate has LSUIElement=YES in its Info.plist, so it never gets a
// dock icon. This controller is the only persistent UI affordance for
// users to see that the app is running, what state it's in, and to
// manage their corpus without dropping to the CLI.
//
// The icon flips between `mic.circle` (idle) and `mic.circle.fill`
// (actively listening) so a glance at the menu bar tells you whether
// Option is being held. Menu items surface counts from each store and
// expose a destructive Reset behind a confirmation alert.

final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let store: SecureStore
    private let workflows: WorkflowStore
    private let rag: RAGIndex

    private var stateItem: NSMenuItem!
    private var recordingsItem: NSMenuItem!
    private var workflowsItem: NSMenuItem!
    private var ragItem: NSMenuItem!

    init(store: SecureStore, workflows: WorkflowStore, rag: RAGIndex) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.store = store
        self.workflows = workflows
        self.rag = rag
        super.init()

        setIcon(listening: false)
        buildMenu()
        refreshCounts()
    }

    // Called by Dictator on every state change. Cheap; runs on main thread.
    func setListening(_ listening: Bool) {
        DispatchQueue.main.async {
            self.setIcon(listening: listening)
            self.stateItem.title = listening ? "Listening" : "Idle"
        }
    }

    // Called after any session finalize so the menu reflects current counts
    // the next time the user opens it.
    func refreshCounts() {
        DispatchQueue.main.async {
            let n = (try? self.store.list().count) ?? 0
            let w = (try? self.workflows.list().count) ?? 0
            let r = self.rag.count
            self.recordingsItem.title = "Recordings: \(n)"
            self.workflowsItem.title  = "Workflows:  \(w)"
            self.ragItem.title        = "RAG index:  \(r)\(self.rag.assetsReady ? "" : " (model loading)")"
        }
    }

    // MARK: - Setup

    private func setIcon(listening: Bool) {
        guard let button = statusItem.button else { return }
        let name = listening ? "mic.circle.fill" : "mic.circle"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "SonarDictate")
        image?.isTemplate = true
        button.image = image
        button.toolTip = listening ? "SonarDictate — listening" : "SonarDictate — idle"
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        // Refresh counts each time the menu opens so they stay current.
        menu.delegate = self

        stateItem = NSMenuItem(title: "Idle", action: nil, keyEquivalent: "")
        stateItem.isEnabled = false
        menu.addItem(stateItem)

        menu.addItem(.separator())

        recordingsItem = NSMenuItem(title: "Recordings: 0", action: nil, keyEquivalent: "")
        recordingsItem.isEnabled = false
        menu.addItem(recordingsItem)

        workflowsItem = NSMenuItem(title: "Workflows: 0", action: nil, keyEquivalent: "")
        workflowsItem.isEnabled = false
        menu.addItem(workflowsItem)

        ragItem = NSMenuItem(title: "RAG index: 0", action: nil, keyEquivalent: "")
        ragItem.isEnabled = false
        menu.addItem(ragItem)

        menu.addItem(.separator())

        let openDir = NSMenuItem(title: "Show Storage in Finder", action: #selector(handleOpenDir), keyEquivalent: "")
        openDir.target = self
        menu.addItem(openDir)

        let resetItem = NSMenuItem(title: "Reset Storage…", action: #selector(handleReset), keyEquivalent: "")
        resetItem.target = self
        menu.addItem(resetItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit SonarDictate", action: #selector(handleQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    // MARK: - Actions

    @objc private func handleOpenDir() {
        NSWorkspace.shared.activateFileViewerSelecting([SecureStore.baseDir])
    }

    @objc private func handleReset() {
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
            try store.reset()           // wipes the directory including the SE key
            try? rag.reset()             // best-effort; recreates index file shell
            NSLog("SonarDictate: storage reset by user from menu")
        } catch {
            let err = NSAlert()
            err.messageText = "Reset failed"
            err.informativeText = "\(error)"
            err.alertStyle = .warning
            err.runModal()
            return
        }

        refreshCounts()

        let done = NSAlert()
        done.messageText = "Storage reset complete."
        done.informativeText = "SonarDictate needs to restart so it can re-create the encryption key. Quitting now."
        done.alertStyle = .informational
        done.addButton(withTitle: "Quit")
        done.runModal()
        NSApp.terminate(nil)
    }

    @objc private func handleQuit() {
        NSApp.terminate(nil)
    }
}

extension StatusItemController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        refreshCounts()
    }
}
