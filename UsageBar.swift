import Cocoa
import ServiceManagement
import UserNotifications

// UsageBar v3 — Claude Code + Codex usage in the macOS menu bar.
// Single binary: all data sources are read natively (no Python helper).

// MARK: - Model

struct Usage {
    var session: Double?        // % used, 0-100
    var weekly: Double?
    var sessionReset: Date?
    var weeklyReset: Date?
    var resetIsEstimate = false
    var asOf: Date?
    var source: String?
    var err: String?
}

struct Sample { let t: Date; let session: Double; let weekly: Double? }

enum Provider: String, CaseIterable {
    case claude, codex
    var name: String { self == .claude ? "Claude Code" : "Codex" }
    var glyph: String { self == .claude ? "C" : "X" }
    var usageURL: URL {
        URL(string: self == .claude ? "https://claude.ai/settings/usage"
                                    : "https://chatgpt.com/codex/settings/usage")!
    }
}

enum MenuStyle: String, CaseIterable {
    case pill, compact, dot
    var title: String {
        switch self {
        case .pill: return "Two-line Pill"
        case .compact: return "Compact Text"
        case .dot: return "Icon with Status Dot"
        }
    }
}

// MARK: - Preferences

enum Prefs {
    static let d = UserDefaults.standard
    static var showUsed: Bool { get { d.bool(forKey: "showUsed") } set { d.set(newValue, forKey: "showUsed") } }
    static var interval: Double {
        get { let v = d.double(forKey: "refreshInterval"); return v == 0 ? 30 : v }
        set { d.set(newValue, forKey: "refreshInterval") }
    }
    static var style: MenuStyle {
        get { MenuStyle(rawValue: d.string(forKey: "menuStyle") ?? "") ?? .pill }
        set { d.set(newValue.rawValue, forKey: "menuStyle") }
    }
    static func enabled(_ p: Provider) -> Bool { d.object(forKey: "show_" + p.rawValue) as? Bool ?? true }
    static func setEnabled(_ p: Provider, _ v: Bool) { d.set(v, forKey: "show_" + p.rawValue) }
    static var notify: Bool { get { d.object(forKey: "notify") as? Bool ?? true } set { d.set(newValue, forKey: "notify") } }
}

// MARK: - Helpers

let home = FileManager.default.homeDirectoryForCurrentUser.path
let appSupport = home + "/Library/Application Support/UsageBar"

func barColor(_ pct: Double?) -> NSColor {
    guard let p = pct else { return .tertiaryLabelColor }
    if p > 80 { return .systemRed }
    if p >= 60 { return .systemYellow }
    return .systemGreen
}

/// resets_at may be epoch seconds, epoch milliseconds, or ISO-8601.
func parseDate(_ v: Any?) -> Date? {
    if let n = v as? NSNumber {
        let x = n.doubleValue
        return Date(timeIntervalSince1970: x > 1e12 ? x / 1000 : x)
    }
    if let s = v as? String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
    return nil
}

func readJSON(_ path: String) -> Any? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    return try? JSONSerialization.jsonObject(with: data)
}

func fmtCountdown(_ d: Date) -> String {
    let s = max(0, Int(d.timeIntervalSinceNow))
    let h = s / 3600, m = (s % 3600) / 60
    if h >= 24 { return "\(h / 24)d \(h % 24)h" }
    return h > 0 ? "\(h)h \(m)m" : "\(m)m"
}

func fmtReset(_ d: Date?, estimate: Bool) -> String {
    guard let d = d else { return "" }
    let secs = d.timeIntervalSinceNow
    let prefix = estimate ? "Resets ≈ " : "Resets "
    if secs > 0 && secs < 86400 {
        let h = Int(secs) / 3600, m = (Int(secs) % 3600) / 60
        return prefix + "in \(h) hr \(m) min"
    }
    let f = DateFormatter()
    f.dateFormat = secs < 86400 ? "h:mm a" : "EEE h:mm a"
    return prefix + f.string(from: d)
}

