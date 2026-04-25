import Cocoa

let APP_VERSION = "2.0.0"
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

            do {
                try compile.run()
                compile.waitUntilExit()
            } catch { return }

            guard compile.terminationStatus == 0 else { return }

            do {
                try FileManager.default.removeItem(atPath: execPath)
                try FileManager.default.moveItem(atPath: tmpBinary, toPath: execPath)

                let chmod = Process()
                chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
                chmod.arguments = ["+x", execPath]
                try chmod.run()
                chmod.waitUntilExit()

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
    private var timer: Timer?

    func startFetching() {
        fetchUptime()
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.fetchUptime()
        }
    }

    private func fetchUptime() {
        guard let url = URL(string: "https://status.claude.com/") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("claude-status-menubar/\(APP_VERSION)", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let data = data, error == nil,
                  let html = String(data: data, encoding: .utf8) else { return }
            self?.parseUptimeData(from: html)
        }.resume()
    }

    private func parseUptimeData(from html: String) {
        guard let startRange = html.range(of: "var uptimeData = ") ?? html.range(of: "uptimeData = ") else { return }
        let afterVar = html[startRange.upperBound...]

        guard let jsonStart = afterVar.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return }
        let jsonSubstring = afterVar[jsonStart...]

        let openChar: Character = jsonSubstring[jsonSubstring.startIndex] == "{" ? "{" : "["
        let closeChar: Character = openChar == "{" ? "}" : "]"

        var depth = 0
        var endIndex = jsonSubstring.startIndex
        for (idx, ch) in jsonSubstring.enumerated() {
            if ch == openChar { depth += 1 }
            else if ch == closeChar {
                depth -= 1
                if depth == 0 {
                    endIndex = jsonSubstring.index(jsonSubstring.startIndex, offsetBy: idx)
                    break
                }
            }
        }

        guard depth == 0,
              let jsonData = String(jsonSubstring[jsonSubstring.startIndex...endIndex]).data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: jsonData)
        else { return }

        var result: [String: [Double]] = [:]
        if let arr = parsed as? [[String: Any]] {
            for item in arr { parseComponentItem(item, into: &result) }
        } else if let dict = parsed as? [String: Any] {
            if let components = dict["components"] as? [[String: Any]] {
                for item in components { parseComponentItem(item, into: &result) }
            } else {
                parseComponentItem(dict, into: &result)
            }
        }

        DispatchQueue.main.async { self.uptimeData = result }
    }

    private func parseComponentItem(_ item: [String: Any], into result: inout [String: [Double]]) {
        guard let name = item["name"] as? String else { return }
        var scores: [Double] = []
        if let days = item["days"] as? [[String: Any]] {
            for day in days {
                if let score = day["uptime_score"] as? Double {
                    scores.append(score)
                } else if let score = day["uptime_score"] as? Int {
                    scores.append(Double(score))
                }
            }
        }
        if !scores.isEmpty { result[name] = scores }
        if let children = item["components"] as? [[String: Any]] {
            for child in children { parseComponentItem(child, into: &result) }
        }
    }

    func uptimeScores(for shortName: String) -> [Double]? {
        for (componentName, scores) in uptimeData {
            let lower = componentName.lowercased()
            let matched: Bool
            switch shortName {
            case "platform.claude.com":
                matched = lower.contains("formerly") || lower.contains("platform")
            case "Claude API":
                matched = lower.contains("api")
            default:
                matched = componentName == shortName || lower.contains(shortName.lowercased())
            }
            if matched { return Array(scores.suffix(90)) }
        }
        return nil
    }

    func buildUptimeImage(for shortName: String) -> NSImage? {
        guard let scores = uptimeScores(for: shortName), !scores.isEmpty else { return nil }
        let barW: CGFloat = 3.0
        let gap: CGFloat = 0.5
        let h: CGFloat = 14.0
        let count = scores.count
        let totalW = CGFloat(count) * barW + CGFloat(max(count - 1, 0)) * gap

        return NSImage(size: NSSize(width: totalW, height: h), flipped: false) { _ in
            for (i, score) in scores.enumerated() {
                let x = CGFloat(i) * (barW + gap)
                self.colorForUptime(score).setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: 1, width: barW, height: h - 2), xRadius: 0.5, yRadius: 0.5).fill()
            }
            return true
        }
    }

    func averageUptime(for shortName: String) -> Double? {
        guard let scores = uptimeScores(for: shortName), !scores.isEmpty else { return nil }
        return scores.reduce(0, +) / Double(scores.count)
    }

    func colorForUptime(_ score: Double) -> NSColor {
        if score >= 100.0 { return NSColor(calibratedRed: 0.46, green: 0.68, blue: 0.16, alpha: 1.0) }
        if score >= 99.0  { return NSColor(calibratedRed: 0.62, green: 0.78, blue: 0.26, alpha: 1.0) }
        if score >= 95.0  { return NSColor(calibratedRed: 0.98, green: 0.65, blue: 0.17, alpha: 1.0) }
        if score >= 90.0  { return NSColor(calibratedRed: 0.91, green: 0.38, blue: 0.21, alpha: 1.0) }
        return NSColor(calibratedRed: 0.88, green: 0.26, blue: 0.26, alpha: 1.0)
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
                guard let name = comp["name"] as? String,
                      let st = comp["status"] as? String else { return nil }
                return ComponentStatus(name: name, status: st)
            }

            let updatedAt = (page["updated_at"] as? String ?? "").prefix(19).replacingOccurrences(of: "T", with: " ")
            completion(StatusResponse(
                overall: status["indicator"] ?? "unknown",
                description: status["description"] ?? "Unknown",
                components: comps,
                updatedAt: String(updatedAt)
            ))
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
        var result: [ComponentStatus] = []
        for name in order {
            if let comp = components.first(where: { $0.shortName == name }) { result.append(comp) }
        }
        for comp in components where !order.contains(comp.shortName) { result.append(comp) }
        return result
    }

    func move(_ name: String, by offset: Int, in allNames: [String]) {
        var order = componentOrder
        for n in allNames where !order.contains(n) { order.append(n) }
        order = order.filter { allNames.contains($0) }
        guard let idx = order.firstIndex(of: name) else { return }
        let newIdx = idx + offset
        guard newIdx >= 0 && newIdx < order.count else { return }
        order.remove(at: idx)
        order.insert(name, at: newIdx)
        componentOrder = order
    }
}

