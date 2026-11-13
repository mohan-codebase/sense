import AppKit
import ServiceManagement

final class Preferences {
    static let shared = Preferences()
    static let changed = Notification.Name("SensePreferencesChanged")
    let defaults: UserDefaults
    static let cards = ["Network", "Thermal", "Battery", "CPU", "GPU", "MEM", "Free space"]
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: ["range":120, "refresh":1.0, "compact":false, "fahrenheit":false,
            "menuTemperature":false, "menuMemory":false, "menuNetwork":false, "sortCPU":false,
            "temperatureAlerts":true, "memoryAlerts":true, "batteryAlerts":true, "otherAlerts":true,
            "sound":false, "temperatureLimit":90, "memoryLimit":2, "batteryLow":20, "batteryHigh":80,
            "cardOrder":Self.cards, "compactCards":["CPU", "MEM", "Thermal", "Battery"]])
    }
    func bool(_ key: String) -> Bool { defaults.bool(forKey:key) }
    func number(_ key: String) -> Double { defaults.double(forKey:key) }
    func strings(_ key: String) -> [String] { defaults.stringArray(forKey:key) ?? [] }
    func set(_ key: String, _ value: Any) {
        defaults.set(value, forKey:key)
        NotificationCenter.default.post(name:Self.changed, object:self)
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
}

