//
//  StartupManagerView.swift
//  SparkClean
//
//  Created by George Khananaev on 3/30/26.
//

import SwiftUI
import ServiceManagement

// MARK: - Startup Item Model

struct StartupItem: Identifiable {
    let id = UUID()
    let label: String
    let displayName: String
    let type: ItemType
    let plistPath: String?
    let programPath: String?
    var isEnabled: Bool
    let isSystem: Bool
    var appIcon: NSImage?

    enum ItemType: String {
        case userAgent = "Launch Agent"
        case systemAgent = "System Agent"
        case systemDaemon = "Daemon"
    }
}

// MARK: - Startup Manager

@Observable
class StartupManager {
    var items: [StartupItem] = []
    var isScanning = false

    func scan() {
        isScanning = true
        items = []

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var results: [StartupItem] = []
            let fm = FileManager.default
            let home = NSHomeDirectory()

            // 1. User Launch Agents
            let userAgentDir = "\(home)/Library/LaunchAgents"
            if let entries = try? fm.contentsOfDirectory(atPath: userAgentDir) {
                for entry in entries where entry.hasSuffix(".plist") {
                    autoreleasepool {
                        let path = (userAgentDir as NSString).appendingPathComponent(entry)
                        if let item = Self.parsePlist(at: path, type: .userAgent) {
                            results.append(item)
                        }
                    }
                }
            }

            // 2. System Launch Agents (read-only display)
            let systemAgentDir = "/Library/LaunchAgents"
            if let entries = try? fm.contentsOfDirectory(atPath: systemAgentDir) {
                for entry in entries where entry.hasSuffix(".plist") {
                    autoreleasepool {
                        let path = (systemAgentDir as NSString).appendingPathComponent(entry)
                        if var item = Self.parsePlist(at: path, type: .systemAgent) {
                            item.isEnabled = true // system agents are always "enabled" from our perspective
                            results.append(item)
                        }
                    }
                }
            }

            // 3. System Daemons (read-only display)
            let daemonDir = "/Library/LaunchDaemons"
            if let entries = try? fm.contentsOfDirectory(atPath: daemonDir) {
                for entry in entries where entry.hasSuffix(".plist") {
                    autoreleasepool {
                        let path = (daemonDir as NSString).appendingPathComponent(entry)
                        if var item = Self.parsePlist(at: path, type: .systemDaemon) {
                            item.isEnabled = true
                            results.append(item)
                        }
                    }
                }
            }

            // Match icons from installed apps
            let appIcons = Self.loadAppIcons()
            for i in results.indices {
                let label = results[i].label.lowercased()
                for (bundleID, icon) in appIcons {
                    if label.contains(bundleID.lowercased()) ||
                       bundleID.lowercased().contains(label.components(separatedBy: ".").last ?? "") {
                        results[i].appIcon = icon
                        break
                    }
                }
            }

            results.sort { a, b in
                if a.type.rawValue != b.type.rawValue { return a.type.rawValue < b.type.rawValue }
                return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
            }

            DispatchQueue.main.async {
                self.items = results
                self.isScanning = false
            }
        }
    }

    // MARK: - Toggle Enable/Disable

    func toggleItem(at index: Int) {
        guard index < items.count else { return }
        let item = items[index]

        // Only user agents can be toggled
        guard item.type == .userAgent, let plistPath = item.plistPath else { return }

        let uid = getuid()
        let shouldDisable = item.isEnabled

        // Run launchctl on background thread to avoid blocking UI
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: String?
            if shouldDisable {
                result = CleanupManager.runCommand("/bin/launchctl", arguments: ["bootout", "gui/\(uid)", plistPath])
            } else {
                result = CleanupManager.runCommand("/bin/launchctl", arguments: ["bootstrap", "gui/\(uid)", plistPath])
            }
            DispatchQueue.main.async {
                // Only update toggle if launchctl succeeded (non-nil result means exit code 0)
                if result != nil {
                    self?.items[index].isEnabled = !shouldDisable
                }
            }
        }
    }

    // MARK: - Plist Parsing

    private static func parsePlist(at path: String, type: StartupItem.ItemType) -> StartupItem? {
        guard let data = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return nil
        }

        let label = plist["Label"] as? String ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        // Skip Apple's own agents
        if label.hasPrefix("com.apple.") { return nil }

        let program: String?
        if let prog = plist["Program"] as? String {
            program = prog
        } else if let args = plist["ProgramArguments"] as? [String], let first = args.first {
            program = first
        } else {
            program = nil
        }

        let disabled = plist["Disabled"] as? Bool ?? false
        let isSystem = type != .userAgent

        // Generate a human-readable name from the label
        let displayName = Self.humanReadableName(from: label)

        return StartupItem(
            label: label,
            displayName: displayName,
            type: type,
            plistPath: path,
            programPath: program,
            isEnabled: !disabled,
            isSystem: isSystem
        )
    }

    private static func humanReadableName(from label: String) -> String {
        // "com.docker.helper" -> "Docker Helper"
        // "org.mozilla.firefoxupdater" -> "Firefox Updater"
        let components = label.components(separatedBy: ".")
        guard components.count >= 2 else { return label }

        // Take last 1-2 meaningful components
        let meaningful = components.suffix(2)
            .filter { $0.count > 2 && $0 != "com" && $0 != "org" && $0 != "io" && $0 != "net" }
            .map { word -> String in
                // Capitalize and split camelCase
                var result = ""
                for (i, char) in word.enumerated() {
                    if i == 0 {
                        result.append(char.uppercased().first!)
                    } else if char.isUppercase && i > 0 {
                        result.append(" ")
                        result.append(char)
                    } else {
                        result.append(char)
                    }
                }
                return result
            }

        return meaningful.isEmpty ? label : meaningful.joined(separator: " ")
    }

    private static func loadAppIcons() -> [(String, NSImage)] {
        var appPaths: [(String, String)] = [] // (bundleID, path)
        let fm = FileManager.default
        for dir in ["/Applications", "\(NSHomeDirectory())/Applications"] {
            guard let contents = try? fm.contentsOfDirectory(
                at: URL(fileURLWithPath: dir),
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in contents where url.pathExtension == "app" {
                autoreleasepool {
                    if let bundle = Bundle(url: url), let id = bundle.bundleIdentifier {
                        appPaths.append((id, url.path))
                    }
                }
            }
        }
        // NSWorkspace.shared.icon must be called on the main thread
        var icons: [(String, NSImage)] = []
        DispatchQueue.main.sync {
            for (id, path) in appPaths {
                icons.append((id, NSWorkspace.shared.icon(forFile: path)))
            }
        }
        return icons
    }
}

