import Cocoa

let APP_VERSION = "1.1.0"

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
            else {
                completion(nil)
                return
            }

            let comps = components.compactMap { comp -> ComponentStatus? in
                guard let name = comp["name"] as? String,
                      let st = comp["status"] as? String
                else { return nil }
                return ComponentStatus(name: name, status: st)
            }

            let updatedAt = (page["updated_at"] as? String ?? "").prefix(19).replacingOccurrences(of: "T", with: " ")

            let response = StatusResponse(
                overall: status["indicator"] ?? "unknown",
                description: status["description"] ?? "Unknown",
                components: comps,
                updatedAt: String(updatedAt)
            )
            completion(response)
        }.resume()
    }
}

// MARK: - Preferences

class Preferences {
    static let shared = Preferences()
    private let defaults = UserDefaults.standard
    private let key = "enabledComponents"

    // All 5 services enabled by default
    private let allComponents = ["claude.ai", "platform.claude.com", "Claude API", "Claude Code", "Claude for Government"]

    var enabledComponents: Set<String> {
        get {
            if let saved = defaults.stringArray(forKey: key) {
                return Set(saved)
            }
            return Set(allComponents)
        }
        set {
            defaults.set(Array(newValue), forKey: key)
        }
    }

    func isEnabled(_ name: String) -> Bool {
        return enabledComponents.contains(name)
    }

    func toggle(_ name: String) {
        var current = enabledComponents
        if current.contains(name) {
            // Don't allow disabling all — keep at least one
            if current.count > 1 {
                current.remove(name)
            }
        } else {
            current.insert(name)
        }
        enabledComponents = current
    }
}

// MARK: - Menu Bar App

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    var lastStatus: StatusResponse?
    var lastFetchTime: Date?

    let dashboardPath: String = {
        let bundle = Bundle.main.bundlePath
        let relative = (bundle as NSString).deletingLastPathComponent + "/claude-status.sh"
        if FileManager.default.fileExists(atPath: relative) {
            return relative
        }
        // Check curl-installed location
        let curlPath = NSHomeDirectory() + "/.claude-status/claude-status.sh"
        if FileManager.default.fileExists(atPath: curlPath) {
            return curlPath
        }
        let home = NSHomeDirectory()
        return home + "/Desktop/Claude Desktop/Claude Status Terminal/claude-status.sh"
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon()
        buildMenu()
        fetchAndUpdate()
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

    let claudeOrange = NSColor(calibratedRed: 0.85, green: 0.47, blue: 0.34, alpha: 0.85)

    func updateIcon() {
        let enabled = Preferences.shared.enabledComponents
        let components = lastStatus?.components.filter { enabled.contains($0.shortName) } ?? []
        let dotCount = max(components.count, enabled.count)

        let dotRadius: CGFloat = 4.5
        let strokeWidth: CGFloat = 1.25
        let spacing: CGFloat = 3.0
        let padding: CGFloat = 3.0
        let totalWidth = padding * 2 + CGFloat(dotCount) * (dotRadius * 2) + CGFloat(max(dotCount - 1, 0)) * spacing
        let size = NSSize(width: max(totalWidth, 18), height: 18)

        let image = NSImage(size: size, flipped: false) { rect in
            let centerY = rect.midY
            var x = padding + dotRadius

            for i in 0..<dotCount {
                let status: String? = i < components.count ? components[i].status : nil
                let dotRect = NSRect(x: x - dotRadius, y: centerY - dotRadius, width: dotRadius * 2, height: dotRadius * 2)

                // Orange stroke
                self.claudeOrange.setStroke()
                let path = NSBezierPath(ovalIn: dotRect.insetBy(dx: strokeWidth / 2, dy: strokeWidth / 2))
                path.lineWidth = strokeWidth
                path.stroke()

                // Status fill
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
        case "operational":
            return NSColor(calibratedRed: 0.46, green: 0.68, blue: 0.16, alpha: 1.0)
        case "degraded_performance":
            return NSColor(calibratedRed: 0.98, green: 0.65, blue: 0.17, alpha: 1.0)
        case "partial_outage":
            return NSColor(calibratedRed: 0.91, green: 0.38, blue: 0.21, alpha: 1.0)
        case "major_outage":
            return NSColor(calibratedRed: 0.88, green: 0.26, blue: 0.26, alpha: 1.0)
        case "under_maintenance":
            return NSColor(calibratedRed: 0.17, green: 0.52, blue: 0.86, alpha: 1.0)
        default:
            return NSColor.tertiaryLabelColor
        }
    }

    // MARK: - Menu

    func buildMenu() {
        let menu = NSMenu()

        // ── Header: flag + overall status ──────────────
        let headerTitle = "🇺🇸 \(lastStatus?.description ?? "Loading...")"
        let headerItem = NSMenuItem(title: headerTitle, action: nil, keyEquivalent: "")
        headerItem.attributedTitle = NSAttributedString(
            string: headerTitle,
            attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]
        )
        menu.addItem(headerItem)
        menu.addItem(NSMenuItem.separator())

        // ── Component statuses with checkboxes ─────────
        if let components = lastStatus?.components {
            let enabledTitle = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
            enabledTitle.attributedTitle = NSAttributedString(
                string: "SERVICES",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 10, weight: .bold),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            )
            menu.addItem(enabledTitle)

            for comp in components {
                let icon = statusIcon(comp.status)
                let label = statusLabel(comp.status)
                let title = "\(icon)  \(comp.shortName) — \(label)"
                let item = NSMenuItem(title: title, action: #selector(toggleComponent(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = comp.shortName

                // Checkbox state
                if Preferences.shared.isEnabled(comp.shortName) {
                    item.state = .on
                } else {
                    item.state = .off
                }

                menu.addItem(item)
            }
        } else {
            menu.addItem(NSMenuItem(title: "Fetching status...", action: nil, keyEquivalent: ""))
        }

        menu.addItem(NSMenuItem.separator())

        // ── Actions ────────────────────────────────────
        let dashItem = NSMenuItem(title: "Open Terminal Dashboard", action: #selector(openDashboard), keyEquivalent: "d")
        dashItem.target = self
        menu.addItem(dashItem)

        let browserItem = NSMenuItem(title: "Open status.claude.com", action: #selector(openBrowser), keyEquivalent: "b")
        browserItem.target = self
        menu.addItem(browserItem)

        menu.addItem(NSMenuItem.separator())

        // ── Footer: version + last update ──────────────
        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        // Last updated timestamp
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

        // ── Flag footer ────────────────────────────────
        let flagItem = NSMenuItem(title: "🇺🇸 Made in America", action: nil, keyEquivalent: "")
        flagItem.attributedTitle = NSAttributedString(
            string: "🇺🇸 Made in America",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        menu.addItem(flagItem)

        // Quit
        let quitItem = NSMenuItem(title: "Quit Claude Status", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    func statusIcon(_ status: String) -> String {
        switch status {
        case "operational": return "🟢"
        case "degraded_performance": return "🟡"
        case "partial_outage": return "🟠"
        case "major_outage": return "🔴"
        case "under_maintenance": return "🔵"
        default: return "⚪"
        }
    }

    func statusLabel(_ status: String) -> String {
        switch status {
        case "operational": return "Operational"
        case "degraded_performance": return "Degraded"
        case "partial_outage": return "Partial Outage"
        case "major_outage": return "Major Outage"
        case "under_maintenance": return "Maintenance"
        default: return "Unknown"
        }
    }

    // MARK: - Actions

    @objc func toggleComponent(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        Preferences.shared.toggle(name)
        updateIcon()
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