func fmtAgo(_ d: Date?) -> String {
    guard let d = d else { return "" }
    let s = Int(-d.timeIntervalSinceNow)
    if s < 60 { return "just now" }
    if s < 3600 { return "\(s / 60) min ago" }
    return "\(s / 3600) hr ago"
}

@discardableResult
func run(_ exe: String, _ args: [String]) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    do { try p.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return p.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil
}

// MARK: - Claude sources

enum ClaudeSource {
    static let desktopHistory = home + "/Library/Application Support/Claude/plan-usage-history.json"
    static let feed = appSupport + "/claude_feed.json"

    /// The Claude desktop app samples plan usage every ~15 min:
    /// {"samples":[{"t": ms, "u": {"fh": %, "sd": %}}]}. No login needed.
    static func desktopSamples() -> [Sample] {
        guard let d = readJSON(desktopHistory) as? [String: Any],
              let samples = d["samples"] as? [[String: Any]] else { return [] }
        return samples.compactMap { s in
            guard let t = parseDate(s["t"]), let u = s["u"] as? [String: Any],
                  let fh = (u["fh"] as? NSNumber)?.doubleValue else { return nil }
            return Sample(t: t, session: fh, weekly: (u["sd"] as? NSNumber)?.doubleValue)
        }.sorted { $0.t < $1.t }
    }

    static func desktop() -> Usage? {
        let samples = desktopSamples()
        guard let last = samples.last, -last.t.timeIntervalSinceNow < 86400 else { return nil }
        var u = Usage(session: last.session, weekly: last.weekly, asOf: last.t, source: "Claude app")
        // The file has no reset times. Estimate the 5h window: it starts on the
        // first request after the previous window expired, i.e. the sample where
        // usage went 0 → >0. Only trust it if the window hasn't already ended.
        if last.session > 0 {
            var start: Date?
            for (i, s) in samples.enumerated().reversed() where i > 0 {
                if samples[i - 1].session == 0 && s.session > 0 { start = samples[i - 1].t; break }
                if s.session == 0 { break }
            }
            if let st = start, st.addingTimeInterval(5 * 3600) > Date() {
                u.sessionReset = st.addingTimeInterval(5 * 3600)
                u.resetIsEstimate = true
            }
        }
        return u
    }

    /// Written by usagebar_statusline.py from Claude Code's status line payload.
    static func statusline() -> Usage? {
        guard let d = readJSON(feed) as? [String: Any], let ts = parseDate(d["ts"]),
              -ts.timeIntervalSinceNow < 86400,
              let s = (d["session"] as? NSNumber)?.doubleValue else { return nil }
        var u = Usage(session: s, weekly: (d["weekly"] as? NSNumber)?.doubleValue,
                      sessionReset: parseDate(d["session_reset"]),
                      weeklyReset: parseDate(d["weekly_reset"]), asOf: ts, source: "status line")
        let now = Date()
        if let r = u.sessionReset, r < now { u.session = 0; u.sessionReset = nil }
        if let r = u.weeklyReset, r < now { u.weekly = 0; u.weeklyReset = nil }
        return u
    }

    // OAuth fallback — only used when neither local source exists.
    static let kcService = "Claude Code-credentials"
    static var apiCooldownUntil = Date.distantPast

