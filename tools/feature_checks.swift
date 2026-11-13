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
        assert(sections.allSatisfy { !$0.0.expanded && $0.1.isHidden })
        let initialHeight = panelHeight
        panel.setFrame(NSRect(x:0, y:0, width:panelWidth, height:initialHeight), display:true)
        panel.contentView?.layoutSubtreeIfNeeded()
        if #available(macOS 26.0, *) {
            assert(panel.contentView is NSGlassEffectView)
            assert(!panel.hasShadow, "Native glass must not have a second rectangular window shadow")
        } else {
            assert(panel.hasShadow)
        }
        assert(tiles.frame.width == panelWidth)
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
        prefs.defaults.set(true, forKey:"compact")
        prefs.defaults.set(["CPU","MEM"], forKey:"compactCards")
        applyPreferences()
        assert(tiles.tiles.map { $0.title } == ["CPU","MEM"])
        assert(tiles.requiredHeight < fullHeight)
        assert(sections.allSatisfy { $0.0.isHidden && $0.1.isHidden })
        prefs.defaults.set(false, forKey:"compact")
        prefs.defaults.set(["MEM","CPU"], forKey:"cardOrder")
        applyPreferences()
        assert(tiles.tiles.first?.title == "MEM")
        assert(sections.allSatisfy { !$0.0.isHidden })
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
        lastDie = 40; prefs.defaults.set(true,forKey:"fahrenheit")
        prefs.defaults.set(true,forKey:"menuTemperature"); updateMenuReadings()
        assert(item.button!.title.contains("104°F"))
        prefs.defaults.set(false,forKey:"menuTemperature"); updateMenuReadings()
        assert(item.button!.title.isEmpty)
        let settings = SettingsController()
        assert(settings.window != nil)
        print("PASS: compact layout, card order, chart ranges, process sorting, menu readings, units, settings construction, panel geometry, overflow scrolling, accessible disclosure controls")
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
test.set("range",0); assert(test.range == 120)
defaults.removePersistentDomain(forName:suite)
AppDelegate().verifyFeatures()
try verifyProcessEnding()

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
