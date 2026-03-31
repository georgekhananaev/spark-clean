//
//  MaintenanceView.swift
//  SparkClean
//
//  Created by George Khananaev on 3/30/26.
//

import SwiftUI

// MARK: - Maintenance Task Model

struct MaintenanceTask: Identifiable {
    let id = UUID()
    let name: String
    let description: String
    let icon: String
    let iconColor: Color
    let requiresAdmin: Bool
    let warning: String?
    let command: () -> (Bool, String)

    enum Status: Equatable {
        case idle
        case running
        case success(String)
        case failed(String)
    }
}

// MARK: - Maintenance Manager

@Observable
class MaintenanceManager {
    var tasks: [(task: MaintenanceTask, status: MaintenanceTask.Status)] = []
    var isRunningAll = false

    init() {
        setupTasks()
    }

    private func setupTasks() {
        tasks = [
            // No root required
            (task: MaintenanceTask(
                name: "Flush DNS Cache",
                description: "Clears stale DNS lookups — fixes website access issues",
                icon: "network", iconColor: .blue, requiresAdmin: false, warning: nil,
                command: {
                    let r1 = CleanupManager.runCommand("/usr/bin/dscacheutil", arguments: ["-flushcache"])
                    return (true, r1 ?? "DNS cache flushed")
                }
            ), status: .idle),

            (task: MaintenanceTask(
                name: "Reset QuickLook Cache",
                description: "Rebuilds file preview thumbnails — fixes broken previews",
                icon: "eye.square", iconColor: .purple, requiresAdmin: false, warning: nil,
                command: {
                    let r = CleanupManager.runCommand("/usr/bin/qlmanage", arguments: ["-r", "cache"])
                    return (r != nil, r ?? "QuickLook cache reset")
                }
            ), status: .idle),

            (task: MaintenanceTask(
                name: "Compact Launch Services",
                description: "Cleans up \"Open With\" menu — removes stale/duplicate entries",
                icon: "arrow.up.doc", iconColor: .orange, requiresAdmin: false, warning: nil,
                command: {
                    let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
                    let r = CleanupManager.runCommand(lsregister, arguments: ["-gc"])
                    // Also restart Finder to apply
                    CleanupManager.runCommand("/usr/bin/killall", arguments: ["Finder"])
                    return (true, r ?? "Launch Services database compacted")
                }
            ), status: .idle),

            (task: MaintenanceTask(
                name: "Clear Font Cache",
                description: "Rebuilds font rendering cache — fixes garbled text (requires re-login)",
                icon: "textformat", iconColor: .pink, requiresAdmin: false,
                warning: "You may need to log out and back in for fonts to reload.",
                command: {
                    let r = CleanupManager.runCommand("/usr/bin/atsutil", arguments: ["databases", "-removeUser"])
                    return (r != nil, r ?? "User font cache cleared")
                }
            ), status: .idle),

            // Requires admin
            (task: MaintenanceTask(
                name: "Full DNS Resolver Restart",
                description: "Restarts the mDNSResponder service — complete DNS reset",
                icon: "network.badge.shield.half.filled", iconColor: .green, requiresAdmin: true, warning: nil,
                command: {
                    let script = "do shell script \"killall -HUP mDNSResponder\" with administrator privileges"
                    var error: NSDictionary?
                    NSAppleScript(source: script)?.executeAndReturnError(&error)
                    if let error {
                        return (false, error["NSAppleScriptErrorMessage"] as? String ?? "Failed")
                    }
                    return (true, "mDNSResponder restarted")
                }
            ), status: .idle),

            (task: MaintenanceTask(
                name: "Rebuild Spotlight Index",
                description: "Re-indexes your entire drive — fixes broken Spotlight search",
                icon: "magnifyingglass", iconColor: .blue, requiresAdmin: true,
                warning: "This takes 30 minutes to 2 hours. Your Mac will use extra CPU during reindexing.",
                command: {
                    let script = "do shell script \"mdutil -E /\" with administrator privileges"
                    var error: NSDictionary?
                    NSAppleScript(source: script)?.executeAndReturnError(&error)
                    if let error {
                        return (false, error["NSAppleScriptErrorMessage"] as? String ?? "Failed")
                    }
                    return (true, "Spotlight reindex started — will complete in the background")
                }
            ), status: .idle),
        ]
    }

