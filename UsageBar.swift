import Cocoa

// UsageBar v2 — menu bar usage for Claude Code + Codex
// Animated progress-bar dropdown, configurable auto-refresh.

let appDir = ("~/Library/Application Support/UsageBar" as NSString).expandingTildeInPath
let helperPath = appDir + "/usagebar_helper.py"

struct Usage {
    var session: Double?
    var weekly: Double?
    var sessionReset: Double?
    var weeklyReset: Double?
    var err: String?
}

func barColor(_ pct: Double?) -> NSColor {
    guard let p = pct else { return .tertiaryLabelColor }
    if p > 80 { return .systemRed }
    if p >= 60 { return .systemYellow }
    return .systemGreen
}

func parse(_ d: [String: Any]?) -> Usage {
    var u = Usage()
    guard let d = d else { u.err = "no data"; return u }
    u.session = (d["session"] as? NSNumber)?.doubleValue
    u.weekly = (d["weekly"] as? NSNumber)?.doubleValue
    u.sessionReset = (d["session_reset"] as? NSNumber)?.doubleValue
    u.weeklyReset = (d["weekly_reset"] as? NSNumber)?.doubleValue
    u.err = d["err"] as? String
    return u
}

func fmtReset(_ ts: Double?) -> String {
    guard let ts = ts else { return "" }
    let d = Date(timeIntervalSince1970: ts)
    let secs = d.timeIntervalSinceNow
    let f = DateFormatter()
    f.dateFormat = secs < 86400 ? "h:mm a" : "EEE h:mm a"
    if secs > 0 && secs < 86400 {
        let h = Int(secs) / 3600, m = (Int(secs) % 3600) / 60
        return "Resets in \(h) hr \(m) min"
    }
    return "Resets \(f.string(from: d))"
}

// MARK: - Progress row view

final class UsageRowView: NSView {
    let titleLabel = NSTextField(labelWithString: "")
    let subLabel = NSTextField(labelWithString: "")
    let pctLabel = NSTextField(labelWithString: "")
    let track = NSView()
    let fill = NSView()
    var pct: Double?

    init(title: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 52))
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.stringValue = title
        subLabel.font = .systemFont(ofSize: 10)
        subLabel.textColor = .secondaryLabelColor
        pctLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        pctLabel.alignment = .right
        track.wantsLayer = true
        fill.wantsLayer = true
        track.layer?.cornerRadius = 3.5
        fill.layer?.cornerRadius = 3.5
        for v in [titleLabel, subLabel, pctLabel, track] { addSubview(v) }
        track.addSubview(fill)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let w = bounds.width
        titleLabel.frame = NSRect(x: 14, y: 30, width: 170, height: 16)
        pctLabel.frame = NSRect(x: w - 100, y: 30, width: 86, height: 16)
        track.frame = NSRect(x: 14, y: 18, width: w - 28, height: 7)
        subLabel.frame = NSRect(x: 14, y: 2, width: w - 28, height: 13)
        track.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        layoutFill(animated: false)
    }

    func layoutFill(animated: Bool) {
        let p = CGFloat(min(max(pct ?? 0, 0), 100)) / 100.0
        let target = NSRect(x: 0, y: 0, width: track.bounds.width * p, height: track.bounds.height)
        fill.layer?.backgroundColor = barColor(pct).cgColor
        if animated {
            fill.frame = NSRect(x: 0, y: 0, width: 0, height: track.bounds.height)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.6
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                fill.animator().frame = target
            }
        } else {
            fill.frame = target
        }
    }

    func update(pct: Double?, reset: Double?, remaining: Bool) {
        self.pct = pct
        if let p = pct {
            pctLabel.stringValue = remaining
                ? String(format: "%.0f%% left", max(0, 100 - p))
                : String(format: "%.0f%% used", p)
            pctLabel.textColor = barColor(p)
            subLabel.stringValue = fmtReset(reset)
        } else {
            pctLabel.stringValue = "–"
            pctLabel.textColor = .secondaryLabelColor
            subLabel.stringValue = "No data yet"
        }
        needsLayout = true
    }
}