final class SettingsController: NSWindowController {
    private let prefs = Preferences.shared
    private var handlers: [NSControl: () -> Void] = [:]
    private var cardsList: NSStackView?
    convenience init() {
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:520,height:580), styleMask:[.titled,.closable], backing:.buffered, defer:false)
        window.title = "Sense Settings"
        window.isReleasedWhenClosed = false
        self.init(window:window)
        let title = NSTextField(labelWithString: "Sense")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        title.frame = NSRect(x: 28, y: 534, width: 180, height: 28)
        let subtitle = NSTextField(labelWithString: "Tune your menu bar, cards, and alerts.")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.frame = NSRect(x: 28, y: 511, width: 450, height: 18)
        window.contentView?.addSubview(title)
        window.contentView?.addSubview(subtitle)
        let tabs = NSTabView(frame:NSRect(x:16,y:16,width:488,height:480))
        tabs.autoresizingMask = [.width,.height]
        window.contentView?.addSubview(tabs)
        func page(_ title:String) -> NSStackView {
            let item = NSTabViewItem(identifier:title); item.label = title
            let host = NSView(); item.view = host; tabs.addTabViewItem(item)
            let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
            stack.translatesAutoresizingMaskIntoConstraints = false; host.addSubview(stack)
            NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:host.leadingAnchor,constant:20),stack.trailingAnchor.constraint(equalTo:host.trailingAnchor,constant:-20),stack.topAnchor.constraint(equalTo:host.topAnchor,constant:20)])
            return stack
        }
        let general = page("General")
        let login = NSButton(checkboxWithTitle:"Launch Sense at login",target:self,action:#selector(changed(_:)))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        handlers[login] = { [weak self, weak login] in
            guard let login else { return }
            do {
                if login.state == .on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            } catch {
                let alert = NSAlert(); alert.messageText = "Could not change launch at login"; alert.informativeText = error.localizedDescription
                if let window = self?.window { alert.beginSheetModal(for:window) }
            }
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }
        general.addArrangedSubview(login)
        check("Use Fahrenheit", "fahrenheit", general)
        choice("Live refresh", "refresh", ["0.5 seconds","1 second","2 seconds","5 seconds"], [0.5,1,2,5], general)
        choice("Chart history", "range", ["2 minutes","15 minutes","1 hour"], [120,900,3600], general)
        choice("Sort processes by", "sortCPU", ["Memory — highest first","CPU — highest first"], [0,1], general, boolean:true)
        note("Charts collect history while Sense runs. Live refresh applies while the panel is open; background readings are saved every 5 seconds.", general)
        let menu = page("Menu Bar")
        note("Choose readings to show beside the Sense icon.", menu)
        check("CPU temperature", "menuTemperature", menu)
        check("Memory usage", "menuMemory", menu)
        check("Network download and upload", "menuNetwork", menu)
        let cards = page("Cards")
        check("Compact mode", "compact", cards)
        note("Use arrows to order cards. Check the cards to show in compact mode. Full mode shows all available cards.", cards)
        let list = NSStackView(); list.orientation = .vertical; list.alignment = .leading; list.spacing = 7
        cards.addArrangedSubview(list); cardsList = list; rebuildCards()
        let alerts = page("Alerts")
        check("Temperature and thermal pressure", "temperatureAlerts", alerts)
        choice("Temperature threshold (°C)", "temperatureLimit", ["70","80","85","90","95","100"], [70,80,85,90,95,100], alerts)
        check("Memory pressure", "memoryAlerts", alerts)
        choice("Memory threshold", "memoryLimit", ["Warning","Critical"], [2,4], alerts)
        check("Battery reminders", "batteryAlerts", alerts)
        choice("Low battery (%)", "batteryLow", ["10","15","20","25","30"], [10,15,20,25,30], alerts)
        choice("Charge reminder (%)", "batteryHigh", ["70","80","90","100"], [70,80,90,100], alerts)
        check("Disk space and sustained CPU alerts", "otherAlerts", alerts)
        check("Play notification sound", "sound", alerts)
        window.center()
    }
    @objc private func changed(_ sender:NSControl) { handlers[sender]?() }
    private func note(_ text:String, _ stack:NSStackView) {
        let label = NSTextField(wrappingLabelWithString:text); label.font = .systemFont(ofSize:11); label.textColor = .secondaryLabelColor
        label.widthAnchor.constraint(equalToConstant:420).isActive = true; stack.addArrangedSubview(label)
    }
    private func check(_ title:String, _ key:String, _ stack:NSStackView) {
        let b = NSButton(checkboxWithTitle:title,target:self,action:#selector(changed(_:))); b.state = prefs.bool(key) ? .on : .off
        handlers[b] = { [weak self, weak b] in if let b { self?.prefs.set(key,b.state == .on) } }; stack.addArrangedSubview(b)
    }
    private func choice(_ title:String, _ key:String, _ labels:[String], _ values:[Double], _ stack:NSStackView, boolean:Bool = false) {
        let p = NSPopUpButton(); p.addItems(withTitles:labels)
        p.selectItem(at:values.firstIndex(of:boolean ? (prefs.bool(key) ? 1 : 0) : prefs.number(key)) ?? 0)
        p.target = self; p.action = #selector(changed(_:))
        handlers[p] = { [weak self, weak p] in
            guard let p, values.indices.contains(p.indexOfSelectedItem) else { return }
            if boolean { self?.prefs.set(key,values[p.indexOfSelectedItem] == 1) } else { self?.prefs.set(key,values[p.indexOfSelectedItem]) }
        }
        let row = NSStackView(views:[NSTextField(labelWithString:title),p]); row.spacing = 12; stack.addArrangedSubview(row)
    }
    private func rebuildCards() {
        guard let list = cardsList else { return }
        for row in list.arrangedSubviews {
            if let row = row as? NSStackView { for control in row.arrangedSubviews.compactMap({$0 as? NSControl}) { handlers.removeValue(forKey:control) } }
            list.removeArrangedSubview(row); row.removeFromSuperview()
        }
        let order = prefs.order
        for (index, card) in order.enumerated() {
            let check = NSButton(checkboxWithTitle:card,target:self,action:#selector(changed(_:)))
            check.widthAnchor.constraint(equalToConstant:210).isActive = true
            check.state = prefs.strings("compactCards").contains(card) ? .on : .off
            handlers[check] = { [weak self, weak check] in
                guard let self, let check else { return }
                var chosen = self.prefs.strings("compactCards").filter { $0 != card }
                if check.state == .on { chosen.append(card) }
                if chosen.isEmpty { check.state = .on; return }
                self.prefs.set("compactCards",chosen)
            }
            let row = NSStackView(views:[check]); row.spacing = 8
            for (title,delta) in [("↑",-1),("↓",1)] {
                let button = NSButton(title:title,target:self,action:#selector(changed(_:)))
                button.bezelStyle = .rounded; button.isEnabled = order.indices.contains(index+delta)
                button.setAccessibilityLabel("Move \(card) \(delta < 0 ? "up" : "down")")
                handlers[button] = { [weak self] in
                    guard let self else { return }; var next = self.prefs.order
                    guard next.indices.contains(index+delta) else { return }
                    next.swapAt(index,index+delta); self.prefs.set("cardOrder",next); self.rebuildCards()
                }
                row.addArrangedSubview(button)
            }
            list.addArrangedSubview(row)
        }
    }
    func present() { showWindow(nil); NSApp.activate(ignoringOtherApps:true); window?.makeKeyAndOrderFront(nil) }
}
