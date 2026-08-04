// Claude Code usage — macOS menu bar item.
//
// Reads the per-session state files written by ~/.claude/statusline.sh into
// ~/.claude/usage/ and shows the account-wide rate limits in the menu bar.
// Rate limits are account-wide, so limits are aggregated across sessions;
// per-session cost is listed in the dropdown.
//
// Two display modes, switchable from the dropdown, stored in config.json:
//   text  ✻ 10% 22m  2% 3d 2h
//   bar   ▐▓▓░░░░▌ 10% 2%      one track, 5h and 7d stacked inside it
//
// Build:  swiftc -O ClaudeUsage.swift -o ClaudeUsage -framework AppKit
// Run:    ./ClaudeUsage                    menu bar item
//         ./ClaudeUsage --dump             print what it would render, then exit
//         ./ClaudeUsage --dump --mode bar  dump a specific mode
// See MENUBAR.md.

import AppKit

// MARK: - Model

struct Limit {
    let pct: Double
    let resetsAt: Double
}

struct SessionState {
    let sessionID: String
    let sessionName: String?
    let dir: String?
    let model: String?
    let effort: String?
    let fastMode: Bool
    let costUSD: Double
    let ctxPct: Double?
    let fiveHour: Limit?
    let sevenDay: Limit?
    let updatedAt: Double

    var age: TimeInterval { Date().timeIntervalSince1970 - updatedAt }

    init?(json: [String: Any]) {
        guard let sid = json["session_id"] as? String else { return nil }
        sessionID = sid
        sessionName = json["session_name"] as? String
        dir = json["dir"] as? String
        model = json["model"] as? String
        effort = json["effort"] as? String
        fastMode = json["fast_mode"] as? Bool ?? false
        costUSD = (json["cost_usd"] as? NSNumber)?.doubleValue ?? 0
        ctxPct = (json["ctx_pct"] as? NSNumber)?.doubleValue
        updatedAt = (json["updated_at"] as? NSNumber)?.doubleValue ?? 0
        fiveHour = SessionState.limit(json["five_hour"])
        sevenDay = SessionState.limit(json["seven_day"])
    }

    private static func limit(_ raw: Any?) -> Limit? {
        guard let d = raw as? [String: Any],
              let pct = (d["used_percentage"] as? NSNumber)?.doubleValue,
              let reset = (d["resets_at"] as? NSNumber)?.doubleValue
        else { return nil }
        return Limit(pct: pct, resetsAt: reset)
    }
}

// MARK: - Formatting

enum Fmt {
    /// Green below 50%, yellow below 80%, red at or above.
    static func color(_ pct: Double) -> NSColor {
        if pct >= 80 { return .systemRed }
        if pct >= 50 { return .systemYellow }
        return .systemGreen
    }

    static func pct(_ v: Double) -> String { "\(Int(v.rounded()))%" }

    /// Epoch seconds -> "3d 4h" / "1h48m" / "12m" / "now".
    static func until(_ epoch: Double) -> String {
        let diff = Int(epoch - Date().timeIntervalSince1970)
        if diff <= 0 { return "now" }
        let d = diff / 86400, h = (diff % 86400) / 3600, m = (diff % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return String(format: "%dh%02dm", h, m) }
        return "\(m)m"
    }

    static func ago(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86400 { return "\(s / 3600)h ago" }
        return "\(s / 86400)d ago"
    }

    static func money(_ v: Double) -> String { String(format: "$%.2f", v) }
}

// MARK: - Display mode, persisted in ~/.claude/menubar/config.json

enum DisplayMode: String {
    case text   // ✻ 10% 22m  2% 3d 2h
    case bar    // one track with both fills, then the percentages

    var label: String {
        switch self {
        case .text: return "Percent + reset time"
        case .bar: return "Progress bar"
        }
    }
}

enum Config {
    private static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/menubar/config.json")
    }

    /// Re-read on every refresh, so editing config.json by hand takes effect too.
    static func mode() -> DisplayMode {
        guard let data = try? Data(contentsOf: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let raw = json["display"] as? String,
              let mode = DisplayMode(rawValue: raw)
        else { return .text }
        return mode
    }

    static func setMode(_ mode: DisplayMode) {
        let json = ["display": mode.rawValue]
        guard let data = try? JSONSerialization.data(withJSONObject: json,
                                                    options: [.prettyPrinted]) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - State loading

final class StateStore {
    private let dir: URL

    init() {
        // CLAUDE_USAGE_DIR overrides the location; used for testing with fixtures.
        if let override = ProcessInfo.processInfo.environment["CLAUDE_USAGE_DIR"], !override.isEmpty {
            dir = URL(fileURLWithPath: override)
        } else {
            dir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/usage")
        }
    }

    /// Sessions that reported within the last 24h, newest first.
    func load() -> [SessionState] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return [] }

        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> SessionState? in
                guard let data = try? Data(contentsOf: url),
                      let obj = try? JSONSerialization.jsonObject(with: data),
                      let json = obj as? [String: Any]
                else { return nil }
                return SessionState(json: json)
            }
            .filter { $0.age < 86_400 }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
}

