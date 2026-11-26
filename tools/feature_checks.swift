extension ProcessTable {
    func verifySortPosition() {
        frame = NSRect(x:0,y:0,width:380,height:236)
        rows = (0..<20).map { ProcRow(pid: Int32($0 + 1), name: "Process \($0)", bytes: Double(20 - $0) * 1_000_000, cpu: Double($0)) }
        assert(process(at: NSPoint(x: 30, y: 20)) == nil)
        assert(process(at: NSPoint(x: 30, y: rowsTop + 1))?.pid == rows[0].pid)
        offset = rowH * 3
        assert(process(at: NSPoint(x: 30, y: rowsTop + 1))?.pid == rows[3].pid)
        sortsByCPU = true
        assert(offset == 0, "Changing sort must show the largest consumer first")
        offset = rowH * 4
        sortsByCPU = false
        assert(offset == 0)
        offset = rowH * 2
        scrollToTop()
        assert(offset == 0)
        let host = NSWindow(contentRect: NSRect(x:0,y:0,width:380,height:236), styleMask: [.borderless], backing: .buffered, defer: false)
        frame = host.contentView!.bounds
        host.contentView!.addSubview(self)
        var activated: ProcRow?
        onActivate = { activated = $0 }
        let point = convert(NSPoint(x:30, y:rowsTop + 1), to: nil)
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: host.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0, windowNumber: host.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0)!
        mouseDown(with: down); mouseUp(with: up)
        assert(activated?.pid == rows[0].pid)
        activated = nil
        mouseDown(with: down)
        rows.swapAt(0, 1)
        mouseUp(with: up)
        assert(activated == nil, "A refresh between mouse down/up must not target another process")
        let children = accessibilityChildren() as! [ProcessAccessibilityRow]
        assert(!children.isEmpty)
        _ = children[0].accessibilityPerformPress()
        assert(activated?.pid == rows[0].pid)
    }
}
func verifyProcessEnding() throws {
    for force in [false, true] {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { if child.isRunning { child.terminate() } }
        let row = ProcessSampler().top(Int.max).first { $0.pid == child.processIdentifier }!
        assert(row.startedAt != 0)
        var stale = row
        stale.startedAt += 1
        do {
            try ProcessControl.end(stale, force: true)
            assertionFailure("Stale process identities must be rejected")
        } catch ProcessControl.Failure.identityChanged { }
        assert(child.isRunning)
        try ProcessControl.end(row, force: force)
        child.waitUntilExit()
        assert(child.terminationReason == .uncaughtSignal)
        assert(child.terminationStatus == (force ? SIGKILL : SIGTERM))
        do {
            try ProcessControl.end(row, force: force)
            assertionFailure("Exited processes must be rejected")
        } catch ProcessControl.Failure.noLongerRunning { }
    }
    for pid in [Int32(0), 1, getpid()] {
        do {
            try ProcessControl.end(ProcRow(pid:pid, name:"Protected", bytes:0, cpu:0), force:true)
            assertionFailure("Protected processes must not be signalled")
        } catch ProcessControl.Failure.protectedProcess { }
    }
    print("PASS: process selection, accessible actions, quit, force quit, stale/exited process rejection")
}
extension AppDelegate {
    func verifyFeatures() {
        buildPanel()
        lastMem = MemStats()
        applyPreferences()
        assert(tiles.tiles.count >= 5)
        gpuHist = [0.25, nil]
        lastGPU = nil
        updateTiles(sample: false, record: false)
        let unavailableGPU = tiles.tiles.first { $0.title == "GPU" }
        assert(unavailableGPU?.value == "—" && unavailableGPU?.footer == "Unavailable")
        assert(unavailableGPU?.readouts.last == "")
        lastGPU = 0
        updateTiles(sample: false, record: false)
        let idleGPU = tiles.tiles.first { $0.title == "GPU" }
        assert(idleGPU?.value == "0" && idleGPU?.unit == "%")
        assert(idleGPU?.chartTint == HealthState.normal.chartInk)
        lastMem.pressureAvailable = false
        updateTiles(sample: false, record: false)
        assert(tiles.tiles.first { $0.title == "MEM" }?.badge == "Unavailable")
        lastMem.pressureAvailable = true
        for (level, status) in [(1, HealthState.normal), (2, .warning), (4, .critical)] {
            lastMem.level = level
            updateTiles(sample: false, record: false)
            let memory = tiles.tiles.first { $0.title == "MEM" }
            assert(memory?.status == status && memory?.badge == status.pressureLabel)
            assert(memory?.chartTint == status.chartInk)
        }
        lastDie = prefs.number("temperatureLimit") + 5
        lastThermalStatus = .normal
        cpuLoad = 0.91
        lastGPU = 0.75
        updateTiles(sample: false, record: false)
        let thermal = tiles.tiles.first { $0.title == "Thermal" }
        assert(thermal?.status == .warning && thermal?.badge == "Hot" && thermal?.chartTint == HealthState.warning.chartInk)
        let cpu = tiles.tiles.first { $0.title == "CPU" }
        let gpu = tiles.tiles.first { $0.title == "GPU" }
        let network = tiles.tiles.first { $0.title == "Network" }
        assert(cpu?.status == nil && cpu?.chartTint == HealthState.critical.chartInk)
        assert(gpu?.status == nil && gpu?.chartTint == HealthState.warning.chartInk)
        assert(network?.status == nil && network?.chartTint == HealthState.normal.chartInk)
        for tile in tiles.tiles where tile.title == "Battery" || tile.title == "Free space" {
            assert(tile.chartTint == (tile.status ?? .normal).chartInk)
        }
        assert(sections.allSatisfy { !$0.0.expanded && $0.1.isHidden })
        let initialHeight = panelHeight
        panel.setFrame(NSRect(x:0, y:0, width:panelWidth, height:initialHeight), display:true)
        panel.contentView?.layoutSubtreeIfNeeded()
        let surface = panel.contentView!
        assert(!panel.hasShadow && !panel.isOpaque)
        assert(surface.layer?.cornerRadius == 18 && surface.layer?.masksToBounds == true)
        assert(surface.subviews.count == 1 && surface.subviews.first?.frame == surface.bounds)
        if #available(macOS 26.0, *) {
            let glass = surface.subviews.first as? NSGlassEffectView
            assert(glass?.style == .regular && scroll.superview === glass?.contentView)
        } else {
            assert(scroll.superview is NSVisualEffectView)
        }
        assert(tiles.frame.width == panelWidth)
        assert(stack.arrangedSubviews.dropFirst().first === tiles)
        assert(sections.first { $0.0 === procHeader }?.1 === procTable)
        assert(tiles.subviews.count == tiles.tiles.count)
        if #available(macOS 26.0, *) {
            assert(tiles.subviews.allSatisfy { ($0 as? NSGlassEffectView)?.cornerRadius == 13 })
        } else {
            assert(tiles.subviews.allSatisfy { $0 is NSVisualEffectView })
        }
        let fullTileMaterials = tiles.subviews
        updateTiles(sample: false, record: false)
        tiles.layoutSubtreeIfNeeded()
        assert(zip(tiles.subviews, fullTileMaterials).allSatisfy { $0 === $1 })
        assert(stack.frame.width == panelWidth)
        assert(document.frame.height == stack.fittingSize.height)
        assert(initialHeight <= (NSScreen.main?.visibleFrame.height ?? 800) - 16)
        // Expanded content remains reachable on smaller displays.
        for (_, body) in sections { body.isHidden = false }
        let expandedHeight = panelHeight
        assert(expandedHeight <= (NSScreen.main?.visibleFrame.height ?? 800) - 16)
        assert(document.frame.height > expandedHeight)
        for (_, body) in sections { body.isHidden = true }
        assert(memHeader.accessibilityRole() == .button)
        assert(memHeader.accessibilityLabel() == "Memory")
        let fullHeight = tiles.requiredHeight
        prefs.set("compact", true)
        prefs.defaults.set(["CPU","MEM"], forKey:"compactCards")
        applyPreferences()
        tiles.layoutSubtreeIfNeeded()
        assert(tiles.tiles.map { $0.title } == ["CPU","MEM"])
        assert(tiles.subviews.count == 2)
        assert(tiles.requiredHeight < fullHeight)
        assert(sections.allSatisfy { $0.0.isHidden && $0.1.isHidden })
        prefs.defaults.set(false, forKey:"compact")
        prefs.defaults.set(["MEM","CPU"], forKey:"cardOrder")
        applyPreferences()
        assert(tiles.tiles.first?.title == "MEM")
        assert(sections.allSatisfy { !$0.0.isHidden })
        let headerButtons = stack.arrangedSubviews.first?.subviews.compactMap({ $0 as? NSButton })
        assert(headerButtons?.map({ $0.accessibilityLabel() }) == ["Sense Settings"])
        prefs.setTile("Network", visible: false, in: .full)
        applyTileLayout()
        assert(!tiles.tiles.contains { $0.title == "Network" })
        for title in prefs.visibleTiles { prefs.setTile(title, visible: false, in: .full) }
        applyTileLayout()
        assert(tiles.isHidden && !emptyTiles.isHidden)
        prefs.setTile("Network", visible: true, in: .full)
        applyTileLayout()
        assert(tiles.tiles.map(\.title) == ["Network"])
        assert(!tiles.isHidden && emptyTiles.isHidden)
        prefs.showAllTiles(in: .full)
        applyTileLayout()
        for range in [120,900,3600] {
            prefs.defaults.set(range,forKey:"range")
            updateLive(sampleHistory:false)
            assert(MemoryPanel.windowDuration == Double(range))
            assert(memPanel.history.count == memPanel.sampleTimes.count)
        }
        ProcessTable().verifySortPosition()
        prefs.defaults.set(true,forKey:"sortCPU"); updateProcesses()
        assert(procTable.sortsByCPU)
        assert(zip(procTable.rows,procTable.rows.dropFirst()).allSatisfy { $0.cpu >= $1.cpu })
        prefs.defaults.set(false,forKey:"sortCPU"); updateProcesses()
        assert(!procTable.sortsByCPU)
        assert(zip(procTable.rows,procTable.rows.dropFirst()).allSatisfy { $0.bytes >= $1.bytes })
        assert(item.length == NSStatusItem.variableLength)
        assert(item.button?.imagePosition == .imageOnly && item.button?.title.isEmpty == true)
        assert(item.button?.image?.isTemplate == true && item.button?.image?.size == NSSize(width: 16, height: 18))
        let settings = SettingsController()
        let content = settings.window!.contentView!
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let tabs = descendants(content).compactMap { $0 as? NSSegmentedControl }.first!
        tabs.selectedSegment = 1
        tabs.sendAction(tabs.action, to: tabs.target)
        func button(_ name: String) -> NSButton {
            descendants(content).compactMap { $0 as? NSButton }
                .first { $0.accessibilityLabel() == name || $0.title == name }!
        }
        let fullNetwork = button("Show Network in Full")
        let compactNetwork = button("Show Network in Compact")
        assert(fullNetwork.state == .on && compactNetwork.state == .off)
        compactNetwork.performClick(nil)
        assert(!prefs.bool("compact") && prefs.visibleTiles(in: .compact).contains("Network"))
        assert(fullNetwork.state == .on)
        fullNetwork.performClick(nil)
        assert(!prefs.visibleTiles.contains("Network") && compactNetwork.state == .on)
        button("Show All in Full").performClick(nil)
        assert(fullNetwork.state == .on && !button("Show All in Full").isEnabled)
        button("Show All in Compact").performClick(nil)
        assert(prefs.visibleTiles(in: .compact) == Set(Preferences.cards))
        button("Reset Order").performClick(nil)
        assert(prefs.order == Preferences.cards && !button("Reset Order").isEnabled)
        print("PASS: compact layout, card order, chart ranges, process sorting, menu bar icon, settings construction, rounded glass panel, panel geometry, overflow scrolling, accessible disclosure controls")
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
let original = UserDefaults.standard.persistentDomain(forName:domain)
defer {
    if let original { UserDefaults.standard.setPersistentDomain(original,forName:domain) }
    else { UserDefaults.standard.removePersistentDomain(forName:domain) }
}
UserDefaults.standard.removePersistentDomain(forName:domain)
let suite = "SenseFeatureTest-" + UUID().uuidString
let defaults = UserDefaults(suiteName:suite)!
let test = Preferences(defaults:defaults)
assert(test.range == 120 && test.interval == 1)
test.set("range",900); test.set("fahrenheit",true)
assert(Preferences(defaults:defaults).range == 900)
assert(test.temperature(100) == "212°F")
test.set("cardOrder",["CPU","CPU","bogus"])
assert(test.order.count == 7 && test.order.first == "CPU")
assert(test.visibleTiles == Set(Preferences.cards))
test.setTile("CPU", visible: false)
assert(!Preferences(defaults: defaults).visibleTiles.contains("CPU"))
test.set("compact", true)
assert(test.visibleTiles.contains("CPU"))
test.setTile("MEM", visible: false)
assert(!test.visibleTiles.contains("MEM"))
test.set("compact", false)
assert(!test.visibleTiles.contains("CPU") && test.visibleTiles.contains("MEM"))
test.setTile("CPU", visible: true)
assert(test.visibleTiles.contains("CPU"))
test.set("range",0); assert(test.range == 120)
defaults.removePersistentDomain(forName:suite)
AppDelegate().verifyFeatures()
try verifyProcessEnding()