// MARK: - Startup Manager View

struct StartupManagerView: View {
    @State private var manager = StartupManager()
    @State private var filter: StartupItem.ItemType?

    var filteredItems: [StartupItem] {
        if let filter {
            return manager.items.filter { $0.type == filter }
        }
        return manager.items
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Startup Items")
                        .font(.title2.bold())
                    Text("\(manager.items.count) items found across Launch Agents and Daemons")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()

                Picker("Filter", selection: $filter) {
                    Text("All").tag(nil as StartupItem.ItemType?)
                    Text("User Agents").tag(StartupItem.ItemType.userAgent as StartupItem.ItemType?)
                    Text("System Agents").tag(StartupItem.ItemType.systemAgent as StartupItem.ItemType?)
                    Text("Daemons").tag(StartupItem.ItemType.systemDaemon as StartupItem.ItemType?)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)

                Button {
                    manager.scan()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Rescan startup items")
            }
            .padding()

            Divider()

            if manager.isScanning {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Scanning launch agents and daemons...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if manager.items.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "bolt.circle")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("Click the refresh button to scan startup items")
                        .font(.body)
                        .foregroundStyle(.secondary)
                    Button("Scan Now") { manager.scan() }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(filteredItems.enumerated()), id: \.element.id) { _, item in
                            if let index = manager.items.firstIndex(where: { $0.id == item.id }) {
                                StartupItemRow(item: item) {
                                    manager.toggleItem(at: index)
                                }
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .onAppear {
            if manager.items.isEmpty {
                manager.scan()
            }
        }
    }
}

// MARK: - Startup Item Row

struct StartupItemRow: View {
    let item: StartupItem
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // Icon
            if let icon = item.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 28, height: 28)
                    .cornerRadius(6)
            } else {
                Image(systemName: item.type == .systemDaemon ? "gearshape.2" : "app.dashed")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }

            // Info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.displayName)
                        .font(.body.weight(.medium))

                    Text(item.type.rawValue)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(typeColor.opacity(0.15))
                        .foregroundStyle(typeColor)
                        .cornerRadius(4)
                }

                Text(item.label)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let program = item.programPath {
                    Text(program)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Toggle (only for user agents)
            if item.type == .userAgent {
                Toggle("", isOn: Binding(
                    get: { item.isEnabled },
                    set: { _ in onToggle() }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)
            } else {
                Text(item.isEnabled ? "Active" : "Disabled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }

    private var typeColor: Color {
        switch item.type {
        case .userAgent: .blue
        case .systemAgent: .orange
        case .systemDaemon: .red
        }
    }
}
