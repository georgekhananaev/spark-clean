//
//  SparkCleanApp.swift
//  SparkClean
//
//  Created by George Khananaev on 3/6/26.
//

import SwiftUI
import AppKit

@main
struct SparkCleanApp: App {
    @State private var showCustomAbout = false
    @State private var trashMonitor = TrashMonitor()
    @State private var updateChecker = UpdateChecker()
    @State private var showUpdateSheet = false
    @AppStorage("trashMonitorEnabled") private var trashMonitorEnabled = false
    @AppStorage("checkUpdatesOnLaunch") private var checkUpdatesOnLaunch = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(trashMonitor)
                .frame(minWidth: 800, minHeight: 550)
                .sheet(isPresented: $showCustomAbout) {
                    CustomAboutView()
                }
                .onAppear {
                    if trashMonitorEnabled {
                        trashMonitor.isEnabled = true
                    }
                    if checkUpdatesOnLaunch {
                        Task {
                            await updateChecker.check()
                            if updateChecker.updateAvailable {
                                showUpdateSheet = true
                            }
                        }
                    }
                }
                .onChange(of: trashMonitorEnabled) { _, newValue in
                    trashMonitor.isEnabled = newValue
                }
                .sheet(item: $trashMonitor.lastDetectedApp) { detected in
                    TrashLeftoverSheet(detected: detected, trashMonitor: trashMonitor)
                }
                .sheet(isPresented: $showUpdateSheet) {
                    UpdateCheckSheet(updateChecker: updateChecker)
                }
        }
        .defaultSize(width: 960, height: 680)
        .windowResizability(.contentSize)
        .commands {
            // Replace the default About menu item
            CommandGroup(replacing: .appInfo) {
                Button("About SparkClean") {
                    showCustomAbout = true
                }
            }

            // File menu
            CommandGroup(after: .newItem) {
                Button("Scan Now") {
                    NotificationCenter.default.post(name: .startScan, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command])

                Button("Export Report...") {
                    NotificationCenter.default.post(name: .exportReport, object: nil)
                }
                .keyboardShortcut("e", modifiers: [.command])
            }

            // Selection menu
            CommandMenu("Selection") {
                Button("Select All") {
                    NotificationCenter.default.post(name: .selectAll, object: nil)
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])

                Button("Deselect All") {
                    NotificationCenter.default.post(name: .deselectAll, object: nil)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

                Button("Select Safe Only") {
                    NotificationCenter.default.post(name: .selectSafeOnly, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }

            // Help menu — use a custom menu to avoid macOS intercepting the help system
            CommandMenu("Support") {
                Button("SparkClean Help") {
                    NotificationCenter.default.post(name: .showHelp, object: nil)
                }
                .keyboardShortcut("?", modifiers: [.command])

                Divider()

                Button("Contact Support") {
                    if let url = URL(string: "https://github.com/georgekhananaev/spark-clean/issues") {
                        NSWorkspace.shared.open(url)
                    }
                }

                Button("Report a Bug") {
                    if let url = URL(string: "https://github.com/georgekhananaev/spark-clean/issues") {
                        NSWorkspace.shared.open(url)
                    }
                }

                Button("GitHub Repository") {
                    if let url = URL(string: "https://github.com/georgekhananaev/spark-clean") {
                        NSWorkspace.shared.open(url)
                    }
                }

                Divider()

                Button("Privacy Policy") {
                    NotificationCenter.default.post(name: .showPrivacyPolicy, object: nil)
                }

                Button("What's New") {
                    NotificationCenter.default.post(name: .showWhatsNew, object: nil)
                }

                Divider()

                Button("Check for Updates...") {
                    showUpdateSheet = true
                    Task { await updateChecker.check() }
                }
            }

            // Remove the default Help menu to avoid "Help isn't available" message
            CommandGroup(replacing: .help) { }
        }

        Settings {
            SettingsView()
        }
    }
}

// MARK: - Custom About View

struct CustomAboutView: View {
    @Environment(\.dismiss) private var dismiss
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    private var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    private var systemInfo: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let arch = {
            #if arch(arm64)
            return "Apple Silicon (arm64)"
            #elseif arch(x86_64)
            return "Intel (x86_64)"
            #else
            return "Unknown"
            #endif
        }()
        let ram = ProcessInfo.processInfo.physicalMemory
        let ramGB = String(format: "%.0f", Double(ram) / 1_073_741_824)
        return """
        macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) \(arch)
        Memory: \(ramGB) GB
        Processors: \(ProcessInfo.processInfo.activeProcessorCount) cores
        """
    }

    private var buildInfo: String {
        "Build #SC-\(buildNumber), \(version)"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with gradient background
            ZStack {
                LinearGradient(
                    colors: [
                        Color.blue.opacity(0.15),
                        Color.purple.opacity(0.1),
                        Color.clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                VStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 52, weight: .thin))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.blue, .purple, .pink],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .shadow(color: .blue.opacity(0.3), radius: 10)

                    Text("SparkClean")
                        .font(.system(size: 24, weight: .bold, design: .rounded))

                    Text("Version \(version)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)

                    Text("Mac Storage & Cache Cleaner")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 20)
                .padding(.bottom, 16)
            }
            .frame(height: 180)

            Divider()

            // System info section
            VStack(alignment: .leading, spacing: 12) {
                InfoSection(title: "Build Information", content: buildInfo)

                InfoSection(title: "Developer", content: "George Khananaev")

                HStack(spacing: 4) {
                    Text("SOURCE CODE")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .tracking(0.5)
                    Spacer()
                }
                Link("github.com/georgekhananaev/spark-clean", destination: URL(string: "https://github.com/georgekhananaev/spark-clean")!)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.blue)

                InfoSection(title: "Runtime", content: systemInfo)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            // Footer
            HStack {
                Button {
                    let info = """
                    SparkClean \(version)
                    \(buildInfo)

                    \(systemInfo)
                    """
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(info, forType: .string)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10))
                        Text("Copy Info")
                            .font(.system(size: 11))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Text("Copyright \u{00A9} 2026 George Khananaev")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)

                Spacer()

                Button("OK") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.small)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 400, height: 420)
    }
}