// MARK: - Snapshot

/// Rate limits are account-wide, but each session only knows what it saw on its
/// own last API response — an idle session can keep reporting an expired window.
/// So limits are aggregated across sessions instead of taken from just one.
struct Snapshot {
    let sessions: [SessionState]
    let fiveHour: Limit?
    let sevenDay: Limit?

    var newest: SessionState? { sessions.first }

    /// True once the data is old enough that the numbers should not be trusted.
    var stale: Bool {
        guard let newest else { return true }
        return newest.age >= Render.staleAfter
    }

    /// Limits worth showing in the menu bar: present, and not stale.
    var displayable: (five: Limit?, seven: Limit?) {
        stale ? (nil, nil) : (fiveHour, sevenDay)
    }

    init(sessions: [SessionState]) {
        self.sessions = sessions
        fiveHour = Snapshot.best(sessions.compactMap(\.fiveHour))
        sevenDay = Snapshot.best(sessions.compactMap(\.sevenDay))
    }

    /// Windows roll forward, and within one window utilization only grows — so the
    /// latest observation is the largest (resetsAt, pct). Expired windows are dropped:
    /// usage has reset to an unknown value, and reporting the old number would lie.
    private static func best(_ limits: [Limit]) -> Limit? {
        let now = Date().timeIntervalSince1970
        return limits
            .filter { $0.resetsAt > now }
            .max { ($0.resetsAt, $0.pct) < ($1.resetsAt, $1.pct) }
    }
}

// MARK: - Render — what to show, independent of AppKit plumbing

enum Row {
    case header(String)
    case info(String)
    case limit(String, Limit?)
}

enum Render {
    /// Limits are stale-but-roughly-valid for a while after the last update.
    static let staleAfter: TimeInterval = 6 * 3600

    static let fiveHourColor = NSColor.systemBlue
    static let sevenDayColor = NSColor.systemPurple

    /// Text mode: "✻ 10% 22m  2% 3d 2h" — percent then time-to-reset, 5h pair then 7d pair.
    static func textParts(_ snap: Snapshot) -> [(String, NSColor)] {
        var parts: [(String, NSColor)] = [("✻ ", .tertiaryLabelColor)]
        let (five, seven) = snap.displayable

        guard five != nil || seven != nil else {
            parts.append(("—", .tertiaryLabelColor))
            return parts
        }

        var first = true
        for limit in [five, seven] {
            guard let limit else { continue }
            if !first { parts.append(("  ", .labelColor)) }
            first = false
            parts.append((Fmt.pct(limit.pct), Fmt.color(limit.pct)))
            parts.append((" " + Fmt.until(limit.resetsAt), .secondaryLabelColor))
        }
        return parts
    }

    /// Bar mode: the percentages that follow the bar image, "10% 2%".
    static func barParts(_ snap: Snapshot) -> [(String, NSColor)] {
        let (five, seven) = snap.displayable
        guard five != nil || seven != nil else { return [(" —", .tertiaryLabelColor)] }

        var parts: [(String, NSColor)] = []
        for (limit, identity) in [(five, fiveHourColor), (seven, sevenDayColor)] {
            guard let limit else { continue }
            parts.append((" ", .labelColor))
            // Threshold color once it matters; identity color otherwise, so the
            // number stays tied to its fill in the bar.
            parts.append((Fmt.pct(limit.pct), limit.pct >= 50 ? Fmt.color(limit.pct) : identity))
        }
        return parts
    }

    /// Dropdown contents, above the Display/Refresh/Quit items.
    static func rows(_ snap: Snapshot) -> [Row] {
        let sessions = snap.sessions
        guard let s = snap.newest else {
            return [.info("No active Claude Code session"),
                    .info("Limits appear once a session reports.")]
        }

        var rows: [Row] = []

        var modelLine = s.model ?? "?"
        if let e = s.effort { modelLine += " · \(e) effort" }
        if s.fastMode { modelLine += " · fast" }
        rows.append(.header("Model"))
        rows.append(.info(modelLine))

        rows.append(.header("Usage limits"))
        rows.append(.limit("5-hour session", snap.fiveHour))
        rows.append(.limit("7-day, all models", snap.sevenDay))
        if snap.stale {
            rows.append(.info("⚠︎ last reported \(Fmt.ago(s.age)) — may be out of date"))
        }

        rows.append(.header(sessions.count == 1 ? "Session" : "Sessions (\(sessions.count))"))
        for session in sessions.prefix(6) {
            let name = session.sessionName
                ?? session.dir.map { ($0 as NSString).lastPathComponent }
                ?? session.sessionID
            var line = "\(Fmt.money(session.costUSD))   \(name)"
            if let ctx = session.ctxPct { line += "   ctx \(Fmt.pct(ctx))" }
            rows.append(.info(line))
        }
        if sessions.count > 1 {
            let total = sessions.reduce(0) { $0 + $1.costUSD }
            rows.append(.info("\(Fmt.money(total))   total"))
        }

        rows.append(.info("Updated \(Fmt.ago(s.age))"))
        return rows
    }

