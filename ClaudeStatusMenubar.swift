import Cocoa

let APP_VERSION = "2.1.3"
let SWIFT_SOURCE_URL = "https://raw.githubusercontent.com/adversarydsgn/claude-status/main/ClaudeStatusMenubar.swift"

// MARK: - Self-Updater

class SelfUpdater {
    static func checkAndUpdate() {
        DispatchQueue.global(qos: .utility).async {
            guard let url = URL(string: SWIFT_SOURCE_URL) else { return }
            var request = URLRequest(url: url)
            request.timeoutInterval = 10

            guard let data = try? Data(contentsOf: url),
                  let source = String(data: data, encoding: .utf8)
            else { return }

            guard let range = source.range(of: #"let APP_VERSION = "([^"]+)""#, options: .regularExpression),
                  let versionRange = source.range(of: #""([^"]+)""#, options: .regularExpression, range: range)
            else { return }

            let remoteVersion = String(source[versionRange]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            guard remoteVersion != APP_VERSION else { return }

            let appBundle = Bundle.main.bundlePath
            let execPath = appBundle + "/Contents/MacOS/ClaudeStatusMenubar"
            let tmpSource = NSTemporaryDirectory() + "ClaudeStatusMenubar.swift"
            let tmpBinary = NSTemporaryDirectory() + "ClaudeStatusMenubar_new"

            try? source.write(toFile: tmpSource, atomically: true, encoding: .utf8)

            let compile = Process()
            compile.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
            compile.arguments = ["-O", "-o", tmpBinary, "-framework", "Cocoa", "-framework", "Foundation", tmpSource]
            compile.standardOutput = FileHandle.nullDevice
            compile.standardError = FileHandle.nullDevice
            do { try compile.run(); compile.waitUntilExit() } catch { return }
            guard compile.terminationStatus == 0 else { return }

            do {
                try FileManager.default.removeItem(atPath: execPath)
                try FileManager.default.moveItem(atPath: tmpBinary, toPath: execPath)
                let chmod = Process()
                chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
                chmod.arguments = ["+x", execPath]
                try chmod.run(); chmod.waitUntilExit()
                DispatchQueue.main.async {
                    let task = Process()
                    task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                    task.arguments = ["-a", appBundle]
                    try? task.run()
                    NSApp.terminate(nil)
                }
            } catch { return }
            try? FileManager.default.removeItem(atPath: tmpSource)
        }
    }
}

// MARK: - Status Types

struct ComponentStatus {
    let name: String
    let status: String
    var shortName: String {
        if name.contains("formerly") { return "platform.claude.com" }
        if name.contains("api.anthropic") { return "Claude API" }
        return name
    }
}

struct StatusResponse {
    let overall: String
    let description: String
    let components: [ComponentStatus]
    let updatedAt: String
}

// MARK: - Uptime Fetcher

class UptimeFetcher {
    static let shared = UptimeFetcher()
    private var uptimeData: [String: [Double]] = [:]
    var onDataUpdated: (() -> Void)?
    private var uptimeTimer: Timer?

    func startFetching() {
        doFetch()
        if uptimeTimer == nil {
            uptimeTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
                self?.doFetch()
            }
        }
    }

    func refresh() { doFetch() }

    private func doFetch() {
        guard let url = URL(string: "https://status.claude.com/") else { return }
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 15
        // Browser UA required — statuspage.io serves a JS shell to non-browser agents
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let data = data, let html = String(data: data, encoding: .utf8) else { return }
            self?.parse(html)
        }.resume()
    }

    private func parse(_ html: String) {
        // Match the Python CI logic: find "uptimeData" then the next {
        guard let keyRange = html.range(of: "uptimeData") else { return }
        let rest = html[keyRange.upperBound...]
        guard let braceIdx = rest.firstIndex(of: "{") else { return }
        let fromBrace = rest[braceIdx...]

        var depth = 0
        var endIdx = fromBrace.startIndex
        for i in fromBrace.indices {
            if fromBrace[i] == "{" { depth += 1 }
            else if fromBrace[i] == "}" {
                depth -= 1
                if depth == 0 { endIdx = i; break }
            }
        }
        guard depth == 0,
              let jsonData = String(fromBrace[fromBrace.startIndex...endIdx]).data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        else { return }

        var result: [String: [Double]] = [:]
        for (_, value) in dict {
            guard let compDict = value as? [String: Any],
                  let component = compDict["component"] as? [String: Any],
                  let name = component["name"] as? String,
                  let days = compDict["days"] as? [[String: Any]]
            else { continue }
            let scores: [Double] = days.map { day in
                let outages = day["outages"] as? [String: Any] ?? [:]
                let outSecs = outages.values.reduce(0.0) { acc, v in
                    if let d = v as? Double { return acc + d }
                    if let i = v as? Int { return acc + Double(i) }
                    return acc
                }
                return max(0, min(100, (86400.0 - outSecs) / 86400.0 * 100.0))
            }
            if !scores.isEmpty { result[name] = scores }
        }

        DispatchQueue.main.async {
            self.uptimeData = result
            self.onDataUpdated?()
        }
    }

    func scores(for shortName: String) -> [Double]? {
        for (name, scores) in uptimeData {
            let lo = name.lowercased()
            let match: Bool
            switch shortName {
            case "platform.claude.com": match = lo.contains("formerly") || lo.contains("platform")
            case "Claude API":          match = lo.contains("api")
            default:                   match = name == shortName || lo.contains(shortName.lowercased())
            }
            if match { return Array(scores.suffix(90)) }
        }
        return nil
    }

    func average(for shortName: String) -> Double? {
        guard let s = scores(for: shortName), !s.isEmpty else { return nil }
        return s.reduce(0, +) / Double(s.count)
    }

    func barImage(for shortName: String, availableWidth: CGFloat = 240) -> NSImage? {
        guard let s = scores(for: shortName), !s.isEmpty else { return nil }
        let count = s.count
        let gap: CGFloat = 0.5
        let totalGaps = CGFloat(max(count - 1, 0)) * gap
        let barW = max(1.5, (availableWidth - totalGaps) / CGFloat(count))
        let actualW = CGFloat(count) * barW + totalGaps
        let h: CGFloat = 12
        return NSImage(size: NSSize(width: actualW, height: h), flipped: false) { _ in
            for (i, score) in s.enumerated() {
                let x = CGFloat(i) * (barW + gap)
                self.color(for: score).setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: 0, width: barW, height: h), xRadius: 0.5, yRadius: 0.5).fill()
            }
            return true
        }
    }

    func color(for score: Double) -> NSColor {
        if score >= 100 { return NSColor(calibratedRed: 0.46, green: 0.68, blue: 0.16, alpha: 1) }
        if score >= 99  { return NSColor(calibratedRed: 0.62, green: 0.78, blue: 0.26, alpha: 1) }
        if score >= 95  { return NSColor(calibratedRed: 0.98, green: 0.65, blue: 0.17, alpha: 1) }
        if score >= 90  { return NSColor(calibratedRed: 0.91, green: 0.38, blue: 0.21, alpha: 1) }
        return NSColor(calibratedRed: 0.88, green: 0.26, blue: 0.26, alpha: 1)
    }
}

