import AppKit

// A standalone window listing every dictation in the encrypted store, so the
// user can always recover a past dictation - even when a live paste misfired and
// the text never landed in the target field. Read-only: select a row (or
// double-click, or hit Copy) to put that dictation's full transcript on the
// clipboard. Nothing here mutates or deletes.
//
// The app is LSUIElement (no dock icon), so a borderless background process
// can't normally bring a real titled window forward. show() flips the
// activation policy to .regular while the window is open and restores
// .accessory when it closes - the standard accessory-app pattern.

final class HistoryWindow: NSObject {
    private let store: SecureStore
    private var window: NSWindow?
    private var tableView: NSTableView?
    private var records: [RecordingMetadata] = []

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    init(store: SecureStore) {
        self.store = store
        super.init()
    }

    // Build (once), refresh from disk, and bring to front.
    func show() {
        ensureWindow()
        reload()
        NSLog("SonarDictate: history window show - \(records.count) recordings")
        NSApp.setActivationPolicy(.regular)
        if let window {
            if !window.isVisible { window.center() }
            window.makeKeyAndOrderFront(nil)
            // Force it in front even though a menu-bar app is NOT "active" when its
            // status item is clicked - otherwise the window orders in behind your
            // current app and it looks like the click did nothing.
            window.orderFrontRegardless()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    // Copy the most recent dictation's transcript straight to the clipboard, no
    // window needed. The "give me my last dictation back" fast path.
    @discardableResult
    func copyMostRecent() -> Bool {
        guard let latest = ((try? store.list()) ?? []).first else {
            NSLog("SonarDictate: copyMostRecent - no recordings yet")
            return false
        }
        return copyTranscript(id: latest.id)
    }

    // MARK: - Internals

    private func reload() {
        records = (try? store.list()) ?? []   // SecureStore.list() is newest-first
        tableView?.reloadData()
    }

    @discardableResult
    private func copyTranscript(id: String) -> Bool {
        guard let (_, transcript) = try? store.read(id) else {
            NSLog("SonarDictate: history copy failed - could not read \(id)")
            return false
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(transcript, forType: .string)
        NSLog("SonarDictate: history -> clipboard (\(transcript.count) chars from \(id))")
        return true
    }

    private func copySelected() {
        guard let row = tableView?.selectedRow, row >= 0, row < records.count else { return }
        _ = copyTranscript(id: records[row].id)
    }

    private func appName(_ bundleID: String?) -> String {
        guard let b = bundleID else { return "-" }
        return b.split(separator: ".").last.map(String.init) ?? b
    }

    @objc private func handleDoubleClick() { copySelected() }
    @objc private func handleCopyButton() { copySelected() }

    private func ensureWindow() {
        if window != nil { return }

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Iris - History"
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 480, height: 280)
        win.delegate = self

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let table = NSTableView()
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.rowHeight = 40
        table.target = self
        table.doubleAction = #selector(handleDoubleClick)

        let whenCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("when"))
        whenCol.title = "When"
        whenCol.width = 150
        whenCol.minWidth = 120
        table.addTableColumn(whenCol)

        let appCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
        appCol.title = "App"
        appCol.width = 130
        appCol.minWidth = 80
        table.addTableColumn(appCol)

        let textCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("text"))
        textCol.title = "Transcript"
        textCol.width = 380
        textCol.minWidth = 160
        table.addTableColumn(textCol)

        table.dataSource = self
        table.delegate = self
        tableView = table
        scroll.documentView = table

        let copyButton = NSButton(title: "Copy Transcript", target: self, action: #selector(handleCopyButton))
        copyButton.bezelStyle = .rounded
        copyButton.keyEquivalent = "\r"
        copyButton.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(labelWithString: "Double-click a row, or select one and click Copy. Every dictation is saved here.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(scroll)
        container.addSubview(copyButton)
        container.addSubview(hint)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: copyButton.topAnchor, constant: -8),

            hint.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            hint.centerYAnchor.constraint(equalTo: copyButton.centerYAnchor),

            copyButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            copyButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])

        win.contentView = container
        window = win
    }
}

extension HistoryWindow: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // Drop back to background (no dock icon) once the window is dismissed.
        NSApp.setActivationPolicy(.accessory)
    }
}

extension HistoryWindow: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { records.count }
}

extension HistoryWindow: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < records.count, let col = tableColumn else { return nil }
        let rec = records[row]
        let columnID = col.identifier.rawValue

        let value: String
        switch columnID {
        case "when": value = dateFormatter.string(from: rec.createdAt)
        case "app":  value = appName(rec.appContext)
        default:     value = rec.transcriptPreview.replacingOccurrences(of: "\n", with: " ")
        }

        let cellID = NSUserInterfaceItemIdentifier("cell.\(columnID)")
        let field: NSTextField
        if let reused = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTextField {
            field = reused
        } else {
            field = NSTextField(labelWithString: "")
            field.identifier = cellID
            field.lineBreakMode = .byTruncatingTail
            field.cell?.usesSingleLineMode = (columnID != "text")
            if columnID == "text" { field.maximumNumberOfLines = 2 }
        }
        field.stringValue = value
        field.textColor = (columnID == "text") ? .labelColor : .secondaryLabelColor
        return field
    }
}