    static func limitText(_ label: String, _ limit: Limit?) -> String {
        guard let limit else { return "\(label)   —   window rolled over, no data yet" }
        return "\(label)   \(Fmt.pct(limit.pct))   resets in \(Fmt.until(limit.resetsAt))"
    }

    /// One rounded track holding both fills as stacked rows: 5h on top, 7d below.
    /// Stacked rather than layered because a smaller value drawn behind a larger one
    /// would be completely hidden (7d at 2% sits inside 5h at 10%).
    static func barImage(five: Limit?, seven: Limit?) -> NSImage {
        let size = NSSize(width: 40, height: 10)
        let image = NSImage(size: size, flipped: false) { rect in
            // labelColor adapts: white on a dark menu bar, black on a light one.
            let track = rect.insetBy(dx: 0.5, dy: 0.5)
            let trackPath = NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2)
            NSColor.labelColor.withAlphaComponent(0.14).setFill()
            trackPath.fill()

            // Clipping to the track means the fills inherit its rounded left edge
            // while staying square-cut on the right — reads as a progress bar, and a
            // 2% sliver stays a thin tick instead of becoming a dot.
            NSGraphicsContext.saveGraphicsState()
            trackPath.addClip()

            let inner = track.insetBy(dx: 1, dy: 1)
            let gap: CGFloat = 1
            let rowHeight = (inner.height - gap) / 2

            func fill(_ limit: Limit?, y: CGFloat, color: NSColor) {
                guard let limit, limit.pct > 0 else { return }
                let frac = min(max(limit.pct / 100, 0), 1)
                let width = max(inner.width * frac, 2)   // keep tiny values visible
                color.setFill()
                NSRect(x: inner.minX, y: y, width: width, height: rowHeight).fill()
            }

            fill(five, y: inner.minY + rowHeight + gap, color: fiveHourColor)  // top
            fill(seven, y: inner.minY, color: sevenDayColor)                   // bottom

            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        image.isTemplate = false   // keep the two identity colors
        return image
    }

    /// ASCII stand-in for the bar, so --dump can verify the fills without a screen.
    static func barASCII(_ limit: Limit?, cells: Int = 10) -> String {
        guard let limit else { return String(repeating: "·", count: cells) }
        let filled = Int((limit.pct / 100 * Double(cells)).rounded(.up))
        return String(repeating: "█", count: min(filled, cells))
            + String(repeating: "░", count: max(cells - filled, 0))
    }
}

// MARK: - Menu bar controller

