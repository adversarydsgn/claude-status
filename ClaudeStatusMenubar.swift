import Cocoa

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
    let overall: String  // none, minor, major, critical
    let description: String
    let components: [ComponentStatus]
}

// MARK: - Status Fetcher

class StatusFetcher {
    static let apiURL = URL(string: "https://status.claude.com/api/v2/summary.json")!

    static func fetch(completion: @escaping (StatusResponse?) -> Void) {
        var request = URLRequest(url: apiURL)
        request.setValue("claude-status-menubar/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { data, _, error in
            guard let data = data, error == nil,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let status = json["status"] as? [String: String],
                  let components = json["components"] as? [[String: Any]]
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

            let response = StatusResponse(
                overall: status["indicator"] ?? "unknown",
                description: status["description"] ?? "Unknown",
                components: comps
            )
            completion(response)
        }.resume()
    }
}

// MARK: - Menu Bar App

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    var lastStatus: StatusResponse?

    let trackedComponents = ["claude.ai", "Claude Code"]
    let dashboardPath: String = {
        let bundle = Bundle.main.bundlePath
        // Look for the script relative to the .app, or fall back to known path
        let relative = (bundle as NSString).deletingLastPathComponent + "/claude-status.sh"
        if FileManager.default.fileExists(atPath: relative) {
            return relative
        }
        // Fall back to the project directory
        let home = NSHomeDirectory()
        return home + "/Desktop/Claude Desktop/Claude Status Terminal/claude-status.sh"
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // Initial state
        updateIcon(overall: nil)
        buildMenu()

        // Fetch immediately, then every 60s
        fetchAndUpdate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.fetchAndUpdate()
        }
    }

    func fetchAndUpdate() {
        StatusFetcher.fetch { [weak self] response in
            DispatchQueue.main.async {
                self?.lastStatus = response
                self?.updateIcon(overall: response?.overall)
                self?.buildMenu()
            }
        }
    }

    // MARK: - Icon Rendering

    // Claude/Anthropic brand orange for the stroke
    let claudeOrange = NSColor(calibratedRed: 0.85, green: 0.47, blue: 0.34, alpha: 0.85)  // #D97757

    func updateIcon(overall: String?) {
        let size = NSSize(width: 36, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            // Find status for tracked components
            let aiStatus = self.lastStatus?.components.first(where: { $0.shortName == "claude.ai" })?.status
            let codeStatus = self.lastStatus?.components.first(where: { $0.shortName == "Claude Code" })?.status

            let dotRadius: CGFloat = 5.0
            let strokeWidth: CGFloat = 1.25
            let padding: CGFloat = 4.0
            let centerY = rect.midY

            // Left dot: claude.ai
            let dot1X = padding + dotRadius
            let dot1Rect = NSRect(x: dot1X - dotRadius, y: centerY - dotRadius, width: dotRadius * 2, height: dotRadius * 2)
            // Orange stroke
            self.claudeOrange.setStroke()
            let dot1Path = NSBezierPath(ovalIn: dot1Rect.insetBy(dx: strokeWidth / 2, dy: strokeWidth / 2))
            dot1Path.lineWidth = strokeWidth
            dot1Path.stroke()
            // Status fill
            let dot1Inner = dot1Rect.insetBy(dx: strokeWidth, dy: strokeWidth)
            self.colorForStatus(aiStatus).setFill()
            NSBezierPath(ovalIn: dot1Inner).fill()

            // Right dot: Claude Code
            let dot2X = dot1X + dotRadius * 2 + padding + 2
            let dot2Rect = NSRect(x: dot2X - dotRadius, y: centerY - dotRadius, width: dotRadius * 2, height: dotRadius * 2)
            // Orange stroke
            self.claudeOrange.setStroke()
            let dot2Path = NSBezierPath(ovalIn: dot2Rect.insetBy(dx: strokeWidth / 2, dy: strokeWidth / 2))
            dot2Path.lineWidth = strokeWidth
            dot2Path.stroke()
            // Status fill
            let dot2Inner = dot2Rect.insetBy(dx: strokeWidth, dy: strokeWidth)
            self.colorForStatus(codeStatus).setFill()
            NSBezierPath(ovalIn: dot2Inner).fill()

            // Labels
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 7, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            let aiLabel = NSAttributedString(string: "ai", attributes: attrs)
            let codeLabel = NSAttributedString(string: "</>", attributes: attrs)

            aiLabel.draw(at: NSPoint(x: dot1X - 4, y: centerY - dotRadius - 9))
            codeLabel.draw(at: NSPoint(x: dot2X - 6, y: centerY - dotRadius - 9))

            return true
        }

        image.isTemplate = false
        statusItem.button?.image = image
    }

    func colorForStatus(_ status: String?) -> NSColor {
        switch status {
        case "operational":
            return NSColor(calibratedRed: 0.46, green: 0.68, blue: 0.16, alpha: 1.0)  // #76AD2A
        case "degraded_performance":
            return NSColor(calibratedRed: 0.98, green: 0.65, blue: 0.17, alpha: 1.0)  // #FAA72A
        case "partial_outage":
            return NSColor(calibratedRed: 0.91, green: 0.38, blue: 0.21, alpha: 1.0)  // #E86235
        case "major_outage":
            return NSColor(calibratedRed: 0.88, green: 0.26, blue: 0.26, alpha: 1.0)  // #E04343
        case "under_maintenance":
            return NSColor(calibratedRed: 0.17, green: 0.52, blue: 0.86, alpha: 1.0)  // #2C84DB
        default:
            return NSColor.tertiaryLabelColor  // gray when unknown/loading
        }
    }

    // MARK: - Menu

    func buildMenu() {
        let menu = NSMenu()

        // Overall status
        let overallTitle = lastStatus?.description ?? "Loading..."
        let overallItem = NSMenuItem(title: overallTitle, action: nil, keyEquivalent: "")
        overallItem.attributedTitle = NSAttributedString(
            string: overallTitle,
            attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]
        )
        menu.addItem(overallItem)
        menu.addItem(NSMenuItem.separator())

        // Component statuses
        if let components = lastStatus?.components {
            for comp in components {
                let icon = statusIcon(comp.status)
                let label = statusLabel(comp.status)
                let title = "\(icon)  \(comp.shortName) — \(label)"
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")

                // Highlight tracked components
                if trackedComponents.contains(comp.shortName) {
                    item.attributedTitle = NSAttributedString(
                        string: title,
                        attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)]
                    )
                }
                menu.addItem(item)
            }
        } else {
            menu.addItem(NSMenuItem(title: "Fetching status...", action: nil, keyEquivalent: ""))
        }

        menu.addItem(NSMenuItem.separator())

        // Open Dashboard
        let dashItem = NSMenuItem(title: "Open Terminal Dashboard", action: #selector(openDashboard), keyEquivalent: "d")
        dashItem.target = self
        menu.addItem(dashItem)

        // Open in Browser
        let browserItem = NSMenuItem(title: "Open status.claude.com", action: #selector(openBrowser), keyEquivalent: "b")
        browserItem.target = self
        menu.addItem(browserItem)

        menu.addItem(NSMenuItem.separator())

        // Refresh
        let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        // Quit
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
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
app.setActivationPolicy(.accessory)  // no dock icon, menubar only
app.run()
