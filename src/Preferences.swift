import AppKit
import ServiceManagement

final class Preferences {
    enum TileLayout: String, CaseIterable {
        case full = "Full"
        case compact = "Compact"

        var visibilityKey: String { self == .full ? "hiddenCards" : "compactCards" }
    }

    static let shared = Preferences()
    static let changed = Notification.Name("SensePreferencesChanged")
    static let tileVisibilityKeys = Set(TileLayout.allCases.map(\.visibilityKey))
    let defaults: UserDefaults
    static let cards = ["Network", "Thermal", "Battery", "CPU", "GPU", "MEM", "Free space"]
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: ["range":120, "refresh":1.0, "compact":false, "fahrenheit":false,
            "sortCPU":false,
            "temperatureAlerts":true, "memoryAlerts":true, "batteryAlerts":true, "otherAlerts":true,
            "sound":false, "temperatureLimit":90, "memoryLimit":2, "batteryLow":20, "batteryHigh":80,
            "cardOrder":Self.cards, "hiddenCards":[String](), "compactCards":["CPU", "MEM", "Thermal", "Battery"]])
    }
    func bool(_ key: String) -> Bool { defaults.bool(forKey:key) }
    func number(_ key: String) -> Double { defaults.double(forKey:key) }
    func strings(_ key: String) -> [String] { defaults.stringArray(forKey:key) ?? [] }
    func set(_ key: String, _ value: Any) {
        defaults.set(value, forKey:key)
        NotificationCenter.default.post(name: Self.changed, object: self, userInfo: ["key": key])
    }
    var range: Double { [120.0,900,3600].contains(number("range")) ? number("range") : 120 }
    var interval: Double { [0.5,1,2,5].contains(number("refresh")) ? number("refresh") : 1 }
    var rangeLabel: String { range == 120 ? "2 min" : range == 900 ? "15 min" : "1 hour" }
    func temperature(_ c: Double, unit: Bool = true) -> String {
        String(format:"%.0f", bool("fahrenheit") ? c * 1.8 + 32 : c) + (unit ? (bool("fahrenheit") ? "°F" : "°C") : "")
    }
    var order: [String] {
        var result = [String]()
        for card in strings("cardOrder") + Self.cards where Self.cards.contains(card) && !result.contains(card) { result.append(card) }
        return result
    }

    var visibleTiles: Set<String> { visibleTiles(in: activeTileLayout) }

    private var activeTileLayout: TileLayout { bool("compact") ? .compact : .full }

    func visibleTiles(in layout: TileLayout) -> Set<String> {
        let stored = Set(strings(layout.visibilityKey))
        let cards = Set(Self.cards)
        return layout == .full ? cards.subtracting(stored) : cards.intersection(stored)
    }

    func setTile(_ tile: String, visible: Bool, in layout: TileLayout? = nil) {
        let layout = layout ?? activeTileLayout
        var shown = visibleTiles(in: layout)
        guard Self.cards.contains(tile), shown.contains(tile) != visible else { return }
        if visible { shown.insert(tile) } else { shown.remove(tile) }
        saveTileVisibility(shown, in: layout)
    }

    func showAllTiles(in layout: TileLayout) {
        saveTileVisibility(Set(Self.cards), in: layout)
    }

    private func saveTileVisibility(_ shown: Set<String>, in layout: TileLayout) {
        let stored = Self.cards.filter { shown.contains($0) == (layout == .compact) }
        set(layout.visibilityKey, stored)
    }
}

private final class SettingsGroup: NSStackView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        NSColor.labelColor.withAlphaComponent(0.035).setFill()
        shape.fill()
        NSColor.labelColor.withAlphaComponent(0.11).setStroke()
        shape.lineWidth = 1
        shape.stroke()
    }
}

final class SettingsController: NSWindowController {
    private static let width: CGFloat = 468
    private static let margin: CGFloat = 20
    private static let pageWidth = width - 2 * margin
    private static let visibilityColumnWidth: CGFloat = 66
    private static let githubProfile = URL(string: "https://github.com/mohan-codebase")!