final class HeaderView: NSView {
    init(_ text: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 26))
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 13, weight: .bold)
        l.frame = NSRect(x: 14, y: 4, width: 260, height: 18)
        addSubview(l)
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class ErrView: NSView {
    let l = NSTextField(labelWithString: "")
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 18))
        l.font = .systemFont(ofSize: 10)
        l.textColor = .systemOrange
        l.frame = NSRect(x: 14, y: 1, width: 272, height: 14)
        addSubview(l)
    }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - App

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    var claude = Usage()
    var codex = Usage()
    var menu = NSMenu()

    var clSession = UsageRowView(title: "Current session")
    var clWeekly = UsageRowView(title: "Weekly · all models")
    var cxSession = UsageRowView(title: "Current session")
    var cxWeekly = UsageRowView(title: "Weekly")
    var clErr = ErrView()
    var cxErr = ErrView()
    var clErrItem = NSMenuItem()
    var cxErrItem = NSMenuItem()

    var showRemaining: Bool {
        get { UserDefaults.standard.bool(forKey: "showRemaining") }
        set { UserDefaults.standard.set(newValue, forKey: "showRemaining") }
    }
    var remainingItem = NSMenuItem()
    var refreshMenu = NSMenu()

    var interval: Double {
        get { let v = UserDefaults.standard.double(forKey: "refreshInterval"); return v == 0 ? 30 : v }
        set { UserDefaults.standard.set(newValue, forKey: "refreshInterval"); restartTimer() }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.attributedTitle = NSAttributedString(string: "⏳")
        buildMenu()
        refresh()
        restartTimer()
    }

    func restartTimer() {
        timer?.invalidate()
        if interval > 0 {
            timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in self.refresh() }
        }
    }

    func refresh() {
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = [helperPath]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = Pipe()
            do {
                try p.run()
                p.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let c = parse(obj["claude"] as? [String: Any])
                    let x = parse(obj["codex"] as? [String: Any])
                    DispatchQueue.main.async {
                        self.claude = c; self.codex = x
                        self.updateUI(animated: false)
                    }
                }
            } catch {}
        }
    }

    func updateUI(animated: Bool) {
        // status bar title — two stacked lines to save width
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
        let para = NSMutableParagraphStyle()
        para.maximumLineHeight = 10
        para.minimumLineHeight = 10
        para.alignment = .left
        let title = NSMutableAttributedString()
        func seg(_ label: String, _ u: Usage) {
            title.append(NSAttributedString(string: label,
                attributes: [.font: font, .foregroundColor: NSColor.labelColor,
                             .paragraphStyle: para]))
            var s = "–"
            if let p = u.session {
                s = String(format: "%.0f", showRemaining ? max(0, 100 - p) : p)
            }
            title.append(NSAttributedString(string: s,
                attributes: [.font: font, .foregroundColor: barColor(u.session),
                             .paragraphStyle: para]))
        }
        seg("C", claude)
        title.append(NSAttributedString(string: "\n",
            attributes: [.font: font, .paragraphStyle: para]))
        seg("X", codex)
        statusItem.button?.attributedTitle = title

        clSession.update(pct: claude.session, reset: claude.sessionReset, remaining: showRemaining)
        clWeekly.update(pct: claude.weekly, reset: claude.weeklyReset, remaining: showRemaining)
        cxSession.update(pct: codex.session, reset: codex.sessionReset, remaining: showRemaining)
        cxWeekly.update(pct: codex.weekly, reset: codex.weeklyReset, remaining: showRemaining)
        clErr.l.stringValue = claude.err.map { "⚠︎ \($0)" } ?? ""
        cxErr.l.stringValue = codex.err.map { "⚠︎ \($0)" } ?? ""
        clErrItem.isHidden = claude.err == nil
        cxErrItem.isHidden = codex.err == nil
        if animated {
            for r in [clSession, clWeekly, cxSession, cxWeekly] {
                r.layoutSubtreeIfNeeded()
                r.layoutFill(animated: true)
            }
        }
    }

    func viewItem(_ v: NSView) -> NSMenuItem {
        let i = NSMenuItem()
        i.view = v
        return i
    }

    func buildMenu() {
        menu = NSMenu()
        menu.delegate = self
        menu.minimumWidth = 300
        menu.addItem(viewItem(HeaderView("Claude Code")))
        menu.addItem(viewItem(clSession))
        menu.addItem(viewItem(clWeekly))
        clErrItem = viewItem(clErr); menu.addItem(clErrItem)
        menu.addItem(.separator())
        menu.addItem(viewItem(HeaderView("Codex")))
        menu.addItem(viewItem(cxSession))
        menu.addItem(viewItem(cxWeekly))
        cxErrItem = viewItem(cxErr); menu.addItem(cxErrItem)
        menu.addItem(.separator())

        remainingItem = NSMenuItem(title: "Show Remaining Instead of Used",
                                   action: #selector(toggleRemaining), keyEquivalent: "")
        remainingItem.target = self
        remainingItem.state = showRemaining ? .on : .off
        menu.addItem(remainingItem)

        refreshMenu = NSMenu()
        let opts: [(String, Double)] = [("10 sec", 10), ("20 sec", 20), ("30 sec", 30), ("1 hour", 3600), ("Off", -1)]
        for (label, val) in opts {
            let it = NSMenuItem(title: label, action: #selector(setInterval(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = val
            refreshMenu.addItem(it)
        }
        syncIntervalTicks()
        let refreshRoot = NSMenuItem(title: "Auto Refresh", action: nil, keyEquivalent: "")
        refreshRoot.submenu = refreshMenu
        menu.addItem(refreshRoot)

        let r = NSMenuItem(title: "Refresh Now", action: #selector(doRefresh), keyEquivalent: "r")
        r.target = self
        menu.addItem(r)
        menu.addItem(NSMenuItem(title: "Quit UsageBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    func syncIntervalTicks() {
        let cur = UserDefaults.standard.double(forKey: "refreshInterval")
        let effective = cur == 0 ? 30.0 : cur
        for it in refreshMenu.items {
            it.state = (it.representedObject as? Double) == effective ? .on : .off
        }
    }

    func menuWillOpen(_ m: NSMenu) {
        guard m == menu else { return }
        syncIntervalTicks()
        updateUI(animated: true)
        refresh()
    }

    @objc func setInterval(_ sender: NSMenuItem) {
        interval = sender.representedObject as? Double ?? 30
        syncIntervalTicks()
    }

    @objc func toggleRemaining() {
        showRemaining.toggle()
        remainingItem.state = showRemaining ? .on : .off
        updateUI(animated: false)
    }

    @objc func doRefresh() { refresh() }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
