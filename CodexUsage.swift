import SwiftUI
import AppKit
import Combine

struct WindowUsage: Decodable { let usedPercent: Int; let windowDurationMins: Int?; let resetsAt: TimeInterval? }
struct Limits: Decodable { let primary: WindowUsage?; let secondary: WindowUsage? }
struct UsageResult: Decodable { let rateLimits: Limits }
struct RPCError: Decodable { let message: String }
struct Response: Decodable { let id: Int?; let result: UsageResult?; let error: RPCError? }
enum UsageError: LocalizedError {
    case unavailable, timeout, noWindows, server(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Couldn’t connect to Codex. Check that the CLI is installed and signed in."
        case .timeout: return "The usage request timed out."
        case .noWindows: return "Usage limits aren’t available for this account."
        case .server(let message): return message
        }
    }
}
enum UsageReader {
    static func read() async throws -> Limits {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do { continuation.resume(returning: try request()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    private static func request() throws -> Limits {
        let process = Process(), output = Pipe(), input = Pipe()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let environmentPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/codex" }
        let candidates = environmentPaths + ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "\(home)/.local/bin/codex", "\(home)/.bun/bin/codex", "\(home)/.npm-global/bin/codex"]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw UsageError.unavailable }
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw UsageError.unavailable }
        defer { if process.isRunning { process.terminate() }; try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close() }
        let messages: [[String: Any]] = [
            ["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "codex_usage_menubar", "version": "1.0"]]],
            ["method": "initialized", "params": [:]],
            ["id": 2, "method": "account/rateLimits/read", "params": [:]]
        ]
        for message in messages {
            var data = try JSONSerialization.data(withJSONObject: message); data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        let fd = output.fileHandleForReading.fileDescriptor, deadline = Date().addingTimeInterval(15)
        var buffer = Data()
        while Date() < deadline {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 500)
            if ready < 0 { throw UsageError.unavailable }
            if ready == 0 { if !process.isRunning { throw UsageError.unavailable }; continue }
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { throw UsageError.unavailable }
            buffer.append(chunk)
            while let end = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
                guard let response = try? JSONDecoder().decode(Response.self, from: line), response.id == 2 else { continue }
                if let error = response.error { throw UsageError.server(error.message) }
                guard let limits = response.result?.rateLimits else { throw UsageError.unavailable }
                return limits
            }
        }
        throw UsageError.timeout
    }
}
@MainActor final class UsageModel: ObservableObject {
    @Published var fiveHour: WindowUsage?
    @Published var weekly: WindowUsage?
    @Published var updated: Date?
    @Published var error: String?
    @Published var loading = false
    private var timer: Timer?
    var exhaustedWindows: [WindowUsage] {
        [fiveHour, weekly].compactMap { $0 }.filter { $0.usedPercent >= 100 }
    }
    var isOutOfUsage: Bool { !exhaustedWindows.isEmpty }
    var exhaustedUntil: Date? {
        let exhausted = exhaustedWindows
        guard !exhausted.isEmpty, exhausted.allSatisfy({ $0.resetsAt != nil }) else { return nil }
        let resets = exhausted.compactMap(\.resetsAt)
            .map { Date(timeIntervalSince1970: $0) }
        guard resets.allSatisfy({ $0 > Date() }) else { return nil }
        return resets.max()
    }
    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
    }
    func refresh() {
        guard !loading else { return }; loading = true
        Task {
            do {
                let limits = try await UsageReader.read()
                let windows = [limits.primary, limits.secondary].compactMap { $0 }
                let five = windows.first { $0.windowDurationMins == 300 }
                let week = windows.first { $0.windowDurationMins == 10080 }
                guard five != nil || week != nil else { throw UsageError.noWindows }
                fiveHour = five; weekly = week; updated = Date(); error = nil
            } catch { self.error = error.localizedDescription }
            loading = false
        }
    }
}
struct UsageRow: View {
    let title: String; let usage: WindowUsage?
    var remaining: Int { max(0, min(100, 100 - (usage?.usedPercent ?? 100))) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 13, weight: .medium)); Spacer()
                Text(usage == nil ? "Unavailable" : "\(remaining)% left")
                    .font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(usage == nil ? .secondary : .primary)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.10))
                    if usage != nil { Capsule().fill(Color.primary.opacity(0.78)).frame(width: g.size.width * CGFloat(remaining) / 100) }
                }
            }.frame(height: 6).accessibilityHidden(true)
            Text(resetText).font(.system(size: 11)).foregroundStyle(.secondary)
        }.accessibilityElement(children: .combine)
    }
    var resetText: String {
        guard let timestamp = usage?.resetsAt else { return "Reset time unavailable" }
        let date = Date(timeIntervalSince1970: timestamp)
        return "Resets " + date.formatted(.relative(presentation: .named)) + " · " + date.formatted(date: .abbreviated, time: .shortened)
    }
}
struct PopoverView: View {
    @ObservedObject var model: UsageModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Codex usage").font(.system(size: 15, weight: .semibold))
                    Text("Your current usage limits").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if model.loading { ProgressView().controlSize(.small).scaleEffect(0.75).frame(width: 20, height: 20) }
            }.padding(.bottom, 19)
            if model.isOutOfUsage {
                VStack(alignment: .leading, spacing: 9) {
                    Text(outOfUsageMessage)
                        .font(.system(size: 13, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Request more usage to keep going")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Link(destination: URL(string: "https://chatgpt.com/settings/usage")!) {
                        Text("Request more usage")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityHint("Opens ChatGPT usage settings")
                }
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Color.primary.opacity(0.08)))
                .padding(.bottom, 18)
            }
            if model.updated == nil && model.loading {
                Text("Loading usage…").font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 112)
            } else if model.updated == nil {
                Text(model.error ?? "Usage unavailable").font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
            } else {
                VStack(spacing: 20) {
                    UsageRow(title: "5-hour limit", usage: model.fiveHour)
                    UsageRow(title: "Weekly limit", usage: model.weekly)
                }
            }
            Divider().padding(.top, 18).padding(.bottom, 10)
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    if let date = model.updated { Text("Updated " + date.formatted(date: .omitted, time: .shortened)).font(.system(size: 10)).foregroundStyle(.secondary) }
                    if model.error != nil && model.updated != nil { Text("Refresh failed · showing last update").font(.system(size: 10)).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
                Button("Refresh") { model.refresh() }.disabled(model.loading)
                Link("Manage usage", destination: URL(string: "https://chatgpt.com/settings/usage")!)
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }.controlSize(.small)
        }.padding(18).frame(width: 300)
    }
    private var outOfUsageMessage: String {
        guard let reset = model.exhaustedUntil else { return "You're out of usage" }
        return "You're out of usage until " + reset.formatted(date: .abbreviated, time: .shortened)
    }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = UsageModel(); let popover = NSPopover()
    var statusItem: NSStatusItem!; var observer: AnyCancellable?
    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self; statusItem.button?.action = #selector(togglePopover)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: PopoverView(model: model))
        observer = model.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.updateStatus() } }
        updateStatus(); model.start()
    }
    func updateStatus() {
        func value(_ usage: WindowUsage?) -> String { usage.map { "\(max(0, min(100, 100 - $0.usedPercent)))%" } ?? "—" }
        statusItem.button?.title = ""
        statusItem.button?.image = Self.statusIcon(fiveHour: model.fiveHour, weekly: model.weekly)
        let availability = model.isOutOfUsage ? model.exhaustedUntil.map {
            "Out of usage until " + $0.formatted(date: .abbreviated, time: .shortened)
        } ?? "Usage limit reached" : "five-hour and weekly limits remaining"
        statusItem.button?.toolTip = "Codex usage: \(availability)"
        statusItem.button?.setAccessibilityLabel("Codex usage, five-hour \(value(model.fiveHour)) remaining, weekly \(value(model.weekly)) remaining, \(availability)")
    }
    static func statusIcon(fiveHour: WindowUsage?, weekly: WindowUsage?) -> NSImage {
        func fraction(_ usage: WindowUsage?) -> CGFloat {
            guard let usage else { return 0 }
            return CGFloat(max(0, min(100, 100 - usage.usedPercent))) / 100
        }
        let five = fraction(fiveHour), week = fraction(weekly)
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            let center = NSPoint(x: 10, y: 10)
            NSColor.labelColor.withAlphaComponent(0.22).setStroke()
            func drawArc(start: CGFloat, span: CGFloat, fraction: CGFloat) {
                guard fraction > 0 else { return }
                let path = NSBezierPath()
                path.lineWidth = 1.6
                path.lineCapStyle = .round
                path.appendArc(withCenter: center, radius: 8, startAngle: start, endAngle: start + span * fraction)
                path.stroke()
            }
            drawArc(start: 45, span: 90, fraction: 1)
            drawArc(start: 190, span: 160, fraction: 1)
            NSColor.labelColor.withAlphaComponent(0.72).setStroke()
            drawArc(start: 45, span: 90, fraction: five)
            drawArc(start: 190, span: 160, fraction: week)
            NSColor.labelColor.withAlphaComponent(0.35).setFill()
            let diamond = NSBezierPath(roundedRect: NSRect(x: -3, y: -3, width: 6, height: 6), xRadius: 1.3, yRadius: 1.3)
            var transform = AffineTransform(translationByX: 10, byY: 10)
            transform.rotate(byDegrees: 45)
            diamond.transform(using: transform)
            diamond.fill()
            return true
        }
        image.isTemplate = true
        return image
    }
    @objc func togglePopover() {
        if popover.isShown { popover.performClose(nil) }
        else if let button = statusItem.button {
            model.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.async { [weak self, weak button] in
                guard let self, let button, let buttonWindow = button.window,
                      let popoverWindow = self.popover.contentViewController?.view.window else { return }
                let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
                var frame = popoverWindow.frame
                let gap = buttonRect.minY - frame.maxY
                if gap > 8 {
                    frame.origin.y += gap - 2
                    popoverWindow.setFrameOrigin(frame.origin)
                }
            }
        }
    }
}
@main struct Main {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