final class Controller: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let store = StateStore()
    private let menu = NSMenu()
    private var timer: Timer?

    private let mono = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)

    override init() {
        super.init()
        menu.delegate = self
        item.menu = menu
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func menuWillOpen(_ menu: NSMenu) { refresh() }

    @objc private func refresh() {
        let snap = Snapshot(sessions: store.load())
        let mode = Config.mode()
        guard let button = item.button else { return }

        switch mode {
        case .text:
            button.image = nil
            button.attributedTitle = attributed(Render.textParts(snap))
        case .bar:
            let (five, seven) = snap.displayable
            button.image = Render.barImage(five: five, seven: seven)
            button.imagePosition = .imageLeading
            button.attributedTitle = attributed(Render.barParts(snap))
        }

        rebuildMenu(Render.rows(snap), mode: mode)
    }

    private func attributed(_ parts: [(String, NSColor)]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (text, color) in parts {
            out.append(NSAttributedString(string: text,
                                          attributes: [.font: mono, .foregroundColor: color]))
        }
        return out
    }

    private func rebuildMenu(_ rows: [Row], mode: DisplayMode) {
        menu.removeAllItems()

        for row in rows {
            switch row {
            case .header(let text):
                addDisabled(NSAttributedString(string: text.uppercased(), attributes: [
                    .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                    .foregroundColor: NSColor.tertiaryLabelColor,
                ]))

            case .info(let text):
                addDisabled(NSAttributedString(string: text, attributes: [
                    .font: mono, .foregroundColor: NSColor.labelColor,
                ]))

            case .limit(let label, let limit):
                let text = Render.limitText(label, limit)
                let attr = NSMutableAttributedString(string: text, attributes: [
                    .font: mono, .foregroundColor: NSColor.labelColor,
                ])
                if let limit, let r = text.range(of: Fmt.pct(limit.pct)) {
                    attr.addAttribute(.foregroundColor, value: Fmt.color(limit.pct),
                                      range: NSRange(r, in: text))
                }
                addDisabled(attr)
            }
        }

        menu.addItem(.separator())

        // Display mode switch
        addDisabled(NSAttributedString(string: "DISPLAY", attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]))
        for candidate in [DisplayMode.text, .bar] {
            let mi = NSMenuItem(title: candidate.label,
                                action: #selector(pickMode(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = candidate.rawValue
            mi.state = (candidate == mode) ? .on : .off
            menu.addItem(mi)
        }

        menu.addItem(.separator())
        addAction("Refresh Now", #selector(refresh))
        addAction("Quit", #selector(quit))
    }

    @objc private func pickMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = DisplayMode(rawValue: raw) else { return }
        Config.setMode(mode)
        refresh()
    }

    private func addDisabled(_ attr: NSAttributedString) {
        let mi = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        mi.attributedTitle = attr
        mi.isEnabled = false
        menu.addItem(mi)
    }

    private func addAction(_ title: String, _ selector: Selector) {
        let mi = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        mi.target = self
        menu.addItem(mi)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

// MARK: - Entry point

/// --png <path> [--pct 5h,7d] renders the bar to a magnified PNG on a menu-bar-like
/// backdrop, so the drawing can be inspected without a screenshot.
if let i = CommandLine.arguments.firstIndex(of: "--png"), i + 1 < CommandLine.arguments.count {
    let path = CommandLine.arguments[i + 1]
    var five: Limit?, seven: Limit?

    if let j = CommandLine.arguments.firstIndex(of: "--pct"), j + 1 < CommandLine.arguments.count {
        let vals = CommandLine.arguments[j + 1].split(separator: ",").compactMap { Double($0) }
        let soon = Date().timeIntervalSince1970 + 3600
        if vals.count > 0 { five = Limit(pct: vals[0], resetsAt: soon) }
        if vals.count > 1 { seven = Limit(pct: vals[1], resetsAt: soon) }
    } else {
        (five, seven) = Snapshot(sessions: StateStore().load()).displayable
    }

    let render = {
        let bar = Render.barImage(five: five, seven: seven)
        let scale: CGFloat = 12, pad: CGFloat = 24
        let canvas = NSImage(size: NSSize(width: bar.size.width * scale + pad * 2,
                                         height: bar.size.height * scale + pad * 2),
                             flipped: false) { rect in
            NSColor(calibratedWhite: 0.13, alpha: 1).setFill()   // menu bar backdrop
            rect.fill()
            NSGraphicsContext.current?.imageInterpolation = .none
            bar.draw(in: NSRect(x: pad, y: pad,
                                width: bar.size.width * scale,
                                height: bar.size.height * scale))
            return true
        }
        guard let tiff = canvas.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }

    // Draw as the dark menu bar would, not in default light appearance.
    if let dark = NSAppearance(named: .darkAqua) {
        dark.performAsCurrentDrawingAppearance(render)
    } else {
        render()
    }
    print("wrote \(path)  (5h=\(five.map { Fmt.pct($0.pct) } ?? "—") 7d=\(seven.map { Fmt.pct($0.pct) } ?? "—"))")
    exit(0)
}

if CommandLine.arguments.contains("--dump") {
    // Headless: render to stdout so the data path can be checked without the GUI.
    let snap = Snapshot(sessions: StateStore().load())
    var mode = Config.mode()
    if let i = CommandLine.arguments.firstIndex(of: "--mode"),
       i + 1 < CommandLine.arguments.count,
       let m = DisplayMode(rawValue: CommandLine.arguments[i + 1]) {
        mode = m
    }

    print("mode: \(mode.rawValue)")
    switch mode {
    case .text:
        print("menu bar: [\(Render.textParts(snap).map(\.0).joined())]")
    case .bar:
        let (five, seven) = snap.displayable
        let nums = Render.barParts(snap).map(\.0).joined()
        print("menu bar: [▐\(Render.barASCII(five))▌\(nums)]   (top row = 5h)")
        print("          [▐\(Render.barASCII(seven))▌]         (bottom row = 7d)")
    }

    print("dropdown:")
    for row in Render.rows(snap) {
        switch row {
        case .header(let t): print("  \(t.uppercased())")
        case .info(let t): print("    \(t)")
        case .limit(let l, let v): print("    \(Render.limitText(l, v))")
        }
    }
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // menu bar only: no Dock icon, no window
let controller = Controller()
app.run()