assert(batteryChargePercent(current: 80, maximum: 100) == 80)
assert(batteryChargePercent(current: 2100, maximum: 5000) == 42)
assert(batteryChargePercent(current: 5100, maximum: 5000) == 100)
assert(batteryChargePercent(current: 0, maximum: 5000) == 0)
assert(batteryChargePercent(current: -1, maximum: 5000) == nil)
assert(batteryChargePercent(current: 80, maximum: 0) == nil)

let signedBoundary = cpuTickValue(Int32.max)
assert(cpuTickValue(Int32.min) == signedBoundary + 1)
assert(cpuTickValue(-1) == UInt64(UInt32.max))
assert(cpuLoadFraction(from: (signedBoundary, signedBoundary + 100),
                       to: (cpuTickValue(Int32.min), signedBoundary + 104)) == 0.25)
assert(cpuLoadFraction(from: (200, 400), to: (10, 410)) == nil)
assert(cpuLoadFraction(from: (200, 400), to: (230, 410)) == nil)
assert(cpuLoadFraction(from: (200, 400), to: (200, 400)) == nil)
assert(cpuLoadFraction(from: (200, 400), to: (200, 420)) == 0)
print("PASS: battery percentage normalization and CPU counter rollover")

var network = NetworkSampler()
assert(network.sample(["en0": (500_000_000, 200), "en1": (300, 100)], at: 1) == (0, 0))
assert(network.sample(["en0": (0, 400), "en1": (500, 300)], at: 3) == (100, 200))
assert(network.sample(["en0": (10, 410), "en2": (900_000, 1_000_000)], at: 4) == (10, 10))
assert(network.sample(["en0": (11, 411)], at: 4.01) == (10, 10))
assert(network.sample([:], at: 5) == (0, 0))
assert(network.sample(["en0": (50, 500)], at: 6) == (0, 0))
assert(network.sample(["en0": (90, 520)], at: 8) == (20, 10))