    static func credentials() -> (token: String, expires: Date?)? {
        var candidates = [kcService]
        if let json = readJSON(home + "/.claude/.credentials.json") as? [String: Any],
           let o = json["claudeAiOauth"] as? [String: Any],
           let t = o["accessToken"] as? String, !t.isEmpty {
            return (t, parseDate(o["expiresAt"]))
        }
        // Newer Claude Code versions use per-account entries with a hash suffix.
        if let dump = run("/usr/bin/security", ["dump-keychain"]) {
            let re = try! NSRegularExpression(pattern: "\"svce\"<blob>=\"(Claude Code-credentials[^\"]*)\"")
            for m in re.matches(in: dump, range: NSRange(dump.startIndex..., in: dump)) {
                if let r = Range(m.range(at: 1), in: dump) { candidates.append(String(dump[r])) }
            }
        }
        for svc in candidates {
            guard let out = run("/usr/bin/security", ["find-generic-password", "-s", svc, "-w"]),
                  let d = try? JSONSerialization.jsonObject(with: Data(out.trimmingCharacters(in: .whitespacesAndNewlines).utf8)) as? [String: Any],
                  let o = d["claudeAiOauth"] as? [String: Any],
                  let t = o["accessToken"] as? String, !t.isEmpty else { continue }
            return (t, parseDate(o["expiresAt"]))
        }
        return nil
    }

    static func api() -> Usage {
        var u = Usage(source: "API")
        guard Date() > apiCooldownUntil else { u.err = "rate-limited, retrying later"; return u }
        guard let cred = credentials() else {
            u.err = "No usage data yet — open the Claude app or a Claude Code session"; return u
        }
        if let e = cred.expires, e < Date() { u.err = "Claude token expired — open a Claude Code session"; return u }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer " + cred.token, forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("claude-cli/2.0.0 (external, cli)", forHTTPHeaderField: "User-Agent")
        let sem = DispatchSemaphore(value: 0)
        var result: (Data?, URLResponse?)
        URLSession.shared.dataTask(with: req) { d, r, _ in result = (d, r); sem.signal() }.resume()
        _ = sem.wait(timeout: .now() + 15)
        guard let http = result.1 as? HTTPURLResponse, let data = result.0 else { u.err = "network error"; return u }
        if http.statusCode == 429 { apiCooldownUntil = Date().addingTimeInterval(1800); u.err = "rate-limited, retrying later"; return u }
        guard http.statusCode == 200, let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            u.err = "HTTP \(http.statusCode)"; return u
        }
        for (k, v) in d {
            guard let o = v as? [String: Any], let util = (o["utilization"] as? NSNumber)?.doubleValue else { continue }
            let key = k.lowercased()
            if key.contains("five_hour") || key.contains("session") {
                u.session = util; u.sessionReset = parseDate(o["resets_at"])
            } else if key.contains("seven_day") && !key.contains("opus") {
                u.weekly = util; u.weeklyReset = parseDate(o["resets_at"])
            }
        }
        u.asOf = Date()
        return u
    }

    static func fetch() -> Usage {
        let local = [statusline(), desktop()].compactMap { $0 }
        if let best = local.max(by: { ($0.asOf ?? .distantPast) < ($1.asOf ?? .distantPast) }) {
            var u = best
            // Fill reset times from the other source if it has them and the window hasn't passed.
            if u.sessionReset == nil, let o = local.first(where: { $0.sessionReset != nil && $0.sessionReset! > Date() }) {
                u.sessionReset = o.sessionReset; u.resetIsEstimate = o.resetIsEstimate
            }
            if u.weeklyReset == nil, let o = local.first(where: { $0.weeklyReset != nil && $0.weeklyReset! > Date() }) {
                u.weeklyReset = o.weeklyReset
            }
            return u
        }
        return api()
    }
}

// MARK: - Codex source

