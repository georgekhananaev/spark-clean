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
    var estimate: String? = nil

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
    var tasks: [(task: MaintenanceTask, status: MaintenanceTask.Status, isSelected: Bool)] = []
    var isRunningAll = false
    var tmSnapshotCount: Int = 0
    var tmSnapshotSize: Int64 = 0
    var purgeableSpace: Int64 = 0
    var spotlightSize: Int64 = 0
    var isEstimating = false
    var containerDisk: String = "disk3"

    init() {
        setupTasks()
        estimateReclaimableSpace()
    }

    func estimateReclaimableSpace() {
        isEstimating = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var snapshotCount = 0
            var snapshotBytes: Int64 = 0
            var purgeable: Int64 = 0
            var diskID = "disk3"

            // Get container disk identifier
            if let output = CleanupManager.runCommand("/usr/sbin/diskutil", arguments: ["info", "/"]) {
                for line in output.components(separatedBy: "\n") {
                    if line.contains("Part of Whole:") {
                        let parts = line.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces) ?? ""
                        if !parts.isEmpty { diskID = parts }
                    }
                }
            }

            // Parse APFS purgeable space (NOT free space — only actual purgeable data)
            if let output = CleanupManager.runCommand("/usr/sbin/diskutil", arguments: ["apfs", "list"]) {
                for line in output.components(separatedBy: "\n") {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.contains("Purgeable") && !trimmed.contains("0 Bytes") && !trimmed.contains("0 B") {
                        if let range = trimmed.range(of: #"\((\d+) Bytes\)"#, options: .regularExpression) {
                            let digits = String(trimmed[range]).filter(\.isNumber)
                            if let bytes = Int64(digits), bytes > 0 {
                                purgeable = max(purgeable, bytes)
                            }
                        }
                    }
                }
            }

            // Count Time Machine local snapshots
            if let output = CleanupManager.runCommand("/usr/bin/tmutil", arguments: ["listlocalsnapshots", "/"]) {
                let snapshots = output.components(separatedBy: "\n").filter { $0.contains("com.apple.TimeMachine") }
                snapshotCount = snapshots.count
            }

            // Get actual snapshot disk usage
            if snapshotCount > 0 {
                if let output = CleanupManager.runCommand("/usr/sbin/diskutil", arguments: ["apfs", "listSnapshots", diskID + "s1"]) {
                    for line in output.components(separatedBy: "\n") {
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        if trimmed.contains("Snapshot Disk Size") || trimmed.contains("Used by Snapshots") {
                            if let range = trimmed.range(of: #"\((\d+) Bytes\)"#, options: .regularExpression) {
                                let digits = String(trimmed[range]).filter(\.isNumber)
                                if let bytes = Int64(digits), bytes > snapshotBytes {
                                    snapshotBytes = bytes
                                }
                            }
                        }
                    }
                }
                // Fallback estimate if parsing failed
                if snapshotBytes == 0 {
                    snapshotBytes = Int64(snapshotCount) * 2_000_000_000
                }
            }

            // Estimate Spotlight index size (~0.5% of used space, typically 1-5 GB)
            var spotlightEst: Int64 = 0
            if let output = CleanupManager.runCommand("/usr/sbin/diskutil", arguments: ["info", "/System/Volumes/Data"]) {
                for line in output.components(separatedBy: "\n") {
                    if line.contains("Volume Used Space") {
                        if let range = line.range(of: #"\((\d+) Bytes\)"#, options: .regularExpression) {
                            let digits = String(line[range]).filter(\.isNumber)
                            if let usedBytes = Int64(digits), usedBytes > 0 {
                                spotlightEst = usedBytes / 200 // ~0.5% of used space
                            }
                        }
                    }
                }
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.tmSnapshotCount = snapshotCount
                self.tmSnapshotSize = snapshotBytes
                self.purgeableSpace = purgeable
                self.spotlightSize = spotlightEst
                self.containerDisk = diskID
                self.isEstimating = false

                // Update per-task estimates
                for i in self.tasks.indices {
                    switch self.tasks[i].task.name {
                    case "Clear Time Machine Snapshots":
                        self.tasks[i].task.estimate = snapshotCount > 0
                            ? "\(snapshotCount) snapshot\(snapshotCount == 1 ? "" : "s") (~\(CleanupManager.formatBytes(snapshotBytes)))"
                            : "No snapshots found"
                    case "Free APFS Purgeable Space":
                        self.tasks[i].task.estimate = purgeable > 0
                            ? "~\(CleanupManager.formatBytes(purgeable)) purgeable"
                            : "Already optimized"
                    case "Rebuild Spotlight Index":
                        self.tasks[i].task.estimate = spotlightEst > 0
                            ? "Index ~\(CleanupManager.formatBytes(spotlightEst))"
                            : nil
                    default: break
                    }
                }
            }
        }
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
            ), status: .idle, isSelected: false),

            (task: MaintenanceTask(
                name: "Reset QuickLook Cache",
                description: "Rebuilds file preview thumbnails — fixes broken previews",
                icon: "eye.square", iconColor: .purple, requiresAdmin: false, warning: nil,
                command: {
                    let r = CleanupManager.runCommand("/usr/bin/qlmanage", arguments: ["-r", "cache"])
                    return (r != nil, r ?? "QuickLook cache reset")
                }
            ), status: .idle, isSelected: false),

            (task: MaintenanceTask(
                name: "Compact Launch Services",
                description: "Cleans up \"Open With\" menu — removes stale/duplicate entries",
                icon: "arrow.up.doc", iconColor: .orange, requiresAdmin: false, warning: nil,
                command: {
                    let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
                    _ = CleanupManager.runCommand(lsregister, arguments: ["-gc"])
                    _ = CleanupManager.runCommand("/usr/bin/killall", arguments: ["Finder"])
                    return (true, "Launch Services compacted, Finder restarted")
                }
            ), status: .idle, isSelected: false),

            (task: MaintenanceTask(
                name: "Clear Font Cache",
                description: "Rebuilds font rendering cache — fixes garbled text (requires re-login)",
                icon: "textformat", iconColor: .pink, requiresAdmin: false,
                warning: "You may need to log out and back in for fonts to reload.",
                command: {
                    let r = CleanupManager.runCommand("/usr/bin/atsutil", arguments: ["databases", "-removeUser"])
                    return (r != nil, r ?? "User font cache cleared")
                }
            ), status: .idle, isSelected: false),

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
            ), status: .idle, isSelected: false),

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
            ), status: .idle, isSelected: false),

            (task: MaintenanceTask(
                name: "Clear Time Machine Snapshots",
                description: "Removes local Time Machine snapshots — can reclaim massive space",
                icon: "clock.arrow.trianglehead.counterclockwise.rotate.90", iconColor: .teal, requiresAdmin: true,
                warning: "This removes ALL local snapshots. Your Time Machine backups on external drives are not affected.",
                command: {
                    // First check how many snapshots exist
                    let before = CleanupManager.runCommand("/usr/bin/tmutil", arguments: ["listlocalsnapshots", "/"])
                    let countBefore = before?.components(separatedBy: "\n").filter { $0.contains("com.apple.TimeMachine") }.count ?? 0

                    if countBefore == 0 {
                        return (true, "No local snapshots found — nothing to clear")
                    }

                    let script = "do shell script \"/usr/bin/tmutil thinlocalsnapshots / 9999999999 1\" with administrator privileges"
                    var error: NSDictionary?
                    let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
                    if let error {
                        return (false, error["NSAppleScriptErrorMessage"] as? String ?? "Failed — admin password required")
                    }

                    let output = result?.stringValue ?? ""
                    // Check how many remain
                    let after = CleanupManager.runCommand("/usr/bin/tmutil", arguments: ["listlocalsnapshots", "/"])
                    let countAfter = after?.components(separatedBy: "\n").filter { $0.contains("com.apple.TimeMachine") }.count ?? 0
                    let removed = countBefore - countAfter

                    if removed > 0 {
                        return (true, "Removed \(removed) snapshot\(removed == 1 ? "" : "s"). \(output)")
                    }
                    return (true, output.isEmpty ? "Snapshots thinned successfully" : output)
                }
            ), status: .idle, isSelected: false),

            (task: MaintenanceTask(
                name: "Free APFS Purgeable Space",
                description: "Enables APFS defragmentation to reclaim fragmented disk space",
                icon: "externaldrive.badge.minus", iconColor: .cyan, requiresAdmin: true,
                warning: "Defragmentation runs in the background. Space is reclaimed gradually.",
                command: { [weak self] in
                    let diskID = self?.containerDisk ?? "disk3"

                    // Check current status first
                    let status = CleanupManager.runCommand("/usr/sbin/diskutil", arguments: ["apfs", "defragment", diskID, "status"])
                    let alreadyEnabled = status?.contains("enabled") ?? false

                    if alreadyEnabled {
                        return (true, "APFS defragmentation is already enabled and running in the background")
                    }

                    let script = "do shell script \"/usr/sbin/diskutil apfs defragment \(diskID) enable\" with administrator privileges"
                    var error: NSDictionary?
                    NSAppleScript(source: script)?.executeAndReturnError(&error)
                    if let error {
                        return (false, error["NSAppleScriptErrorMessage"] as? String ?? "Failed — admin password required")
                    }
                    return (true, "APFS defragmentation enabled — space will be reclaimed in the background")
                }
            ), status: .idle, isSelected: false),
        ]
    }

    func runTask(at index: Int) {
        guard index < tasks.count else { return }
        tasks[index].status = .running
        let command = tasks[index].task.command
        let isSpaceRecovery = tasks[index].task.name == "Clear Time Machine Snapshots" ||
                              tasks[index].task.name == "Free APFS Purgeable Space"

        // Run on background thread for non-blocking tasks,
        // but NSAppleScript must run on main thread for admin tasks
        if tasks[index].task.requiresAdmin {
            Task { @MainActor [weak self] in
                let (success, message) = command()
                self?.tasks[index].status = success ? .success(message) : .failed(message)
                if isSpaceRecovery && success { self?.estimateReclaimableSpace() }
            }
        } else {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let (success, message) = command()
                DispatchQueue.main.async {
                    self?.tasks[index].status = success ? .success(message) : .failed(message)
                    if isSpaceRecovery && success { self?.estimateReclaimableSpace() }
                }
            }
        }
    }

    var selectedCount: Int {
        tasks.filter(\.isSelected).count
    }

    func runSelected() {
        isRunningAll = true
        let selectedIndices = tasks.indices.filter { tasks[$0].isSelected }

        // Split into non-admin (run on background) and admin (run on main)
        let nonAdmin = selectedIndices.filter { !tasks[$0].task.requiresAdmin }
        let admin = selectedIndices.filter { tasks[$0].task.requiresAdmin }

        Task { [weak self] in
            // Run non-admin tasks on background thread
            if !nonAdmin.isEmpty {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    DispatchQueue.global(qos: .userInitiated).async {
                        for i in nonAdmin {
                            guard let self else { break }
                            let command = self.tasks[i].task.command
                            DispatchQueue.main.async { self.tasks[i].status = .running }
                            let (success, message) = command()
                            DispatchQueue.main.async {
                                self.tasks[i].status = success ? .success(message) : .failed(message)
                            }
                        }
                        continuation.resume()
                    }
                }
            }

            // Run admin tasks on main thread (NSAppleScript requirement)
            for i in admin {
                guard let self else { break }
                await MainActor.run { self.tasks[i].status = .running }
                let command = self.tasks[i].task.command
                let (success, message) = await MainActor.run { command() }
                await MainActor.run {
                    self.tasks[i].status = success ? .success(message) : .failed(message)
                    let isSpaceRecovery = self.tasks[i].task.name == "Clear Time Machine Snapshots" ||
                                          self.tasks[i].task.name == "Free APFS Purgeable Space"
                    if isSpaceRecovery && success { self.estimateReclaimableSpace() }
                }
            }

            await MainActor.run { self?.isRunningAll = false }
        }
    }

    func resetAll() {
        for i in tasks.indices {
            tasks[i].status = .idle
            tasks[i].isSelected = false
        }
    }
}