    func runTask(at index: Int) {
        guard index < tasks.count else { return }
        tasks[index].status = .running
        let command = tasks[index].task.command

        // Run on background thread for non-blocking tasks,
        // but NSAppleScript must run on main thread for admin tasks
        if tasks[index].task.requiresAdmin {
            // Admin tasks use NSAppleScript which is NOT thread-safe
            Task { @MainActor [weak self] in
                let (success, message) = command()
                self?.tasks[index].status = success ? .success(message) : .failed(message)
            }
        } else {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let (success, message) = command()
                DispatchQueue.main.async {
                    self?.tasks[index].status = success ? .success(message) : .failed(message)
                }
            }
        }
    }

    func runAll() {
        isRunningAll = true
        let nonAdminCommands: [(Int, () -> (Bool, String))] = tasks.indices
            .filter { !tasks[$0].task.requiresAdmin }
            .map { ($0, tasks[$0].task.command) }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            for (i, command) in nonAdminCommands {
                DispatchQueue.main.async { self?.tasks[i].status = .running }
                let (success, message) = command()
                DispatchQueue.main.async {
                    self?.tasks[i].status = success ? .success(message) : .failed(message)
                }
            }
            DispatchQueue.main.async { self?.isRunningAll = false }
        }
    }

    func resetAll() {
        for i in tasks.indices {
            tasks[i].status = .idle
        }
    }
}

// MARK: - Maintenance View

struct MaintenanceView: View {
    @State private var manager = MaintenanceManager()

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("System Maintenance")
                        .font(.title2.bold())
                    Text("Run Apple's built-in maintenance commands with one click")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Run All (Safe)") {
                    manager.runAll()
                }
                .buttonStyle(.borderedProminent)
                .disabled(manager.isRunningAll)
                .help("Runs all tasks that don't require admin password")

                if manager.tasks.contains(where: { $0.status != .idle }) {
                    Button("Reset") {
                        manager.resetAll()
                    }
                }
            }
            .padding()

            Divider()

            // Task List
            ScrollView {
                LazyVStack(spacing: 1) {
                    // No-admin section
                    Section {
                        ForEach(Array(manager.tasks.enumerated()), id: \.element.task.id) { index, item in
                            if !item.task.requiresAdmin {
                                MaintenanceTaskRow(
                                    task: item.task,
                                    status: item.status,
                                    isRunningAll: manager.isRunningAll
                                ) {
                                    manager.runTask(at: index)
                                }
                            }
                        }
                    } header: {
                        sectionHeader("Quick Actions", subtitle: "No admin password required")
                    }

                    Section {
                        ForEach(Array(manager.tasks.enumerated()), id: \.element.task.id) { index, item in
                            if item.task.requiresAdmin {
                                MaintenanceTaskRow(
                                    task: item.task,
                                    status: item.status,
                                    isRunningAll: manager.isRunningAll
                                ) {
                                    manager.runTask(at: index)
                                }
                            }
                        }
                    } header: {
                        sectionHeader("Admin Actions", subtitle: "Requires your password")
                    }
                }
                .padding()
            }
        }
    }

    private func sectionHeader(_ title: String, subtitle: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.top, 16)
        .padding(.bottom, 8)
    }
}

// MARK: - Task Row

struct MaintenanceTaskRow: View {
    let task: MaintenanceTask
    let status: MaintenanceTask.Status
    let isRunningAll: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: task.icon)
                .font(.title3)
                .foregroundStyle(task.iconColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(task.name)
                        .font(.body.weight(.medium))
                    if task.requiresAdmin {
                        Image(systemName: "lock.shield")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(task.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let warning = task.warning {
                    Text(warning)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

                // Status message
                switch status {
                case .success(let msg):
                    Text(msg)
                        .font(.caption2)
                        .foregroundStyle(.green)
                case .failed(let msg):
                    Text(msg)
                        .font(.caption2)
                        .foregroundStyle(.red)
                default:
                    EmptyView()
                }
            }

            Spacer()

            // Status / Action
            switch status {
            case .idle:
                Button("Run") { action() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isRunningAll)
            case .running:
                ProgressView()
                    .controlSize(.small)
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .font(.title3)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }
}