enum CodexSource {
    static func fetch() -> Usage {
        var u = Usage(source: "Codex logs")
        let root = home + "/.codex/sessions"
        guard let e = FileManager.default.enumerator(atPath: root) else { u.err = "no sessions"; return u }
        var files: [(String, Date)] = []
        for case let p as String in e where p.hasSuffix(".jsonl") {
            let full = root + "/" + p
            let m = (try? FileManager.default.attributesOfItem(atPath: full)[.modificationDate] as? Date) ?? .distantPast
            files.append((full, m))
        }
        guard !files.isEmpty else { u.err = "no sessions"; return u }
        files.sort { $0.1 > $1.1 }
        for (f, mtime) in files.prefix(10) {
            guard let text = try? String(contentsOfFile: f, encoding: .utf8) else { continue }
            var found: [String: Any]?
            for line in text.split(separator: "\n") where line.contains("\"rate_limits\"") {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)), let rl = findRL(obj),
                      let p = rl["primary"] as? [String: Any], p["used_percent"] != nil else { continue }
                var rl2 = rl
                if let prev = found, !(rl["secondary"] is [String: Any]) { rl2["secondary"] = prev["secondary"] }
                found = rl2
            }
            if let rl = found {
                let p = rl["primary"] as? [String: Any] ?? [:], s = rl["secondary"] as? [String: Any] ?? [:]
                u.session = (p["used_percent"] as? NSNumber)?.doubleValue
                u.sessionReset = parseDate(p["resets_at"])
                u.weekly = (s["used_percent"] as? NSNumber)?.doubleValue
                u.weeklyReset = parseDate(s["resets_at"])
                u.asOf = mtime
                let now = Date()
                if let r = u.sessionReset, r < now { u.session = 0; u.sessionReset = nil }
                if let r = u.weeklyReset, r < now { u.weekly = 0; u.weeklyReset = nil }
                return u
            }
        }
        u.err = "no rate data"
        return u
    }

    static func findRL(_ o: Any) -> [String: Any]? {
        guard let d = o as? [String: Any] else { return nil }
        if let rl = d["rate_limits"] as? [String: Any] { return rl }
        for v in d.values { if let x = findRL(v) { return x } }
        return nil
    }
}

// MARK: - Views

final class UsageRowView: NSView {
    let titleLabel = NSTextField(labelWithString: "")
    let subLabel = NSTextField(labelWithString: "")
    let pctLabel = NSTextField(labelWithString: "")
    let track = NSView(), fill = NSView()
    var pct: Double?
    var onClick: (() -> Void)?

    init(title: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 52))
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.stringValue = title
        subLabel.font = .systemFont(ofSize: 10)
        subLabel.textColor = .secondaryLabelColor
        pctLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        pctLabel.alignment = .right
        track.wantsLayer = true; fill.wantsLayer = true
        track.layer?.cornerRadius = 3.5; fill.layer?.cornerRadius = 3.5
        for v in [titleLabel, subLabel, pctLabel, track] { addSubview(v) }
        track.addSubview(fill)
        toolTip = "Open usage page"
    }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseUp(with event: NSEvent) { onClick?() }

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
        let p = CGFloat(min(max(pct ?? 0, 0), 100)) / 100
        let target = NSRect(x: 0, y: 0, width: track.bounds.width * p, height: track.bounds.height)
        fill.layer?.backgroundColor = barColor(pct).cgColor
        if animated {
            fill.frame = NSRect(x: 0, y: 0, width: 0, height: track.bounds.height)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.6
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                fill.animator().frame = target
            }
        } else { fill.frame = target }
    }

    func update(pct: Double?, reset: Date?, estimate: Bool) {
        self.pct = pct
        if let p = pct {
            pctLabel.stringValue = Prefs.showUsed ? String(format: "%.0f%% used", p)
                                                  : String(format: "%.0f%% left", max(0, 100 - p))
            pctLabel.textColor = barColor(p)
            subLabel.stringValue = fmtReset(reset, estimate: estimate)
        } else {
            pctLabel.stringValue = "–"; pctLabel.textColor = .secondaryLabelColor
            subLabel.stringValue = "No data yet"
        }
        needsLayout = true
    }
}