// MARK: - Status Fetcher

class StatusFetcher {
    static let apiURL = URL(string: "https://status.claude.com/api/v2/summary.json")!

    static func fetch(completion: @escaping (StatusResponse?) -> Void) {
        var request = URLRequest(url: apiURL)
        request.setValue("claude-status-menubar/\(APP_VERSION)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10
        URLSession.shared.dataTask(with: request) { data, _, error in
            guard let data = data, error == nil,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let status = json["status"] as? [String: String],
                  let components = json["components"] as? [[String: Any]],
                  let page = json["page"] as? [String: Any]
            else { completion(nil); return }
            let comps = components.compactMap { comp -> ComponentStatus? in
                guard let name = comp["name"] as? String, let st = comp["status"] as? String else { return nil }
                return ComponentStatus(name: name, status: st)
            }
            let updatedAt = (page["updated_at"] as? String ?? "").prefix(19).replacingOccurrences(of: "T", with: " ")
            completion(StatusResponse(overall: status["indicator"] ?? "unknown",
                                      description: status["description"] ?? "Unknown",
                                      components: comps,
                                      updatedAt: String(updatedAt)))
        }.resume()
    }
}

// MARK: - Preferences

class Preferences {
    static let shared = Preferences()
    private let defaults = UserDefaults.standard
    private let enabledKey = "enabledComponents"
    private let orderKey = "componentOrder"
    private let hideDisabledKey = "hideDisabledInMenu"