let historyEncoder = JSONEncoder()
let historyDecoder = JSONDecoder()
let previousGPUHistory = try historyEncoder.encode([0.25, 0.5])
let decodedGPUHistory = try historyDecoder.decode([Double?].self, from: previousGPUHistory)
assert(decodedGPUHistory == [0.25, 0.5])
let savedHistory = try historyEncoder.encode(SavedHistory(gpu: [0.25, nil, 0]))
let restoredHistory = try historyDecoder.decode(SavedHistory.self, from: savedHistory)
assert(restoredHistory.gpu == [0.25, nil, 0])
print("PASS: unavailable GPU readings, history gaps, and network counter resets")

var episodeCheck = AlertEpisode()
let alertStart = Date(timeIntervalSince1970: 1000)
assert(!episodeCheck.update(active: true, now: alertStart))
assert(!episodeCheck.update(active: true, now: alertStart.addingTimeInterval(29)))
assert(episodeCheck.update(active: true, now: alertStart.addingTimeInterval(30)))
assert(!episodeCheck.update(active: true, now: alertStart.addingTimeInterval(3600)), "Persistent pressure must not repeat")
assert(!episodeCheck.update(active: false, now: alertStart.addingTimeInterval(3601)))
assert(!episodeCheck.update(active: true, now: alertStart.addingTimeInterval(3610)), "A brief dip must not rearm")
assert(!episodeCheck.update(active: false, now: alertStart.addingTimeInterval(3620)))
assert(!episodeCheck.update(active: false, now: alertStart.addingTimeInterval(3680)))
assert(!episodeCheck.update(active: true, now: alertStart.addingTimeInterval(3681)))
assert(episodeCheck.update(active: true, now: alertStart.addingTimeInterval(3711)), "Recovered conditions should rearm")
var transientCheck = AlertEpisode()
assert(!transientCheck.update(active: true, now: alertStart))
assert(!transientCheck.update(active: false, now: alertStart.addingTimeInterval(20)))
assert(!transientCheck.update(active: true, now: alertStart.addingTimeInterval(25)))
assert(!transientCheck.update(active: true, now: alertStart.addingTimeInterval(45)))
print("PASS: sustained alerts, spike suppression, recovery and no-repeat behavior")