final class HeaderView: NSView {
    let title = NSTextField(labelWithString: "")
    let meta = NSTextField(labelWithString: "")
    init(_ text: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 26))
        title.font = .systemFont(ofSize: 13, weight: .bold)
        title.stringValue = text
        title.frame = NSRect(x: 14, y: 4, width: 150, height: 18)
        meta.font = .systemFont(ofSize: 10)
        meta.textColor = .tertiaryLabelColor
        meta.alignment = .right
        meta.frame = NSRect(x: 150, y: 6, width: 136, height: 14)
        addSubview(title); addSubview(meta)
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class ErrView: NSView {
    let l = NSTextField(wrappingLabelWithString: "")
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 30))
        l.font = .systemFont(ofSize: 10)
        l.textColor = .systemOrange
        l.frame = NSRect(x: 14, y: 2, width: 272, height: 26)
        addSubview(l)
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// 24h sparkline of the 5-hour window usage from the Claude app's samples.
final class SparklineView: NSView {
    var samples: [Sample] = [] { didSet { needsDisplay = true } }
    init() { super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 44)) }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let inset = NSRect(x: 14, y: 6, width: bounds.width - 28, height: 26)
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        let pts = samples.filter { $0.t > cutoff }
        let label = NSAttributedString(string: "Last 24h · 5-hour window", attributes: [
            .font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.tertiaryLabelColor])
        label.draw(at: NSPoint(x: 14, y: bounds.height - 12))
        guard pts.count > 1 else { return }
        let path = NSBezierPath()
        let area = NSBezierPath()
        let span = Date().timeIntervalSince(cutoff)
        for (i, s) in pts.enumerated() {
            let x = inset.minX + inset.width * CGFloat(s.t.timeIntervalSince(cutoff) / span)
            let y = inset.minY + inset.height * CGFloat(min(100, max(0, s.session)) / 100)
            if i == 0 { path.move(to: NSPoint(x: x, y: y)); area.move(to: NSPoint(x: x, y: inset.minY)); area.line(to: NSPoint(x: x, y: y)) }
            else { path.line(to: NSPoint(x: x, y: y)); area.line(to: NSPoint(x: x, y: y)) }
            if i == pts.count - 1 { area.line(to: NSPoint(x: x, y: inset.minY)); area.close() }
        }
        let c = barColor(pts.last?.session)
        c.withAlphaComponent(0.15).setFill(); area.fill()
        c.setStroke(); path.lineWidth = 1.5; path.stroke()
    }
}