    private let defaultComponents = ["claude.ai", "platform.claude.com", "Claude API", "Claude Code", "Claude Cowork", "Claude for Government"]

    var enabledComponents: Set<String> {
        get {
            if let saved = defaults.stringArray(forKey: enabledKey) { return Set(saved) }
            return Set(defaultComponents)
        }
        set { defaults.set(Array(newValue), forKey: enabledKey) }
    }

    var componentOrder: [String] {
        get { defaults.stringArray(forKey: orderKey) ?? defaultComponents }
        set { defaults.set(newValue, forKey: orderKey) }
    }

    var hideDisabledInMenu: Bool {
        get { defaults.object(forKey: hideDisabledKey) as? Bool ?? false }
        set { defaults.set(newValue, forKey: hideDisabledKey) }
    }

    func isEnabled(_ name: String) -> Bool { enabledComponents.contains(name) }

    func toggle(_ name: String) {
        var current = enabledComponents
        if current.contains(name) {
            if current.count > 1 { current.remove(name) }
        } else {
            current.insert(name)
        }
        enabledComponents = current
    }

    func sorted(_ components: [ComponentStatus]) -> [ComponentStatus] {
        let order = componentOrder
        var result = order.compactMap { name in components.first { $0.shortName == name } }
        for comp in components where !order.contains(comp.shortName) { result.append(comp) }
        return result
    }

    func move(_ name: String, by offset: Int, in allNames: [String]) {
        var order = componentOrder
        for n in allNames where !order.contains(n) { order.append(n) }
        order = order.filter { allNames.contains($0) }
        guard let idx = order.firstIndex(of: name) else { return }
        let newIdx = max(0, min(order.count - 1, idx + offset))
        guard newIdx != idx else { return }
        order.remove(at: idx)
        order.insert(name, at: newIdx)
        componentOrder = order
    }
}

// MARK: - Service Row View

class ServiceRowView: NSView {
    let shortName: String
    private let statusEmoji: String
    private let statusLabel: String
    private var isServiceEnabled: Bool

    var toggleAction: (() -> Void)?
    var moveAction: ((Int) -> Void)?

    private var isHovered = false

    static let rowHeight: CGFloat = 22
    static let handleW: CGFloat = 30
    static let menuWidth: CGFloat = 310

    init(shortName: String, statusEmoji: String, statusLabel: String, isEnabled: Bool) {
        self.shortName = shortName
        self.statusEmoji = statusEmoji
        self.statusLabel = statusLabel
        self.isServiceEnabled = isEnabled
        super.init(frame: NSRect(x: 0, y: 0, width: ServiceRowView.menuWidth, height: ServiceRowView.rowHeight))
        let ta = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(ta)
    }
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered {
            NSColor.selectedMenuItemColor.setFill()
            bounds.fill()
        }

        let textColor: NSColor = isHovered
            ? (isServiceEnabled ? .white : NSColor.white.withAlphaComponent(0.6))
            : (isServiceEnabled ? .labelColor : .secondaryLabelColor)
        let dimColor: NSColor = isHovered ? NSColor.white.withAlphaComponent(0.55) : .quaternaryLabelColor