// MARK: - Maintenance View

struct MaintenanceView: View {
    @State private var manager = MaintenanceManager()
    @State private var showRunConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("System Maintenance")
                        .font(.title2.bold())
                    Text("Select tasks to run, then click Run Selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()

                if manager.tasks.contains(where: { $0.status != .idle }) {
                    Button("Reset") {
                        manager.resetAll()
                    }
                }

                Button("Run Selected (\(manager.selectedCount))") {
                    showRunConfirmation = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(manager.selectedCount == 0 || manager.isRunningAll)
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
                                    isSelected: $manager.tasks[index].isSelected,
                                    isRunning: manager.isRunningAll
                                )
                            }
                        }
                    } header: {
                        sectionHeader("Quick Actions", subtitle: "No admin password required")
                    }

                    Section {
                        ForEach(Array(manager.tasks.enumerated()), id: \.element.task.id) { index, item in
                            if item.task.requiresAdmin && !isSpaceRecoveryTask(item.task) {
                                MaintenanceTaskRow(
                                    task: item.task,
                                    status: item.status,
                                    isSelected: $manager.tasks[index].isSelected,
                                    isRunning: manager.isRunningAll
                                )
                            }
                        }
                    } header: {
                        sectionHeader("Admin Actions", subtitle: "Requires your password")
                    }

                    Section {
                        ForEach(Array(manager.tasks.enumerated()), id: \.element.task.id) { index, item in
                            if isSpaceRecoveryTask(item.task) {
                                MaintenanceTaskRow(
                                    task: item.task,
                                    status: item.status,
                                    isSelected: $manager.tasks[index].isSelected,
                                    isRunning: manager.isRunningAll
                                )
                            }
                        }
                    } header: {
                        sectionHeader("Space Recovery", subtitle: "Reclaim hidden disk space")
                    }
                }
                .padding()
            }
        }
        .alert("Run Maintenance Tasks?", isPresented: $showRunConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Run \(manager.selectedCount) Task\(manager.selectedCount == 1 ? "" : "s")", role: .destructive) {
                manager.runSelected()
            }
        } message: {
            let selected = manager.tasks.filter(\.isSelected)
            let names = selected.map(\.task.name).joined(separator: ", ")
            let hasAdmin = selected.contains(where: \.task.requiresAdmin)
            Text("\(names)\(hasAdmin ? "\n\nSome tasks require your admin password." : "")")
        }
    }

    private func isSpaceRecoveryTask(_ task: MaintenanceTask) -> Bool {
        task.name == "Clear Time Machine Snapshots" || task.name == "Free APFS Purgeable Space"
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
    @Binding var isSelected: Bool
    let isRunning: Bool

    var body: some View {
        HStack(spacing: 12) {
            // Checkbox for selection (hide during/after run)
            if status == .idle {
                Toggle("", isOn: $isSelected)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .disabled(isRunning)
            }

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
                    if let estimate = task.estimate {
                        Text(estimate)
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundStyle(task.iconColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(task.iconColor.opacity(0.12)))
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

            // Status indicator
            switch status {
            case .idle:
                EmptyView()
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