// MARK: - App

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    var usage: [Provider: Usage] = [:]
    var samples: [Sample] = []
    var menu = NSMenu()
    var refreshing = false

    var rows: [Provider: (session: UsageRowView, weekly: UsageRowView)] = [:]
    var headers: [Provider: HeaderView] = [:]
    var errs: [Provider: (view: ErrView, item: NSMenuItem)] = [:]
    var sparkline = SparklineView()
    var sparkItem = NSMenuItem()
    var usedItem = NSMenuItem(), notifyItem = NSMenuItem(), loginItem = NSMenuItem()
    var refreshMenu = NSMenu(), styleMenu = NSMenu(), providerMenu = NSMenu()

    // notification state: last known % per provider/window
    var lastPct: [String: Double] = [:]

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "⏳"
        buildMenu()
        UNUserNotificationCenter.current().delegate = self
        if Prefs.notify {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        refresh()
        restartTimer()
    }

    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler h: @escaping (UNNotificationPresentationOptions) -> Void) {
        h([.banner, .sound])
    }

    func restartTimer() {
        timer?.invalidate()
        if Prefs.interval > 0 {
            timer = Timer.scheduledTimer(withTimeInterval: Prefs.interval, repeats: true) { _ in self.refresh() }
        }
    }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        DispatchQueue.global().async {
            var new: [Provider: Usage] = [:]
            if Prefs.enabled(.claude) { new[.claude] = ClaudeSource.fetch() }
            if Prefs.enabled(.codex) { new[.codex] = CodexSource.fetch() }
            let s = ClaudeSource.desktopSamples()
            DispatchQueue.main.async {
                self.usage = new
                self.samples = s
                self.checkNotifications()
                self.updateUI(animated: false)
                self.refreshing = false
            }
        }
    }

    // MARK: notifications

    func checkNotifications() {
        guard Prefs.notify else { return }
        for (p, u) in usage {
            for (win, pct, reset) in [("5-hour", u.session, u.sessionReset), ("weekly", u.weekly, u.weeklyReset)] {
                guard let now = pct else { continue }
                let key = p.rawValue + win
                defer { lastPct[key] = now }
                guard let prev = lastPct[key] else { continue }
                for th in [80.0, 95.0] where prev < th && now >= th {
                    var body = String(format: "%.0f%% of your %@ limit used.", now, win)
                    if let r = reset { body += " Resets in \(fmtCountdown(r))." }
                    notify(title: "\(p.name) at \(Int(th))%", body: body, id: key + "\(Int(th))")
                }
                if prev >= 50 && now < 5 {
                    notify(title: "\(p.name) \(win) limit reset", body: "You're back to 100%.", id: key + "reset")
                }
            }
        }
    }

    func notify(title: String, body: String, id: String) {
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body; c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }

    // MARK: status item rendering

    func displayValue(_ u: Usage?) -> String {
        guard let p = u?.session else { return "–" }
        return String(format: "%.0f", Prefs.showUsed ? p : max(0, 100 - p))
    }

    var activeProviders: [Provider] { Provider.allCases.filter { Prefs.enabled($0) } }

    func renderStatus() {
        guard let button = statusItem.button else { return }
        button.image = nil
        button.attributedTitle = NSAttributedString(string: "")
        button.imagePosition = .imageOnly
        statusItem.length = NSStatusItem.variableLength
        switch Prefs.style {
        case .pill: renderPill(button)
        case .compact: renderCompact(button)
        case .dot: renderDot(button)
        }
    }

    /// Two-line pill drawn as an image: the button cell clips two-line titles.
    func renderPill(_ button: NSStatusBarButton) {
        let thickness = NSStatusBar.system.thickness
        let safeTop = NSScreen.main?.safeAreaInsets.top ?? 0
        let height = safeTop > thickness ? safeTop : thickness
        let gap: CGFloat = 2
        var size: CGFloat = 13
        var font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .heavy)
        while font.capHeight * 2 + gap > height - 5, size > 7 {
            size -= 0.5
            font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .heavy)
        }
        func line(_ p: Provider) -> NSAttributedString {
            let u = usage[p]
            let s = NSMutableAttributedString(string: p.glyph, attributes: [.font: font, .foregroundColor: NSColor.white])
            let tint = barColor(u?.session).blended(withFraction: 0.25, of: .white) ?? barColor(u?.session)
            s.append(NSAttributedString(string: displayValue(u), attributes: [.font: font, .foregroundColor: tint]))
            return s
        }
        let lines = activeProviders.map(line)
        guard !lines.isEmpty else { button.title = "UB"; return }
        let textHeight = font.capHeight * CGFloat(lines.count) + gap * CGFloat(lines.count - 1)
        let padX: CGFloat = 7
        let width = ceil((lines.map { $0.size().width }.max() ?? 0) + padX * 2)
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        let pill = NSBezierPath(roundedRect: NSRect(x: 0.5, y: 1, width: width - 1, height: height - 2), xRadius: 6, yRadius: 6)
        NSColor.black.withAlphaComponent(0.62).setFill(); pill.fill()
        NSColor.white.withAlphaComponent(0.35).setStroke(); pill.lineWidth = 1; pill.stroke()
        let bottom = (height - textHeight) / 2 - 1.5
        for (i, l) in lines.reversed().enumerated() {
            l.draw(at: NSPoint(x: padX, y: bottom + CGFloat(i) * (font.capHeight + gap) + font.descender))
        }
        image.unlockFocus()
        image.isTemplate = false
        button.image = image
        statusItem.length = width
    }

    /// `C89 X100` on one line, with a countdown when a window is nearly exhausted.
    func renderCompact(_ button: NSStatusBarButton) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let s = NSMutableAttributedString()
        for (i, p) in activeProviders.enumerated() {
            let u = usage[p]
            if i > 0 { s.append(NSAttributedString(string: " ", attributes: [.font: font])) }
            s.append(NSAttributedString(string: p.glyph, attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
            s.append(NSAttributedString(string: displayValue(u), attributes: [.font: font, .foregroundColor: barColor(u?.session)]))
            if let pct = u?.session, pct >= 80, let r = u?.sessionReset {
                s.append(NSAttributedString(string: "·" + fmtCountdown(r), attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                    .foregroundColor: NSColor.secondaryLabelColor]))
            }
        }
        button.imagePosition = .noImage
        button.attributedTitle = s
    }

    /// Sparkle glyph with a coloured dot for the worst window.
    func renderDot(_ button: NSStatusBarButton) {
        let worst = activeProviders.compactMap { usage[$0]?.session }.max()
        let image = NSImage(size: NSSize(width: 22, height: 18))
        image.lockFocus()
        let glyph = NSAttributedString(string: "✱", attributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor.labelColor])
        glyph.draw(at: NSPoint(x: 1, y: 0))
        barColor(worst).setFill()
        NSBezierPath(ovalIn: NSRect(x: 14, y: 11, width: 6, height: 6)).fill()
        image.unlockFocus()
        image.isTemplate = false
        button.image = image
        button.imagePosition = .imageOnly
    }

    func updateUI(animated: Bool) {
        renderStatus()
        for p in Provider.allCases {
            let u = usage[p]
            rows[p]?.session.update(pct: u?.session, reset: u?.sessionReset, estimate: u?.resetIsEstimate ?? false)
            rows[p]?.weekly.update(pct: u?.weekly, reset: u?.weeklyReset, estimate: false)
            var meta = ""
            if let u = u, let a = u.asOf { meta = (u.source.map { $0 + " · " } ?? "") + fmtAgo(a) }
            headers[p]?.meta.stringValue = meta
            errs[p]?.view.l.stringValue = u?.err.map { "⚠︎ \($0)" } ?? ""
            errs[p]?.item.isHidden = u?.err == nil
        }
        sparkline.samples = samples
        sparkItem.isHidden = !Prefs.enabled(.claude) || samples.count < 2
        if animated {
            for r in rows.values { r.session.layoutSubtreeIfNeeded(); r.session.layoutFill(animated: true)
                                   r.weekly.layoutSubtreeIfNeeded(); r.weekly.layoutFill(animated: true) }
        }
    }

    // MARK: menu

    func viewItem(_ v: NSView) -> NSMenuItem { let i = NSMenuItem(); i.view = v; return i }

    func buildMenu() {
        menu = NSMenu()
        menu.delegate = self
        menu.minimumWidth = 300
        for p in Provider.allCases {
            let h = HeaderView(p.name); headers[p] = h
            let s = UsageRowView(title: "Current session")
            let w = UsageRowView(title: p == .claude ? "Weekly · all models" : "Weekly")
            for r in [s, w] { r.onClick = { NSWorkspace.shared.open(p.usageURL) } }
            rows[p] = (s, w)
            let e = ErrView(); let ei = viewItem(e); errs[p] = (e, ei)
            let items = [viewItem(h), viewItem(s), viewItem(w), ei]
            if p == .claude { sparkItem = viewItem(sparkline); items.forEach { menu.addItem($0) }; menu.addItem(sparkItem) }
            else { items.forEach { menu.addItem($0) } }
            menu.addItem(.separator())
            // hide whole section when provider is off
            items.forEach { $0.isHidden = !Prefs.enabled(p) }
        }

        usedItem = NSMenuItem(title: "Show Used Instead of Remaining", action: #selector(toggleUsed), keyEquivalent: "")
        usedItem.target = self
        usedItem.state = Prefs.showUsed ? .on : .off
        menu.addItem(usedItem)

        styleMenu = NSMenu()
        for st in MenuStyle.allCases {
            let it = NSMenuItem(title: st.title, action: #selector(setStyle(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = st.rawValue
            styleMenu.addItem(it)
        }
        let styleRoot = NSMenuItem(title: "Menu Bar Style", action: nil, keyEquivalent: "")
        styleRoot.submenu = styleMenu
        menu.addItem(styleRoot)

        providerMenu = NSMenu()
        for p in Provider.allCases {
            let it = NSMenuItem(title: p.name, action: #selector(toggleProvider(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = p.rawValue
            providerMenu.addItem(it)
        }
        let provRoot = NSMenuItem(title: "Providers", action: nil, keyEquivalent: "")
        provRoot.submenu = providerMenu
        menu.addItem(provRoot)

        refreshMenu = NSMenu()
        let opts: [(String, Double)] = [("10 sec", 10), ("30 sec", 30), ("1 min", 60), ("5 min", 300), ("Off", -1)]
        for (label, val) in opts {
            let it = NSMenuItem(title: label, action: #selector(setInterval(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = val
            refreshMenu.addItem(it)
        }
        let refreshRoot = NSMenuItem(title: "Auto Refresh", action: nil, keyEquivalent: "")
        refreshRoot.submenu = refreshMenu
        menu.addItem(refreshRoot)

        notifyItem = NSMenuItem(title: "Notify at 80% / 95% and on Reset", action: #selector(toggleNotify), keyEquivalent: "")
        notifyItem.target = self
        menu.addItem(notifyItem)

        loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)

        menu.addItem(.separator())
        let r = NSMenuItem(title: "Refresh Now", action: #selector(doRefresh), keyEquivalent: "r")
        r.target = self
        menu.addItem(r)
        menu.addItem(NSMenuItem(title: "Quit UsageBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        syncTicks()
    }

    func syncTicks() {
        for it in refreshMenu.items { it.state = (it.representedObject as? Double) == Prefs.interval ? .on : .off }
        for it in styleMenu.items { it.state = (it.representedObject as? String) == Prefs.style.rawValue ? .on : .off }
        for it in providerMenu.items {
            if let p = Provider(rawValue: it.representedObject as? String ?? "") { it.state = Prefs.enabled(p) ? .on : .off }
        }
        usedItem.state = Prefs.showUsed ? .on : .off
        notifyItem.state = Prefs.notify ? .on : .off
        if #available(macOS 13, *) {
            loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
            loginItem.isHidden = Bundle.main.bundleIdentifier == nil
        } else { loginItem.isHidden = true }
    }

    func menuWillOpen(_ m: NSMenu) {
        guard m == menu else { return }
        syncTicks()
        updateUI(animated: true)
        refresh()
    }

    @objc func setInterval(_ s: NSMenuItem) { Prefs.interval = s.representedObject as? Double ?? 30; restartTimer(); syncTicks() }
    @objc func setStyle(_ s: NSMenuItem) { Prefs.style = MenuStyle(rawValue: s.representedObject as? String ?? "") ?? .pill; syncTicks(); renderStatus() }
    @objc func toggleUsed() { Prefs.showUsed.toggle(); syncTicks(); updateUI(animated: false) }
    @objc func toggleNotify() {
        Prefs.notify.toggle(); syncTicks()
        if Prefs.notify { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in } }
    }
    @objc func toggleProvider(_ s: NSMenuItem) {
        guard let p = Provider(rawValue: s.representedObject as? String ?? "") else { return }
        if activeProviders.count == 1 && Prefs.enabled(p) { return }  // keep at least one
        Prefs.setEnabled(p, !Prefs.enabled(p))
        buildMenu()
        refresh()
    }
    @objc func toggleLogin() {
        guard #available(macOS 13, *) else { return }
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { NSLog("launch at login: \(error)") }
        syncTicks()
    }
    @objc func doRefresh() { refresh() }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