struct InfoSection: View {
    let title: String
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)

            Text(content)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
    }
}

extension Notification.Name {
    static let startScan = Notification.Name("startScan")
    static let selectAll = Notification.Name("selectAll")
    static let deselectAll = Notification.Name("deselectAll")
    static let selectSafeOnly = Notification.Name("selectSafeOnly")
    static let exportReport = Notification.Name("exportReport")
    static let showHelp = Notification.Name("showHelp")
    static let showPrivacyPolicy = Notification.Name("showPrivacyPolicy")
    static let showWhatsNew = Notification.Name("showWhatsNew")
}

// MARK: - Trash Leftover Cleanup Sheet

struct TrashLeftoverSheet: View {
    let detected: TrashMonitor.DetectedTrashedApp
    let trashMonitor: TrashMonitor
    @Environment(\.dismiss) private var dismiss
    @State private var isCleaning = false
    @State private var cleaned = false

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "trash.slash")
                    .font(.title2)
                    .foregroundStyle(.orange)
                Text("Leftover Files Detected")
                    .font(.title3.bold())
                Spacer()
                Button("Dismiss") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("**\(detected.appName)** was moved to Trash but left **\(detected.formattedSize)** of data behind:")
                    .font(.body)

                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(detected.leftovers, id: \.path) { item in
                            HStack {
                                Text(item.category)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 100, alignment: .leading)
                                Text((item.path as NSString).lastPathComponent)
                                    .font(.caption.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Text(CleanupManager.formatBytes(item.size))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxHeight: 200)
            }

            HStack {
                Text("Files will be moved to Trash (recoverable).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()

                if cleaned {
                    Label("Cleaned!", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Button("Clean Leftovers") {
                        cleanLeftovers()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isCleaning)
                }
            }
        }
        .padding(20)
        .frame(width: 500, height: 350)
    }

    private func cleanLeftovers() {
        isCleaning = true
        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var failedPaths: [String] = []

            for item in detected.leftovers {
                let url = URL(fileURLWithPath: item.path)
                if (try? fm.trashItem(at: url, resultingItemURL: nil)) == nil {
                    failedPaths.append(item.path)
                }
            }

            // Escalate failed paths via admin privileges
            if !failedPaths.isEmpty {
                let trashDir = NSHomeDirectory() + "/.Trash"
                let tempScript = NSTemporaryDirectory() + "sparkclean_leftover_\(ProcessInfo.processInfo.processIdentifier).sh"
                var script = "#!/bin/bash\nset -e\n"
                for path in failedPaths {
                    let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
                    let name = (path as NSString).lastPathComponent.replacingOccurrences(of: "'", with: "'\\''")
                    let trashEscaped = trashDir.replacingOccurrences(of: "'", with: "'\\''")
                    script += "dest='\(trashEscaped)/\(name)'; "
                    script += "if [ -e \"$dest\" ]; then i=2; while [ -e \"$dest $i\" ]; do i=$((i+1)); done; dest=\"$dest $i\"; fi; "
                    script += "/bin/mv '\(escaped)' \"$dest\"\n"
                }
                try? script.write(toFile: tempScript, atomically: true, encoding: .utf8)
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempScript)

                let escapedScript = tempScript.replacingOccurrences(of: "'", with: "'\\''")
                let appleScriptSource = "do shell script \"'\(escapedScript)'\" with administrator privileges"

                await MainActor.run {
                    var error: NSDictionary?
                    let appleScript = NSAppleScript(source: appleScriptSource)
                    appleScript?.executeAndReturnError(&error)
                }
                try? fm.removeItem(atPath: tempScript)
            }

            await MainActor.run {
                cleaned = true
                isCleaning = false
            }
        }
    }
}

// MARK: - Update Check Sheet (from menu)

struct UpdateCheckSheet: View {
    @Bindable var updateChecker: UpdateChecker
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.title2)
                    .foregroundStyle(.blue)
                Text("Software Update")
                    .font(.title3.bold())
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            Spacer()

            if updateChecker.isChecking {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.regular)
                    Text("Checking for updates...")
                        .foregroundStyle(.secondary)
                }
            } else if updateChecker.isDownloading {
                VStack(spacing: 12) {
                    ProgressView(value: updateChecker.downloadProgress)
                        .frame(width: 250)
                    Text("Downloading... \(Int(updateChecker.downloadProgress * 100))%")
                        .foregroundStyle(.secondary)
                }
            } else if updateChecker.checkCompleted {
                if let error = updateChecker.errorMessage {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(.orange)
                        Text(error)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Try Again") {
                            Task { await updateChecker.check() }
                        }
                        .buttonStyle(.bordered)
                    }
                } else if updateChecker.updateAvailable {
                    VStack(spacing: 12) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(.green)
                        Text("SparkClean v\(updateChecker.latestVersion!) is available")
                            .font(.headline)
                        Text("You're currently on v\(updateChecker.currentVersion)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Download Update") {
                            updateChecker.downloadUpdate()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(.green)
                        Text("You're up to date!")
                            .font(.headline)
                        Text("SparkClean v\(updateChecker.currentVersion) is the latest version")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()
        }
        .padding(24)
        .frame(width: 380, height: 260)
    }
}
