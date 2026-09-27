import AppKit
import Carbon.HIToolbox
import SSHManagerKit

/// Her yerden çalışan genel kısayol (varsayılan ⌃⌥S). Erişilebilirlik izni gerektirmez.
final class HotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    init(keyCode: Int = kVK_ANSI_S, modifiers: Int = controlKey | optionKey, action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData = userData else { return noErr }
            Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue().action()
            return noErr
        }, 1, &spec, me, &handlerRef)
        let id = EventHotKeyID(signature: OSType(0x5353484D), id: 1) // "SSHM"
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    deinit {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        if let ref = handlerRef { RemoveEventHandler(ref) }
    }
}

/// Spotlight benzeri arama kutusu: yaz, ok tuşlarıyla seç, Enter ile bağlan.
final class QuickConnectPanel: NSObject, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {

    var onConnect: ((Server) -> Void)?
    var onFiles: ((Server) -> Void)?

    private let panel: NSPanel
    private let search = NSSearchField()
    private let table = NSTableView()
    private let hint = NSTextField(labelWithString: "Enter: bağlan   ⌘Enter: dosyalar (mc)   Esc: kapat")
    private var all: [(alias: String, server: Server)] = []
    private var items: [(alias: String, server: Server)] = []

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
                        styleMask: [.titled, .fullSizeContentView],
                        backing: .buffered, defer: false)
        super.init()
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        buildUI()
    }

    func show() {
        ServerStore.shared.load()
        all = ServerStore.shared.aliases().sorted {
            $0.server.name.localizedCaseInsensitiveCompare($1.server.name) == .orderedAscending
        }
        search.stringValue = ""
        filter()
        NSApp.activate(ignoringOtherApps: true)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(search)
    }

    // MARK: - Arayüz

    private func buildUI() {
        let content = NSView()
        panel.contentView = content

        search.placeholderString = "Sunucu ara… (ad, host, grup)"
        search.font = .systemFont(ofSize: 18)
        search.focusRingType = .none
        search.delegate = self
        search.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("server"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 44
        table.style = .inset
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(connectSelected)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false

        hint.textColor = .tertiaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        hint.translatesAutoresizingMaskIntoConstraints = false

        [search, scroll, hint].forEach(content.addSubview)
        NSLayoutConstraint.activate([
            search.topAnchor.constraint(equalTo: content.topAnchor, constant: 30),
            search.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            search.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -6),
            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            hint.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])
    }

    private func filter() {
        // Harf/rakam içermeyen parçaları yok say; kalanları Türkçe karakterden arındırıp ara.
        let tokens = search.stringValue.split(separator: " ")
            .filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }
            .map { Server.slugify(String($0)) }
        items = all.filter { entry in
            let s = entry.server
            let hay = Server.slugify([s.name, entry.alias, s.host, s.user, s.displayGroup].joined(separator: " "))
            return tokens.allSatisfy { hay.contains($0) }
        }
        table.reloadData()
        if !items.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
    }

    // MARK: - Klavye

    func controlTextDidChange(_ obj: Notification) { filter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        case #selector(NSResponder.insertNewline(_:)):
            if NSEvent.modifierFlags.contains(.command) { filesSelected() } else { connectSelected() }
            return true
        case #selector(NSResponder.cancelOperation(_:)): panel.orderOut(nil); return true
        default: return false
        }
    }

    private func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        let row = max(0, min(items.count - 1, table.selectedRow + delta))
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    private var selected: Server? {
        let row = table.selectedRow
        return row >= 0 && row < items.count ? items[row].server : nil
    }

    @objc private func connectSelected() {
        guard let s = selected else { return }
        panel.orderOut(nil)
        onConnect?(s)
    }

    private func filesSelected() {
        guard let s = selected else { return }
        panel.orderOut(nil)
        onFiles?(s)
    }

    func windowDidResignKey(_ notification: Notification) { panel.orderOut(nil) }

    // MARK: - Tablo

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = items[row]
        let s = entry.server
        let title = NSTextField(labelWithString: s.name)
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        let detail = NSTextField(labelWithString: "\(s.sshDestination)\(s.port == 22 ? "" : ":\(s.port)")  ·  \(s.displayGroup)  ·  sshm \(entry.alias)")
        detail.font = .systemFont(ofSize: 11.5)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [title, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 6, bottom: 5, right: 6)
        return stack
    }
}