    private let prefs = Preferences.shared
    private let layout = NSStackView()
    private let tabs = NSSegmentedControl(labels: ["General", "Cards", "Alerts"], trackingMode: .selectOne,
                                          target: nil, action: nil)
    private let cardRows = SettingsGroup()
    private var visibilityChecks: [Preferences.TileLayout: [String: NSButton]] = [:]
    private var showAllButtons: [Preferences.TileLayout: NSButton] = [:]
    private let resetOrder = NSButton(title: "Reset Order", target: nil, action: nil)
    private var pages: [NSStackView] = []
    private var activePage: NSStackView?
    private var actions: [NSControl: () -> Void] = [:]

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 360),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Sense Settings"
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(name: nil) { appearance in
            let shade: CGFloat = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? 0.125 : 0.98
            return NSColor(white: shade, alpha: 1)
        }
        self.init(window: window)
        buildContent()
        NotificationCenter.default.addObserver(self, selector: #selector(refreshCardVisibility),
                                               name: Preferences.changed, object: nil)
        window.center()
    }

    private func buildContent() {
        guard let content = window?.contentView else { return }
        layout.orientation = .vertical
        layout.alignment = .leading
        layout.spacing = 16
        layout.edgeInsets = NSEdgeInsets(top: Self.margin, left: Self.margin, bottom: Self.margin, right: Self.margin)
        layout.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(layout)
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            layout.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            layout.topAnchor.constraint(equalTo: content.topAnchor)
        ])

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 48).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 48).isActive = true
        icon.setAccessibilityElement(false)

        let title = NSTextField(labelWithString: "Sense")
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "Menu bar system monitor")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        let name = column([title, subtitle], spacing: 2)
        layout.addArrangedSubview(row([icon, name], spacing: 10))

        tabs.segmentStyle = .texturedRounded
        tabs.segmentDistribution = .fillEqually
        tabs.selectedSegment = 0
        tabs.target = self
        tabs.action = #selector(selectPage)
        tabs.setAccessibilityLabel("Settings categories")
        tabs.widthAnchor.constraint(equalToConstant: Self.pageWidth).isActive = true
        layout.addArrangedSubview(tabs)

        pages = [generalPage(), cardsPage(), alertsPage()]
        layout.addArrangedSubview(creditsFooter())
        selectPage()
    }

    @objc private func selectPage() {
        guard pages.indices.contains(tabs.selectedSegment), let window else { return }
        let page = pages[tabs.selectedSegment]
        if activePage !== page {
            if let previous = activePage {
                layout.removeArrangedSubview(previous)
                previous.removeFromSuperview()
            }
            layout.insertArrangedSubview(page, at: layout.arrangedSubviews.count - 1)
            activePage = page
        }
        let size = NSSize(width: Self.width, height: ceil(layout.fittingSize.height))
        var frame = window.frame
        let height = window.frameRect(forContentRect: NSRect(origin: .zero, size: size)).height
        frame.origin.y = max(frame.maxY - height, window.screen?.visibleFrame.minY ?? 0)
        frame.size.height = height
        window.setFrame(frame, display: true)
    }

    private func creditsFooter() -> NSView {
        let made = NSTextField(labelWithString: "Made")
        let author = NSTextField(labelWithString: "by Mohan")
        for label in [made, author] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
        }
        let heart = NSImageView(image: NSImage(systemSymbolName: "heart.fill", accessibilityDescription: nil)!)
        heart.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        heart.contentTintColor = .systemRed
        heart.setAccessibilityElement(false)

        let github = NSButton(title: "GitHub", target: self, action: #selector(openGitHubProfile))
        github.isBordered = false
        github.font = .systemFont(ofSize: 11)
        if let url = Bundle.main.url(forResource: "GitHubMark", withExtension: "svg"),
           let mark = NSImage(contentsOf: url) {
            mark.size = NSSize(width: 14, height: 14)
            mark.isTemplate = true
            github.image = mark
            github.imagePosition = .imageOnly
            github.contentTintColor = .labelColor
            github.widthAnchor.constraint(equalToConstant: 24).isActive = true
        }
        github.heightAnchor.constraint(equalToConstant: 22).isActive = true
        github.toolTip = "Open Mohan’s GitHub profile"
        github.setAccessibilityLabel("Mohan’s GitHub profile")

        let credits = row([made, heart, author, github], spacing: 5)
        let footer = NSView()
        credits.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(credits)
        NSLayoutConstraint.activate([
            footer.widthAnchor.constraint(equalToConstant: Self.pageWidth),
            footer.heightAnchor.constraint(equalToConstant: 22),
            credits.centerXAnchor.constraint(equalTo: footer.centerXAnchor),
            credits.centerYAnchor.constraint(equalTo: footer.centerYAnchor)
        ])
        return footer
    }

    @objc private func openGitHubProfile() {
        NSWorkspace.shared.open(Self.githubProfile)
    }

    private func generalPage() -> NSStackView {
        let login = NSSwitch()
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        bind(login) { [weak self, weak login] in
            guard let login else { return }
            do {
                if login.state == .on {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                if SMAppService.mainApp.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            } catch {
                let alert = NSAlert()
                alert.messageText = "Could not change launch at login"
                alert.informativeText = error.localizedDescription
                if let window = self?.window { alert.beginSheetModal(for: window) }
            }
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }

        let sort = choice("sortCPU", ["Memory usage", "CPU usage"], [0, 1], boolean: true)
        sort.toolTip = "Highest usage first"
        return column([
            group([
                setting("Launch at login", symbol: "power", control: login),
                setting("Use Fahrenheit", symbol: "thermometer.medium", control: toggle("fahrenheit")),
                setting("Live refresh", symbol: "arrow.clockwise", control:
                    choice("refresh", ["0.5 seconds", "1 second", "2 seconds", "5 seconds"], [0.5, 1, 2, 5])),
                setting("Chart history", symbol: "clock", control:
                    choice("range", ["2 minutes", "15 minutes", "1 hour"], [120, 900, 3600])),
                setting("Sort processes by", symbol: "list.number", control: sort)
            ]),
            note("Charts update live while the panel is open. History is sampled every 5 seconds.")
        ])
    }

    private func cardsPage() -> NSStackView {
        let showAll = Preferences.TileLayout.allCases.map { layout in
            let button = NSButton(title: "Show All in \(layout.rawValue)", target: nil, action: nil)
            button.controlSize = .small
            bind(button) { [weak self] in self?.prefs.showAllTiles(in: layout) }
            showAllButtons[layout] = button
            return button
        }
        resetOrder.controlSize = .small
        bind(resetOrder) { [weak self] in
            guard let self else { return }
            self.prefs.set("cardOrder", Preferences.cards)
            self.rebuildCards()
        }
        let bulkActions = row(showAll + [NSView(), resetOrder])
        bulkActions.widthAnchor.constraint(equalToConstant: Self.pageWidth).isActive = true
        rebuildCards()
        return column([
            group([setting("Compact mode", symbol: "rectangle.compress.vertical", control: toggle("compact"))]),
            cardRows,
            bulkActions
        ])
    }

    private func alertsPage() -> NSStackView {
        column([
            group([
                setting("Temperature and thermal pressure", symbol: "thermometer.medium", control: toggle("temperatureAlerts")),
                setting("Temperature threshold", control:
                    choice("temperatureLimit", ["70 °C", "80 °C", "85 °C", "90 °C", "95 °C", "100 °C"], [70, 80, 85, 90, 95, 100])),
                setting("Memory pressure", symbol: "memorychip", control: toggle("memoryAlerts")),
                setting("Memory threshold", control: choice("memoryLimit", ["Warning", "Critical"], [2, 4]))
            ]),
            group([
                setting("Battery reminders", symbol: "battery.100", control: toggle("batteryAlerts")),
                setting("Low battery", control: choice("batteryLow", ["10%", "15%", "20%", "25%", "30%"], [10, 15, 20, 25, 30])),
                setting("Charge reminder", control: choice("batteryHigh", ["70%", "80%", "90%", "100%"], [70, 80, 90, 100]))
            ]),
            group([
                setting("Disk space and sustained CPU", symbol: "internaldrive", control: toggle("otherAlerts")),
                setting("Play notification sound", symbol: "speaker.wave.2", control: toggle("sound"))
            ])
        ])
    }

    private func column(_ views: [NSView], spacing: CGFloat = 10) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    private func row(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        return stack
    }

    private func group(_ rows: [NSView], in stack: SettingsGroup = SettingsGroup()) -> SettingsGroup {
        let inset: CGFloat = 12
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 4, left: inset, bottom: 4, right: inset)
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let divider = NSBox()
                divider.boxType = .separator
                divider.widthAnchor.constraint(equalToConstant: Self.pageWidth - 2 * inset).isActive = true
                stack.addArrangedSubview(divider)
            }
            row.widthAnchor.constraint(equalToConstant: Self.pageWidth - 2 * inset).isActive = true
            row.heightAnchor.constraint(equalToConstant: 36).isActive = true
            stack.addArrangedSubview(row)
        }
        return stack
    }

    private func glyph(_ symbol: String?) -> NSView {
        let plate = NSView()
        plate.widthAnchor.constraint(equalToConstant: 24).isActive = true
        plate.heightAnchor.constraint(equalToConstant: 24).isActive = true
        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            let mark = NSImageView(image: image)
            mark.symbolConfiguration = .init(pointSize: 13, weight: .medium)
            mark.contentTintColor = .secondaryLabelColor
            mark.translatesAutoresizingMaskIntoConstraints = false
            plate.addSubview(mark)
            NSLayoutConstraint.activate([
                mark.centerXAnchor.constraint(equalTo: plate.centerXAnchor),
                mark.centerYAnchor.constraint(equalTo: plate.centerYAnchor)
            ])
        }
        plate.setAccessibilityElement(false)
        return plate
    }

    private func setting(_ title: String, symbol: String? = nil, control: NSControl) -> NSStackView {
        control.setAccessibilityLabel(title)
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: symbol == nil ? .regular : .medium)
        label.setAccessibilityElement(false)
        return row([glyph(symbol), label, NSView(), control])
    }

    private func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = Self.pageWidth
        label.widthAnchor.constraint(equalToConstant: Self.pageWidth).isActive = true
        return label
    }

    private func bind(_ control: NSControl, action: @escaping () -> Void) {
        control.target = self
        control.action = #selector(changed(_:))
        actions[control] = action
    }

    @objc private func changed(_ sender: NSControl) { actions[sender]?() }

    private func toggle(_ key: String) -> NSSwitch {
        let control = NSSwitch()
        control.state = prefs.bool(key) ? .on : .off
        bind(control) { [weak self, weak control] in
            guard let control else { return }
            self?.prefs.set(key, control.state == .on)
        }
        return control
    }

    private func choice(_ key: String, _ labels: [String], _ values: [Double], boolean: Bool = false) -> NSPopUpButton {
        let control = NSPopUpButton()
        control.addItems(withTitles: labels)
        let current = boolean ? (prefs.bool(key) ? 1.0 : 0.0) : prefs.number(key)
        control.selectItem(at: values.firstIndex(of: current) ?? 0)
        control.widthAnchor.constraint(equalToConstant: 134).isActive = true
        bind(control) { [weak self, weak control] in
            guard let self, let index = control?.indexOfSelectedItem, values.indices.contains(index) else { return }
            if boolean {
                self.prefs.set(key, values[index] == 1)
            } else {
                self.prefs.set(key, values[index])
            }
        }
        return control
    }

    private func rebuildCards(focusing cardToFocus: String? = nil, direction focusDirection: Int = 0) {
        for checks in visibilityChecks.values {
            for control in checks.values { actions.removeValue(forKey: control) }
        }
        visibilityChecks.removeAll()
        for row in cardRows.arrangedSubviews {
            if let row = row as? NSStackView {
                for control in row.arrangedSubviews.compactMap({ $0 as? NSControl }) {
                    actions.removeValue(forKey: control)
                }
            }
            cardRows.removeArrangedSubview(row)
            row.removeFromSuperview()
        }

        let symbols = ["Network": "network", "Thermal": "thermometer.medium", "Battery": "battery.100",
                       "CPU": "cpu", "GPU": "display", "MEM": "memorychip", "Free space": "internaldrive"]
        let order = prefs.order
        var preferredFocus: NSControl?
        var fallbackFocus: NSControl?
        let rows = order.enumerated().map { index, card in
            let name = NSTextField(labelWithString: card)
            name.setAccessibilityElement(false)
            let checks = Preferences.TileLayout.allCases.map { visibilityCheck(for: card, in: $0) }
            let moves = [-1, 1].map { direction in
                let label = "Move \(card) \(direction < 0 ? "up" : "down")"
                let symbol = direction < 0 ? "chevron.up" : "chevron.down"
                let button = NSButton(title: "", target: nil, action: nil)
                button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                button.imagePosition = .imageOnly
                button.bezelStyle = .rounded
                button.controlSize = .small
                button.widthAnchor.constraint(equalToConstant: 28).isActive = true
                let destination = index + direction
                button.isEnabled = order.indices.contains(destination)
                button.toolTip = label
                button.setAccessibilityLabel(label)
                if cardToFocus == card, button.isEnabled {
                    if direction == focusDirection { preferredFocus = button } else { fallbackFocus = button }
                }
                bind(button) { [weak self, weak button] in
                    guard let self, let button, button.isEnabled else { return }
                    // Keep keyboard focus on the moved row after the buttons are rebuilt.
                    let movedWithKeyboardFocus = self.window?.firstResponder === button
                    var next = order
                    next.swapAt(index, destination)
                    self.prefs.set("cardOrder", next)
                    self.rebuildCards(focusing: movedWithKeyboardFocus ? card : nil, direction: direction)
                }
                return button
            }
            return row([glyph(symbols[card]), name, NSView()] + checks + moves)
        }
        let headings = row([
            glyph(nil), cardHeading("Tile"), NSView(),
            cardHeading("Full", width: Self.visibilityColumnWidth),
            cardHeading("Compact", width: Self.visibilityColumnWidth),
            cardHeading("Order", width: 64)
        ])
        _ = group([headings] + rows, in: cardRows)
        refreshCardVisibility()
        if let focus = preferredFocus ?? fallbackFocus { window?.makeFirstResponder(focus) }
    }

    private func cardHeading(_ title: String, width: CGFloat? = nil) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        if let width {
            label.alignment = .center
            label.widthAnchor.constraint(equalToConstant: width).isActive = true
        }
        return label
    }

    private func visibilityCheck(for tile: String, in layout: Preferences.TileLayout) -> NSView {
        let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        let label = "Show \(tile) in \(layout.rawValue)"
        checkbox.setAccessibilityLabel(label)
        checkbox.toolTip = label
        visibilityChecks[layout, default: [:]][tile] = checkbox
        bind(checkbox) { [weak self, weak checkbox] in
            guard let checkbox else { return }
            self?.prefs.setTile(tile, visible: checkbox.state == .on, in: layout)
        }

        let cell = NSView()
        cell.widthAnchor.constraint(equalToConstant: Self.visibilityColumnWidth).isActive = true
        cell.heightAnchor.constraint(equalToConstant: 24).isActive = true
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(checkbox)
        NSLayoutConstraint.activate([
            checkbox.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
            checkbox.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    @objc private func refreshCardVisibility() {
        for (layout, checks) in visibilityChecks {
            let visible = prefs.visibleTiles(in: layout)
            for (name, control) in checks { control.state = visible.contains(name) ? .on : .off }
            showAllButtons[layout]?.isEnabled = visible.count < Preferences.cards.count
        }
        resetOrder.isEnabled = prefs.order != Preferences.cards
    }

    func present() {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
