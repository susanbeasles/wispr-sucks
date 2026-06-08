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

    // Set after construction (like the other UI affordances wired in main).
    var history: HistoryWindow?
    private var cleanupMenuItem: NSMenuItem?
    private var recentItems: [NSMenuItem] = []

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

        // Browse + recover every past dictation (also bound to a global hotkey
        // in main). The safety net for when a live paste misses its target.
        let historyItem = NSMenuItem(title: "Dictation History...", action: #selector(handleHistory), keyEquivalent: "")
        historyItem.target = self
        menu.addItem(historyItem)

        // Toggle the on-device LLM cleanup pass on/off. Checkmark = on.
        let cleanupItem = NSMenuItem(title: "Clean Up Dictation (LLM)", action: #selector(handleToggleCleanup), keyEquivalent: "")
        cleanupItem.target = self
        if #available(macOS 26.0, *) {
            cleanupItem.state = Cleanup.isEnabled ? .on : .off
        } else {
            cleanupItem.isEnabled = false
        }
        cleanupMenuItem = cleanupItem
        menu.addItem(cleanupItem)

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

        // Clicking the mic drops this menu (always visible = guaranteed feedback).
        // The most recent dictations are listed at the top, rebuilt on each open
        // in menuWillOpen - click one to copy it.
        statusItem.menu = menu
    }

    // MARK: - Actions

    @objc private func handleOpenDir() {
        NSWorkspace.shared.activateFileViewerSelecting([SecureStore.baseDir])
    }

    @objc private func handleHistory() {
        history?.show()
    }

    // Rebuild the "recent dictations" block at the top of the menu each time it
    // opens, newest first. Each entry copies that dictation's full transcript to
    // the clipboard on click - the fast "grab the last message, or one from 10
    // ago" path, right in the menu with guaranteed visual feedback.
    private func rebuildRecents(in menu: NSMenu) {
        for item in recentItems { menu.removeItem(item) }
        recentItems.removeAll()

        let recents = Array(((try? store.list()) ?? []).prefix(10))
        guard !recents.isEmpty else { return }

        // Insert right after the state item + its separator (indices 0 and 1).
        var at = 2
        let header = NSMenuItem(title: "Recent - click to copy:", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.insertItem(header, at: at); recentItems.append(header); at += 1

        for rec in recents {
            let preview = rec.transcriptPreview
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            let title = preview.isEmpty ? "(empty)" : String(preview.prefix(50))
            let item = NSMenuItem(title: title, action: #selector(handleCopyRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = rec.id
            menu.insertItem(item, at: at); recentItems.append(item); at += 1
        }

        let sep = NSMenuItem.separator()
        menu.insertItem(sep, at: at); recentItems.append(sep)
    }

    @objc private func handleCopyRecent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let (_, transcript) = try? store.read(id) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(transcript, forType: .string)
        NSLog("SonarDictate: copied recent dictation \(id) to clipboard (\(transcript.count) chars)")
    }

    @objc private func handleToggleCleanup(_ sender: NSMenuItem) {
        if #available(macOS 26.0, *) {
            Cleanup.isEnabled.toggle()
            sender.state = Cleanup.isEnabled ? .on : .off
            NSLog("SonarDictate: cleanup pass \(Cleanup.isEnabled ? "ENABLED" : "DISABLED") by user")
        }
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
        rebuildRecents(in: menu)
        if #available(macOS 26.0, *) {
            cleanupMenuItem?.state = Cleanup.isEnabled ? .on : .off
        }
    }
}