        // ▲▼ tap-to-reorder: top half = up, bottom half = down
        let arrowAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .medium),
            .foregroundColor: dimColor
        ]
        let upStr = NSAttributedString(string: "▲", attributes: arrowAttrs)
        let dnStr = NSAttributedString(string: "▼", attributes: arrowAttrs)
        let ax = (ServiceRowView.handleW - upStr.size().width) / 2
        upStr.draw(at: NSPoint(x: ax, y: bounds.midY + 1))
        dnStr.draw(at: NSPoint(x: ax, y: bounds.midY - dnStr.size().height - 0))

        // Status + name
        let title = "\(statusEmoji)  \(shortName) — \(statusLabel)"
        let titleAS = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: textColor
        ])
        let ty = (bounds.height - titleAS.size().height) / 2
        titleAS.draw(at: NSPoint(x: ServiceRowView.handleW + 2, y: ty))

        // Checkmark if enabled
        if isServiceEnabled {
            let checkColor: NSColor = isHovered ? NSColor.white.withAlphaComponent(0.7) : .tertiaryLabelColor
            let ck = NSAttributedString(string: "✓", attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: checkColor
            ])
            ck.draw(at: NSPoint(x: bounds.width - ck.size().width - 14, y: ty))
        }
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        if loc.x < ServiceRowView.handleW {
            // Top half = move up (-1), bottom half = move down (+1)
            let offset = loc.y >= bounds.midY ? -1 : 1
            moveAction?(offset)
        } else {
            isServiceEnabled.toggle()
            needsDisplay = true
            toggleAction?()
        }
    }
}

// MARK: - Uptime Row View

class UptimeRowView: NSView {
    private let shortName: String
    static let rowHeight: CGFloat = 22

    init(shortName: String) {
        self.shortName = shortName
        super.init(frame: NSRect(x: 0, y: 0, width: ServiceRowView.menuWidth, height: UptimeRowView.rowHeight))
    }
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let indent: CGFloat = ServiceRowView.handleW + 2
        let uptime = UptimeFetcher.shared