// MARK: - Menu Bar App

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
        let curlPath = NSHomeDirectory() + "/.claude-status/claude-status.sh"
        if FileManager.default.fileExists(atPath: curlPath) { return curlPath }
        return NSHomeDirectory() + "/Desktop/Claude Desktop/Claude Status Terminal/claude-status.sh"
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon()
        buildMenu()
        fetchAndUpdate()
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

    // MARK: - Icon Rendering

    func updateIcon() {
        let enabled = Preferences.shared.enabledComponents
        let allSorted = lastStatus.map { Preferences.shared.sorted($0.components) } ?? []
        let components = allSorted.filter { enabled.contains($0.shortName) }
        let dotCount = max(components.count, enabled.count)

        let dotRadius: CGFloat = 5.5
        let strokeWidth: CGFloat = 1.25
        let spacing: CGFloat = 3.0
        let padding: CGFloat = 3.0
        let totalWidth = padding * 2 + CGFloat(dotCount) * (dotRadius * 2) + CGFloat(max(dotCount - 1, 0)) * spacing
        let size = NSSize(width: max(totalWidth, 20), height: 18)

        let image = NSImage(size: size, flipped: false) { rect in
            let centerY = rect.midY
            var x = padding + dotRadius
            for i in 0..<dotCount {
                let status: String? = i < components.count ? components[i].status : nil
                let dotRect = NSRect(x: x - dotRadius, y: centerY - dotRadius, width: dotRadius * 2, height: dotRadius * 2)
                self.claudeOrange.setStroke()
                let path = NSBezierPath(ovalIn: dotRect.insetBy(dx: strokeWidth / 2, dy: strokeWidth / 2))
                path.lineWidth = strokeWidth
                path.stroke()
                let inner = dotRect.insetBy(dx: strokeWidth, dy: strokeWidth)
                self.colorForStatus(status).setFill()
                NSBezierPath(ovalIn: inner).fill()
                x += dotRadius * 2 + spacing
            }
            return true
        }
        image.isTemplate = false
        statusItem.button?.image = image
    }

    func colorForStatus(_ status: String?) -> NSColor {
        switch status {
        case "operational":          return NSColor(calibratedRed: 0.46, green: 0.68, blue: 0.16, alpha: 1.0)
        case "degraded_performance": return NSColor(calibratedRed: 0.98, green: 0.65, blue: 0.17, alpha: 1.0)
        case "partial_outage":       return NSColor(calibratedRed: 0.91, green: 0.38, blue: 0.21, alpha: 1.0)
        case "major_outage":         return NSColor(calibratedRed: 0.88, green: 0.26, blue: 0.26, alpha: 1.0)
        case "under_maintenance":    return NSColor(calibratedRed: 0.17, green: 0.52, blue: 0.86, alpha: 1.0)
        default:                     return NSColor.tertiaryLabelColor
        }
    }

    // MARK: - Menu

    func buildMenu() {
        let menu = NSMenu()

        // Header — no flag
        let headerTitle = lastStatus?.description ?? "Loading..."
        let headerItem = NSMenuItem(title: headerTitle, action: nil, keyEquivalent: "")
        headerItem.attributedTitle = NSAttributedString(
            string: headerTitle,
            attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]
        )
        menu.addItem(headerItem)
        menu.addItem(NSMenuItem.separator())

        // Services
        if let status = lastStatus {
            let sectionItem = NSMenuItem(title: "SERVICES", action: nil, keyEquivalent: "")
            sectionItem.attributedTitle = NSAttributedString(
                string: "SERVICES",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 10, weight: .bold),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            )
            menu.addItem(sectionItem)

            let prefs = Preferences.shared
            let allSorted = prefs.sorted(status.components)
            let allNames = allSorted.map { $0.shortName }
            let displayed = prefs.hideDisabledInMenu ? allSorted.filter { prefs.isEnabled($0.shortName) } : allSorted

            for comp in displayed {
                let icon = statusIcon(comp.status)
                let label = statusLabel(comp.status)
                let enabled = prefs.isEnabled(comp.shortName)
                let fullIdx = allNames.firstIndex(of: comp.shortName) ?? 0

                let sub = NSMenu()

                // Visible in menu bar toggle
                let visibleItem = NSMenuItem(title: "Visible in Menu Bar", action: #selector(toggleComponent(_:)), keyEquivalent: "")
                visibleItem.target = self
                visibleItem.representedObject = comp.shortName
                visibleItem.state = enabled ? .on : .off
                sub.addItem(visibleItem)

                // Hide disabled from list toggle (global pref)
                let hideItem = NSMenuItem(title: "Hide Disabled from List", action: #selector(toggleHideDisabled(_:)), keyEquivalent: "")
                hideItem.target = self
                hideItem.state = prefs.hideDisabledInMenu ? .on : .off
                sub.addItem(hideItem)

                sub.addItem(NSMenuItem.separator())

                // Reorder
                let upItem = NSMenuItem(title: "↑ Move Up", action: #selector(moveComponentUp(_:)), keyEquivalent: "")
                upItem.target = self
                upItem.representedObject = comp.shortName
                upItem.isEnabled = fullIdx > 0
                sub.addItem(upItem)

                let downItem = NSMenuItem(title: "↓ Move Down", action: #selector(moveComponentDown(_:)), keyEquivalent: "")
                downItem.target = self
                downItem.representedObject = comp.shortName
                downItem.isEnabled = fullIdx < allNames.count - 1
                sub.addItem(downItem)

                // Uptime chart
                if let chartImage = UptimeFetcher.shared.buildUptimeImage(for: comp.shortName) {
                    sub.addItem(NSMenuItem.separator())

                    if let avg = UptimeFetcher.shared.averageUptime(for: comp.shortName) {
                        let pctItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                        pctItem.attributedTitle = NSAttributedString(
                            string: String(format: "%.2f%% uptime · 90 days", avg),
                            attributes: [
                                .font: NSFont.systemFont(ofSize: 11),
                                .foregroundColor: NSColor.secondaryLabelColor
                            ]
                        )
                        sub.addItem(pctItem)
                    }

                    let barItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                    barItem.image = chartImage
                    sub.addItem(barItem)
                }

                let itemTitle = "\(icon)  \(comp.shortName) — \(label)"
                let mainItem = NSMenuItem(title: itemTitle, action: nil, keyEquivalent: "")
                if !enabled {
                    mainItem.attributedTitle = NSAttributedString(
                        string: itemTitle,
                        attributes: [.foregroundColor: NSColor.tertiaryLabelColor]
                    )
                }
                mainItem.submenu = sub
                menu.addItem(mainItem)
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

        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        var infoLine = "v\(APP_VERSION)"
        if let fetchTime = lastFetchTime {
            let fmt = DateFormatter()
            fmt.dateFormat = "h:mm:ss a"
            infoLine += " · Updated \(fmt.string(from: fetchTime))"
        }
        if let apiTime = lastStatus?.updatedAt, !apiTime.isEmpty {
            infoLine += "\nAPI: \(apiTime) UTC"
        }
        let infoItem = NSMenuItem(title: infoLine, action: nil, keyEquivalent: "")
        infoItem.attributedTitle = NSAttributedString(
            string: infoLine,
            attributes: [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.tertiaryLabelColor
            ]
        )
        menu.addItem(infoItem)

        menu.addItem(NSMenuItem.separator())

        let flagItem = NSMenuItem(title: "🇺🇸 Made in America", action: nil, keyEquivalent: "")
        flagItem.attributedTitle = NSAttributedString(
            string: "🇺🇸 Made in America",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        menu.addItem(flagItem)

        let quitItem = NSMenuItem(title: "Quit Claude Status", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    func statusIcon(_ status: String) -> String {
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

    @objc func toggleComponent(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        Preferences.shared.toggle(name)
        updateIcon()
        buildMenu()
    }

    @objc func moveComponentUp(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let components = lastStatus?.components else { return }
        let allNames = Preferences.shared.sorted(components).map { $0.shortName }
        Preferences.shared.move(name, by: -1, in: allNames)
        buildMenu()
    }

    @objc func moveComponentDown(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let components = lastStatus?.components else { return }
        let allNames = Preferences.shared.sorted(components).map { $0.shortName }
        Preferences.shared.move(name, by: 1, in: allNames)
        buildMenu()
    }

    @objc func toggleHideDisabled(_ sender: NSMenuItem) {
        Preferences.shared.hideDisabledInMenu.toggle()
        buildMenu()
    }

    @objc func openDashboard() {
        let script = """
        tell application "Terminal"
            activate
            do script "\(dashboardPath)"
        end tell
        """
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(nil)
        }
    }

    @objc func openBrowser() {
        NSWorkspace.shared.open(URL(string: "https://status.claude.com")!)
    }

    @objc func refreshNow() {
        fetchAndUpdate()
        UptimeFetcher.shared.startFetching()
        SelfUpdater.checkAndUpdate()
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - Main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