        if let img = uptime.barImage(for: shortName, availableWidth: 200) {
            let imgY = (bounds.height - img.size.height) / 2
            img.draw(in: NSRect(x: indent, y: imgY, width: img.size.width, height: img.size.height))

            if let avg = uptime.average(for: shortName) {
                let pctStr = String(format: "%.2f%% · 90d", avg)
                let pctAS = NSAttributedString(string: pctStr, attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                    .foregroundColor: NSColor.secondaryLabelColor
                ])
                let tx = indent + img.size.width + 8
                pctAS.draw(at: NSPoint(x: tx, y: (bounds.height - pctAS.size().height) / 2))
            }
        } else {
            let loadAS = NSAttributedString(string: "loading uptime...", attributes: [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.tertiaryLabelColor
            ])
            loadAS.draw(at: NSPoint(x: indent, y: (bounds.height - loadAS.size().height) / 2))
        }
    }

    // Absorb clicks — do not close menu
    override func mouseDown(with event: NSEvent) {}
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    var lastStatus: StatusResponse?
    var lastFetchTime: Date?

    let claudeOrange = NSColor(calibratedRed: 0.85, green: 0.47, blue: 0.34, alpha: 0.85)

    let dashboardPath: String = {
        let bundle = Bundle.main.bundlePath
        let relative = (bundle as NSString).deletingLastPathComponent + "/claude-status.sh"
        if FileManager.default.fileExists(atPath: relative) { return relative }
        let curl = NSHomeDirectory() + "/.claude-status/claude-status.sh"
        if FileManager.default.fileExists(atPath: curl) { return curl }
        return NSHomeDirectory() + "/Desktop/Claude Desktop/Claude Status Terminal/claude-status.sh"
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon()
        buildMenu()
        fetchAndUpdate()

        UptimeFetcher.shared.onDataUpdated = { [weak self] in self?.buildMenu() }
        UptimeFetcher.shared.startFetching()

        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.fetchAndUpdate()
        }
    }

    func fetchAndUpdate() {
        StatusFetcher.fetch { [weak self] response in
            DispatchQueue.main.async {
                self?.lastStatus = response
                self?.lastFetchTime = Date()
                self?.updateIcon()
                self?.buildMenu()
            }
        }
    }

    // MARK: - Icon

    func updateIcon() {
        let enabled = Preferences.shared.enabledComponents
        let allSorted = lastStatus.map { Preferences.shared.sorted($0.components) } ?? []
        // Only render dots for components that are both enabled AND have live status
        let components = allSorted.filter { enabled.contains($0.shortName) }
        let dotCount = components.count  // fixed: no phantom dark dots

        let dotRadius: CGFloat = 5.5
        let strokeW: CGFloat = 1.25
        let spacing: CGFloat = 3.0
        let padding: CGFloat = 3.0
        let totalW = padding * 2 + CGFloat(dotCount) * (dotRadius * 2) + CGFloat(max(dotCount - 1, 0)) * spacing
        let size = NSSize(width: max(totalW, 20), height: 18)

        let image = NSImage(size: size, flipped: false) { rect in
            let cy = rect.midY
            var x = padding + dotRadius
            for i in 0..<dotCount {
                let status: String? = i < components.count ? components[i].status : nil
                let dr = NSRect(x: x - dotRadius, y: cy - dotRadius, width: dotRadius * 2, height: dotRadius * 2)
                self.claudeOrange.setStroke()
                let path = NSBezierPath(ovalIn: dr.insetBy(dx: strokeW / 2, dy: strokeW / 2))
                path.lineWidth = strokeW
                path.stroke()
                self.colorForStatus(status).setFill()
                NSBezierPath(ovalIn: dr.insetBy(dx: strokeW, dy: strokeW)).fill()
                x += dotRadius * 2 + spacing
            }
            return true
        }
        image.isTemplate = false
        statusItem.button?.image = image
    }

    func colorForStatus(_ status: String?) -> NSColor {
        switch status {
        case "operational":          return NSColor(calibratedRed: 0.46, green: 0.68, blue: 0.16, alpha: 1)
        case "degraded_performance": return NSColor(calibratedRed: 0.98, green: 0.65, blue: 0.17, alpha: 1)
        case "partial_outage":       return NSColor(calibratedRed: 0.91, green: 0.38, blue: 0.21, alpha: 1)
        case "major_outage":         return NSColor(calibratedRed: 0.88, green: 0.26, blue: 0.26, alpha: 1)
        case "under_maintenance":    return NSColor(calibratedRed: 0.17, green: 0.52, blue: 0.86, alpha: 1)
        default:                     return NSColor.tertiaryLabelColor
        }
    }

    // MARK: - Menu

    func buildMenu() {
        let menu = NSMenu()
        let prefs = Preferences.shared

        // Header
        let headerTitle = lastStatus?.description ?? "Loading..."
        let headerItem = NSMenuItem(title: headerTitle, action: nil, keyEquivalent: "")
        headerItem.attributedTitle = NSAttributedString(string: headerTitle, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold)
        ])
        menu.addItem(headerItem)
        menu.addItem(NSMenuItem.separator())

        // Services section label
        let sectionItem = NSMenuItem(title: "SERVICES", action: nil, keyEquivalent: "")
        sectionItem.attributedTitle = NSAttributedString(string: "SERVICES", attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: NSColor.secondaryLabelColor
        ])
        menu.addItem(sectionItem)

        if let status = lastStatus {
            let allSorted = prefs.sorted(status.components)
            let allNames = allSorted.map { $0.shortName }
            let displayed = prefs.hideDisabledInMenu ? allSorted.filter { prefs.isEnabled($0.shortName) } : allSorted

            for comp in displayed {
                let enabled = prefs.isEnabled(comp.shortName)

                // Service row (custom view — stays open on interaction)
                let rowView = ServiceRowView(
                    shortName: comp.shortName,
                    statusEmoji: statusEmoji(comp.status),
                    statusLabel: statusLabel(comp.status),
                    isEnabled: enabled
                )

                rowView.toggleAction = { [weak self] in
                    guard let self = self else { return }
                    prefs.toggle(comp.shortName)
                    self.updateIcon()
                    // If hide-disabled is on and we just disabled something, rebuild
                    if prefs.hideDisabledInMenu && !prefs.isEnabled(comp.shortName) {
                        self.buildMenu()
                    }
                }

                rowView.moveAction = { [weak self] rowsToMove in
                    guard let self = self else { return }
                    prefs.move(comp.shortName, by: rowsToMove, in: allNames)
                    self.buildMenu()
                }

                let rowItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                rowItem.view = rowView
                menu.addItem(rowItem)

                // Uptime row (custom view — absorbs clicks, never closes menu)
                let uptimeView = UptimeRowView(shortName: comp.shortName)
                let uptimeItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                uptimeItem.view = uptimeView
                menu.addItem(uptimeItem)
            }
        } else {
            menu.addItem(NSMenuItem(title: "Fetching status...", action: nil, keyEquivalent: ""))
        }

        menu.addItem(NSMenuItem.separator())

        // Actions
        let dashItem = NSMenuItem(title: "Open Terminal Dashboard", action: #selector(openDashboard), keyEquivalent: "t")
        dashItem.target = self
        menu.addItem(dashItem)

        let browserItem = NSMenuItem(title: "Open status.claude.com", action: #selector(openBrowser), keyEquivalent: "b")
        browserItem.target = self
        menu.addItem(browserItem)

        menu.addItem(NSMenuItem.separator())

        // Hide Disabled toggle (above Refresh)
        let hideItem = NSMenuItem(title: "Hide Disabled from List", action: #selector(toggleHideDisabled), keyEquivalent: "")
        hideItem.target = self
        hideItem.state = Preferences.shared.hideDisabledInMenu ? .on : .off
        menu.addItem(hideItem)

        menu.addItem(NSMenuItem.separator())

        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        var infoLine = "v\(APP_VERSION)"
        if let ft = lastFetchTime {
            let fmt = DateFormatter(); fmt.dateFormat = "h:mm:ss a"
            infoLine += " · Updated \(fmt.string(from: ft))"
        }
        if let apiTime = lastStatus?.updatedAt, !apiTime.isEmpty {
            infoLine += "\nAPI: \(apiTime) UTC"
        }
        let infoItem = NSMenuItem(title: infoLine, action: nil, keyEquivalent: "")
        infoItem.attributedTitle = NSAttributedString(string: infoLine, attributes: [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.tertiaryLabelColor
        ])
        menu.addItem(infoItem)

        menu.addItem(NSMenuItem.separator())

        let flagItem = NSMenuItem(title: "🇺🇸 Made in America", action: nil, keyEquivalent: "")
        flagItem.attributedTitle = NSAttributedString(string: "🇺🇸 Made in America", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor
        ])
        menu.addItem(flagItem)

        let quitItem = NSMenuItem(title: "Quit Claude Status", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    func statusEmoji(_ status: String) -> String {
        switch status {
        case "operational":          return "🟢"
        case "degraded_performance": return "🟡"
        case "partial_outage":       return "🟠"
        case "major_outage":         return "🔴"
        case "under_maintenance":    return "🔵"
        default:                     return "⚪"
        }
    }

    func statusLabel(_ status: String) -> String {
        switch status {
        case "operational":          return "Operational"
        case "degraded_performance": return "Degraded"
        case "partial_outage":       return "Partial Outage"
        case "major_outage":         return "Major Outage"
        case "under_maintenance":    return "Maintenance"
        default:                     return "Unknown"
        }
    }

    // MARK: - Actions

    @objc func toggleHideDisabled() {
        Preferences.shared.hideDisabledInMenu.toggle()
        buildMenu()
    }

    @objc func openDashboard() {
        let script = "tell application \"Terminal\"\nactivate\ndo script \"\(dashboardPath)\"\nend tell"
        if let s = NSAppleScript(source: script) { s.executeAndReturnError(nil) }
    }

    @objc func openBrowser() {
        NSWorkspace.shared.open(URL(string: "https://status.claude.com")!)
    }

    @objc func refreshNow() {
        fetchAndUpdate()
        UptimeFetcher.shared.refresh()
        SelfUpdater.checkAndUpdate()
    }

    @objc func quit() { NSApp.terminate(nil) }
}

// MARK: - Main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
