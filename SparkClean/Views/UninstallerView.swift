//
//  UninstallerView.swift
//  SparkClean
//
//  Created by George Khananaev on 3/6/26.
//

import SwiftUI
import AppKit

// MARK: - Uninstaller Manager

@Observable
class UninstallerManager {
    var apps: [AppInfo] = []
    var isScanning = false
    var scanComplete = false
    var searchQuery = ""
    var sortOrder: AppSortOrder = .totalSize
    var selectedAppIDs: Set<UUID> = []
    var currentScanItem = ""
    var scanProgress: Double = 0

    var filteredApps: [AppInfo] {
        var result = apps
        if !searchQuery.isEmpty {
            result = result.filter {
                $0.name.localizedCaseInsensitiveContains(searchQuery) ||
                $0.bundleID.localizedCaseInsensitiveContains(searchQuery)
            }
        }
        switch sortOrder {
        case .name: result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .totalSize: result.sort { $0.totalSize > $1.totalSize }
        case .appSize: result.sort { $0.appSize > $1.appSize }
        case .relatedSize: result.sort { $0.totalRelatedSize > $1.totalRelatedSize }
        }
        return result
    }

    // MARK: - Scan All Apps

    func scanApps() async {
        await MainActor.run {
            isScanning = true
            scanComplete = false
            apps = []
            selectedAppIDs = []
            scanProgress = 0
            currentScanItem = "Finding applications..."
        }

        let foundApps = await withCheckedContinuation { (continuation: CheckedContinuation<[AppInfo], Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let fm = FileManager.default
                let home = NSHomeDirectory()
                let appDirs = ["/Applications", "\(home)/Applications"]

                let systemBundles: Set<String> = [
                    "com.apple.Safari", "com.apple.mail", "com.apple.iChat",
                    "com.apple.FaceTime", "com.apple.Maps", "com.apple.Photos",
                    "com.apple.Music", "com.apple.TV", "com.apple.news",
                    "com.apple.stocks", "com.apple.podcasts", "com.apple.iBooksX",
                    "com.apple.AppStore", "com.apple.systempreferences",
                    "com.apple.Preview", "com.apple.TextEdit", "com.apple.calculator",
                    "com.apple.Dictionary", "com.apple.FontBook",
                    "com.apple.keychainaccess", "com.apple.Terminal",
                    "com.apple.ActivityMonitor", "com.apple.Console",
                    "com.apple.DiskUtility", "com.apple.MigrateAssistant",
                    "com.apple.Automator", "com.apple.dt.Xcode",
                    "com.apple.finder", "com.apple.Siri",
                ]

                var results: [AppInfo] = []

                for dir in appDirs where fm.fileExists(atPath: dir) {
                    guard let contents = try? fm.contentsOfDirectory(
                        at: URL(fileURLWithPath: dir),
                        includingPropertiesForKeys: [.isPackageKey],
                        options: [.skipsHiddenFiles]
                    ) else { continue }

                    for url in contents where url.pathExtension == "app" {
                        let bundle = Bundle(url: url)
                        let bundleID = bundle?.bundleIdentifier ?? ""

                        // Skip system apps
                        if systemBundles.contains(bundleID) { continue }
                        if bundleID.hasPrefix("com.apple.") { continue }

                        let appName = url.deletingPathExtension().lastPathComponent
                        let icon = NSWorkspace.shared.icon(forFile: url.path)

                        let info = AppInfo(
                            name: appName,
                            bundleID: bundleID,
                            path: url.path,
                            icon: icon
                        )
                        results.append(info)
                    }
                }

                continuation.resume(returning: results)
            }
        }

        // Calculate sizes for each app
        let total = foundApps.count
        for (index, app) in foundApps.enumerated() {
            await MainActor.run {
                currentScanItem = app.name
                scanProgress = Double(index) / Double(max(total, 1))
            }

            let sized = await calculateAppSize(app)
            await MainActor.run {
                apps.append(sized)
            }
        }

        await MainActor.run {
            isScanning = false
            scanComplete = true
            currentScanItem = ""
            scanProgress = 1.0
        }
    }

    // MARK: - Calculate App Size + Related Data

    private func calculateAppSize(_ app: AppInfo) async -> AppInfo {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let fm = FileManager.default
                let home = NSHomeDirectory()
                var info = app

                // App bundle size
                info.appSize = Self.dirSize(app.path)

                // Find all related paths
                var related: [RelatedPath] = []
                let bundleID = app.bundleID
                let appName = app.name

                if !bundleID.isEmpty {
                    // Caches
                    let cachePath = "\(home)/Library/Caches/\(bundleID)"
                    if fm.fileExists(atPath: cachePath) {
                        let sz = Self.dirSize(cachePath)
                        if sz > 0 { related.append(RelatedPath(path: cachePath, category: "Caches", size: sz, fileCount: Self.fileCount(cachePath))) }
                    }

                    // Application Support (by bundle ID)
                    let supportPath = "\(home)/Library/Application Support/\(bundleID)"
                    if fm.fileExists(atPath: supportPath) {
                        let sz = Self.dirSize(supportPath)
                        if sz > 0 { related.append(RelatedPath(path: supportPath, category: "App Support", size: sz, fileCount: Self.fileCount(supportPath))) }
                    }

                    // Preferences
                    let prefsPath = "\(home)/Library/Preferences/\(bundleID).plist"
                    if fm.fileExists(atPath: prefsPath) {
                        let sz = (try? fm.attributesOfItem(atPath: prefsPath)[.size] as? Int64) ?? 0
                        if sz > 0 { related.append(RelatedPath(path: prefsPath, category: "Preferences", size: sz, fileCount: 1)) }
                    }

                    // Containers
                    let containerPath = "\(home)/Library/Containers/\(bundleID)"
                    if fm.fileExists(atPath: containerPath) {
                        let sz = Self.dirSize(containerPath)
                        if sz > 0 { related.append(RelatedPath(path: containerPath, category: "Container", size: sz, fileCount: Self.fileCount(containerPath))) }
                    }

                    // Group Containers
                    let groupDir = "\(home)/Library/Group Containers"
                    if let groups = try? fm.contentsOfDirectory(atPath: groupDir) {
                        for group in groups where group.contains(bundleID) {
                            let groupPath = (groupDir as NSString).appendingPathComponent(group)
                            let sz = Self.dirSize(groupPath)
                            if sz > 0 { related.append(RelatedPath(path: groupPath, category: "Group Container", size: sz, fileCount: Self.fileCount(groupPath))) }
                        }
                    }

                    // Saved Application State
                    let statePath = "\(home)/Library/Saved Application State/\(bundleID).savedState"
                    if fm.fileExists(atPath: statePath) {
                        let sz = Self.dirSize(statePath)
                        if sz > 0 { related.append(RelatedPath(path: statePath, category: "Saved State", size: sz, fileCount: Self.fileCount(statePath))) }
                    }

                    // Logs
                    let logsPath = "\(home)/Library/Logs/\(bundleID)"
                    if fm.fileExists(atPath: logsPath) {
                        let sz = Self.dirSize(logsPath)
                        if sz > 0 { related.append(RelatedPath(path: logsPath, category: "Logs", size: sz, fileCount: Self.fileCount(logsPath))) }
                    }

                    // Crash Reports
                    let crashDir = "\(home)/Library/Logs/DiagnosticReports"
                    if let crashes = try? fm.contentsOfDirectory(atPath: crashDir) {
                        var crashSize: Int64 = 0
                        var crashCount = 0
                        for file in crashes where file.contains(appName) || file.contains(bundleID) {
                            let fullPath = (crashDir as NSString).appendingPathComponent(file)
                            if let attrs = try? fm.attributesOfItem(atPath: fullPath), let sz = attrs[.size] as? Int64 {
                                crashSize += sz
                                crashCount += 1
                            }
                        }
                        if crashSize > 0 {
                            related.append(RelatedPath(path: crashDir, category: "Crash Reports", size: crashSize, fileCount: crashCount))
                        }
                    }

                    // WebKit data
                    let webkitPath = "\(home)/Library/WebKit/\(bundleID)"
                    if fm.fileExists(atPath: webkitPath) {
                        let sz = Self.dirSize(webkitPath)
                        if sz > 0 { related.append(RelatedPath(path: webkitPath, category: "WebKit Data", size: sz, fileCount: Self.fileCount(webkitPath))) }
                    }

                    // HTTPStorages
                    let httpPath = "\(home)/Library/HTTPStorages/\(bundleID)"
                    if fm.fileExists(atPath: httpPath) {
                        let sz = Self.dirSize(httpPath)
                        if sz > 0 { related.append(RelatedPath(path: httpPath, category: "HTTP Storage", size: sz, fileCount: Self.fileCount(httpPath))) }
                    }
                }

                // Application Support by app name (some apps use name instead of bundle ID)
                if !appName.isEmpty {
                    let supportByName = "\(home)/Library/Application Support/\(appName)"
                    let alreadyFound = related.contains { $0.path == supportByName }
                    if !alreadyFound && fm.fileExists(atPath: supportByName) {
                        let sz = Self.dirSize(supportByName)
                        if sz > 0 { related.append(RelatedPath(path: supportByName, category: "App Support", size: sz, fileCount: Self.fileCount(supportByName))) }
                    }

                    // Caches by app name
                    let cacheByName = "\(home)/Library/Caches/\(appName)"
                    let cacheAlreadyFound = related.contains { $0.path == cacheByName }
                    if !cacheAlreadyFound && fm.fileExists(atPath: cacheByName) {
                        let sz = Self.dirSize(cacheByName)
                        if sz > 0 { related.append(RelatedPath(path: cacheByName, category: "Caches", size: sz, fileCount: Self.fileCount(cacheByName))) }
                    }

                    // Logs by app name
                    let logsByName = "\(home)/Library/Logs/\(appName)"
                    let logsAlreadyFound = related.contains { $0.path == logsByName }
                    if !logsAlreadyFound && fm.fileExists(atPath: logsByName) {
                        let sz = Self.dirSize(logsByName)
                        if sz > 0 { related.append(RelatedPath(path: logsByName, category: "Logs", size: sz, fileCount: Self.fileCount(logsByName))) }
                    }
                }

                // Known app data paths (non-standard locations)
                if let knownPaths = KnownAppData.paths[bundleID] {
                    for entry in knownPaths {
                        let expandedPath = entry.path.replacingOccurrences(of: "~", with: home)
                        guard fm.fileExists(atPath: expandedPath) else { continue }
                        guard !related.contains(where: { $0.path == expandedPath }) else { continue }

                        var dirSize: Int64 = 0
                        var dirCount = 0
                        if let enumerator = fm.enumerator(
                            at: URL(fileURLWithPath: expandedPath),
                            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey],
                            options: [], errorHandler: nil
                        ) {
                            for case let fileURL as URL in enumerator {
                                if let rv = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]),
                                   rv.isRegularFile == true {
                                    dirSize += Int64(rv.totalFileAllocatedSize ?? 0)
                                    dirCount += 1
                                }
                            }
                        }

                        if dirSize > 0 {
                            let label = entry.safetyNote.isEmpty ? entry.description : "\(entry.description) \u{26a0}\u{fe0f} \(entry.safetyNote)"
                            related.append(RelatedPath(path: expandedPath, category: label, size: dirSize, fileCount: dirCount))
                        }
                    }
                }

                // Dotfile auto-discovery for apps not in known map
                if KnownAppData.paths[bundleID] == nil {
                    let homeURL = URL(fileURLWithPath: home)
                    let appNameLower = appName.lowercased().replacingOccurrences(of: " ", with: "")
                    let bundleSuffix = bundleID.components(separatedBy: ".").last?.lowercased() ?? ""

                    if let homeContents = try? fm.contentsOfDirectory(at: homeURL, includingPropertiesForKeys: [.isDirectoryKey], options: []) {
                        for url in homeContents {
                            let name = url.lastPathComponent
                            guard name.hasPrefix(".") else { continue }
                            guard let rv = try? url.resourceValues(forKeys: [.isDirectoryKey]),
                                  rv.isDirectory == true else { continue }

                            let dirName = String(name.dropFirst()).lowercased()
                            guard dirName.contains(appNameLower) || (!bundleSuffix.isEmpty && dirName.contains(bundleSuffix)) else { continue }
                            guard !related.contains(where: { $0.path == url.path }) else { continue }

                            var dirSize: Int64 = 0
                            var dirCount = 0
                            if let enumerator = fm.enumerator(
                                at: url,
                                includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey],
                                options: [], errorHandler: nil
                            ) {
                                for case let fileURL as URL in enumerator {
                                    if let rv2 = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]),
                                       rv2.isRegularFile == true {
                                        dirSize += Int64(rv2.totalFileAllocatedSize ?? 0)
                                        dirCount += 1
                                    }
                                }
                            }

                            if dirSize > 10_000_000 {
                                related.append(RelatedPath(path: url.path, category: "Possible App Data (Home Directory)", size: dirSize, fileCount: dirCount))
                            }
                        }
                    }
                }

                info.relatedPaths = related.sorted { $0.size > $1.size }
                info.totalRelatedSize = related.reduce(0) { $0 + $1.size }

                continuation.resume(returning: info)
            }
        }
    }

    // MARK: - Uninstall

    func uninstallApp(_ app: AppInfo, trashOnly: Bool = true) async -> Bool {
        // Check if app is running
        let runningApps = NSWorkspace.shared.runningApplications
        if let running = runningApps.first(where: { $0.bundleIdentifier == app.bundleID }) {
            running.terminate()
            // Give it a moment to quit
            try? await Task.sleep(for: .seconds(1))
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let fm = FileManager.default
                var success = true

                // Remove related data first
                for related in app.relatedPaths {
                    let url = URL(fileURLWithPath: related.path)
                    if trashOnly {
                        if (try? fm.trashItem(at: url, resultingItemURL: nil)) == nil {
                            do { try fm.removeItem(at: url) } catch { success = false }
                        }
                    } else {
                        do { try fm.removeItem(at: url) } catch { success = false }
                    }
                }

                // Remove app bundle
                let appURL = URL(fileURLWithPath: app.path)
                if trashOnly {
                    if (try? fm.trashItem(at: appURL, resultingItemURL: nil)) == nil {
                        do { try fm.removeItem(at: appURL) } catch { success = false }
                    }
                } else {
                    do { try fm.removeItem(at: appURL) } catch { success = false }
                }

                continuation.resume(returning: success)
            }
        }
    }

    // MARK: - Export Report

    func exportReport(verbose: Bool) -> String {
        let dateStr = Date().formatted(date: .long, time: .standard)
        var r = """
        ╔═══════════════════════════════════════════════════════════════════╗
        ║  SparkClean - App Uninstaller Audit Report                      ║
        ║  Generated: \(dateStr)\(String(repeating: " ", count: max(0, 40 - dateStr.count)))║
        ╚═══════════════════════════════════════════════════════════════════╝

        """

        r += "SUMMARY\n"
        r += String(repeating: "─", count: 60) + "\n"
        r += "  Total Apps Scanned:  \(apps.count)\n"

        let totalAppSize = apps.reduce(0 as Int64) { $0 + $1.appSize }
        let totalRelated = apps.reduce(0 as Int64) { $0 + $1.totalRelatedSize }
        let totalAll = apps.reduce(0 as Int64) { $0 + $1.totalSize }

        r += "  Total App Bundles:   \(CleanupManager.formatBytes(totalAppSize))\n"
        r += "  Total Related Data:  \(CleanupManager.formatBytes(totalRelated))\n"
        r += "  Grand Total:         \(CleanupManager.formatBytes(totalAll))\n\n"

        r += "═══════════════════════════════════════════════════════════════════\n"
        r += "INSTALLED APPLICATIONS (sorted by total size)\n"
        r += "═══════════════════════════════════════════════════════════════════\n\n"

        let sorted = apps.sorted { $0.totalSize > $1.totalSize }

        for (idx, app) in sorted.enumerated() {
            r += "┌─── \(idx + 1). \(app.name)\n"
            r += "│  Bundle ID:    \(app.bundleID)\n"
            r += "│  App Path:     \(app.path)\n"
            r += "│  App Size:     \(CleanupManager.formatBytes(app.appSize))\n"
            r += "│  Related Data: \(CleanupManager.formatBytes(app.totalRelatedSize))\n"
            r += "│  Total Size:   \(CleanupManager.formatBytes(app.totalSize))\n"

            if app.relatedPaths.isEmpty {
                r += "│  Related Files: None found\n"
            } else {
                r += "│  Related Files (\(app.relatedPaths.count) locations):\n"
                for related in app.relatedPaths {
                    r += "│    ┊ [\(related.category)]\n"
                    r += "│    ┊   Path:  \(related.path)\n"
                    r += "│    ┊   Size:  \(CleanupManager.formatBytes(related.size))\n"
                    r += "│    ┊   Files: \(related.fileCount)\n"
                }
            }

            r += "└" + String(repeating: "─", count: 60) + "\n\n"
        }

        // Top consumers
        r += "═══════════════════════════════════════════════════════════════════\n"
        r += "TOP 10 LARGEST APPS (by total disk usage)\n"
        r += "═══════════════════════════════════════════════════════════════════\n\n"

        for (idx, app) in sorted.prefix(10).enumerated() {
            let bar = String(repeating: "█", count: max(1, Int(Double(app.totalSize) / Double(max(sorted.first?.totalSize ?? 1, 1)) * 30)))
            r += "  \(String(format: "%2d", idx + 1)). \(app.name.padding(toLength: 25, withPad: " ", startingAt: 0)) \(CleanupManager.formatBytes(app.totalSize).padding(toLength: 10, withPad: " ", startingAt: 0)) \(bar)\n"
        }

        r += "\n═══════════════════════════════════════════════════════════════════\n"
        r += "TOP 10 APPS WITH MOST RELATED DATA\n"
        r += "═══════════════════════════════════════════════════════════════════\n\n"

        let sortedByRelated = apps.sorted { $0.totalRelatedSize > $1.totalRelatedSize }
        for (idx, app) in sortedByRelated.prefix(10).enumerated() where app.totalRelatedSize > 0 {
            r += "  \(String(format: "%2d", idx + 1)). \(app.name.padding(toLength: 25, withPad: " ", startingAt: 0)) \(CleanupManager.formatBytes(app.totalRelatedSize).padding(toLength: 10, withPad: " ", startingAt: 0)) (\(app.relatedPaths.count) locations)\n"
        }

        r += "\n═══════════════════════════════════════════════════════════════════\n"
        r += "END OF UNINSTALLER REPORT\n"
        r += "═══════════════════════════════════════════════════════════════════\n"

        return r
    }

    // MARK: - Helpers

    private static func dirSize(_ path: String) -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey],
            options: [],
            errorHandler: nil
        ) else { return 0 }

        for case let url as URL in enumerator {
            guard let rv = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey]) else { continue }
            if rv.isRegularFile == true {
                total += Int64(rv.totalFileAllocatedSize ?? rv.fileSize ?? 0)
            }
        }
        return total
    }

    private static func fileCount(_ path: String) -> Int {
        let fm = FileManager.default
        var count = 0
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [],
            errorHandler: nil
        ) else { return 0 }
        for case let url as URL in enumerator {
            if let rv = try? url.resourceValues(forKeys: [.isRegularFileKey]), rv.isRegularFile == true {
                count += 1
            }
        }
        return count
    }
}

// MARK: - Uninstaller View

struct UninstallerView: View {
    @State private var uninstaller = UninstallerManager()
    @State private var selectedApp: AppInfo? = nil
    @State private var showUninstallAlert = false
    @State private var appToUninstall: AppInfo? = nil
    @State private var showExportSheet = false
    @State private var isUninstalling = false
    @State private var exportReport = ""
    @State private var isGeneratingReport = false
    @State private var lastUninstalledApp: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerSection

            Divider()

            if let appName = lastUninstalledApp {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("\"\(appName)\" moved to Trash")
                        .font(.callout)
                    Spacer()
                    Button("Open Trash") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.Trash"))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button {
                        lastUninstalledApp = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color.green.opacity(0.08))
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if uninstaller.scanComplete {
                HSplitView {
                    // App list
                    appListSection
                        .frame(minWidth: 340, idealWidth: 400)

                    // Detail panel
                    if let app = selectedApp {
                        appDetailSection(app)
                            .frame(minWidth: 420, idealWidth: 500, maxWidth: .infinity)
                    } else {
                        VStack {
                            Spacer()
                            Text("Select an app to view details")
                                .foregroundStyle(.tertiary)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            } else if uninstaller.isScanning {
                scanningSection
            } else {
                welcomeSection
            }
        }
        .alert("Uninstall App?", isPresented: $showUninstallAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Trash", role: .destructive) {
                if let app = appToUninstall {
                    Task {
                        isUninstalling = true
                        let success = await uninstaller.uninstallApp(app)
                        if success {
                            selectedApp = nil
                            uninstaller.apps.removeAll(where: { $0.id == app.id })
                            lastUninstalledApp = app.name
                            // Auto-dismiss the banner after 5 seconds
                            Task {
                                try? await Task.sleep(for: .seconds(5))
                                if lastUninstalledApp == app.name {
                                    lastUninstalledApp = nil
                                }
                            }
                        }
                        isUninstalling = false
                    }
                }
            }
        } message: {
            if let app = appToUninstall {
                Text("This will move \"\(app.name)\" and all its related data (\(CleanupManager.formatBytes(app.totalSize))) to Trash.\n\nRelated files: \(app.relatedPaths.count) locations")
            }
        }
        .sheet(isPresented: $showExportSheet) {
            ExportReportView(report: $exportReport, isGenerating: $isGeneratingReport)
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 14) {
            Image(systemName: "trash.square")
                .font(.title2)
                .foregroundStyle(.red)

            VStack(alignment: .leading, spacing: 2) {
                Text("App Uninstaller")
                    .font(.title3)
                    .fontWeight(.bold)
                if uninstaller.scanComplete {
                    Text("\(uninstaller.apps.count) apps found")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if uninstaller.scanComplete {
                // Search
                TextField("Search apps...", text: $uninstaller.searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)

            }

            Button {
                Task { await uninstaller.scanApps() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                    Text(uninstaller.isScanning ? "Scanning..." : (uninstaller.scanComplete ? "Rescan" : "Scan Apps"))
                        .font(.system(size: 13, weight: .semibold))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
            }
            .buttonStyle(.borderedProminent)
            .disabled(uninstaller.isScanning)

            if uninstaller.scanComplete {
                Menu {
                    Button("Export Report...") {
                        exportReport = uninstaller.exportReport(verbose: true)
                        isGeneratingReport = false
                        showExportSheet = true
                    }
                    Divider()
                    Button("Sort by Name") { uninstaller.sortOrder = .name }
                    Button("Sort by Total Size") { uninstaller.sortOrder = .totalSize }
                    Button("Sort by App Size") { uninstaller.sortOrder = .appSize }
                    Button("Sort by Related Data") { uninstaller.sortOrder = .relatedSize }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 14))
                }
                .menuStyle(.borderlessButton)
                .frame(width: 30)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    // MARK: - App List

    private var appListSection: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(uninstaller.filteredApps) { app in
                    AppRowView(
                        app: app,
                        isSelected: selectedApp?.id == app.id
                    ) {
                        selectedApp = app
                    }
                }
            }
            .padding(12)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - App Detail

    private func appDetailSection(_ app: AppInfo) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // App header
                HStack(spacing: 16) {
                    if let icon = app.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 64, height: 64)
                            .cornerRadius(14)
                            .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(app.name)
                            .font(.title2)
                            .fontWeight(.bold)

                        Text(app.bundleID)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)

                        Text(app.path)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }

                    Spacer()
                }

                // Size breakdown
                HStack(spacing: 16) {
                    sizeCard("App Bundle", size: app.appSize, color: .blue)
                    sizeCard("Related Data", size: app.totalRelatedSize, color: .orange)
                    sizeCard("Total", size: app.totalSize, color: .red)
                }

                // Related paths
                if !app.relatedPaths.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Related Files & Data")
                            .font(.headline)

                        ForEach(app.relatedPaths) { related in
                            let isLarge = related.size > 1_073_741_824
                            let hasSafetyNote = related.category.contains("\u{26a0}\u{fe0f}")
                            let isPossibleData = related.category.hasPrefix("Possible App Data")
                            let isWarning = isLarge || hasSafetyNote || isPossibleData

                            HStack(spacing: 12) {
                                Image(systemName: isWarning ? "exclamationmark.triangle.fill" : iconForCategory(related.category))
                                    .foregroundStyle(isWarning ? .orange : .secondary)
                                    .frame(width: 20)

                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(related.category)
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundStyle(hasSafetyNote ? .orange : .primary)

                                        if isLarge {
                                            Text("LARGE")
                                                .font(.system(size: 9, weight: .bold))
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1)
                                                .background(Capsule().fill(Color.orange.opacity(0.2)))
                                                .foregroundStyle(.orange)
                                        }

                                        if isPossibleData {
                                            Text("AUTO-DETECTED")
                                                .font(.system(size: 9, weight: .bold))
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1)
                                                .background(Capsule().fill(Color.blue.opacity(0.2)))
                                                .foregroundStyle(.blue)
                                        }
                                    }
                                    Text(related.path)
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }

                                Spacer()

                                Text("\(related.fileCount) files")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)

                                Text(CleanupManager.formatBytes(related.size))
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundStyle(isLarge ? .red : .orange)

                                Button {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: related.path)])
                                } label: {
                                    Image(systemName: "folder")
                                        .font(.caption)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                            }
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(isWarning ? Color.orange.opacity(0.06) : Color.primary.opacity(0.03))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(isWarning ? Color.orange.opacity(0.2) : Color.clear, lineWidth: 1)
                            )
                        }
                    }
                } else {
                    HStack {
                        Image(systemName: "checkmark.circle")
                            .foregroundStyle(.green)
                        Text("No related data found outside the app bundle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                }

                Spacer(minLength: 20)

                // Uninstall button
                HStack {
                    Spacer()
                    Button {
                        appToUninstall = app
                        showUninstallAlert = true
                    } label: {
                        HStack(spacing: 8) {
                            if isUninstalling {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Uninstalling...")
                                    .font(.system(size: 14, weight: .semibold))
                            } else {
                                Image(systemName: "trash")
                                    .font(.system(size: 14, weight: .semibold))
                                Text("Uninstall \(app.name)")
                                    .font(.system(size: 14, weight: .semibold))
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(isUninstalling)
                    Spacer()
                }
            }
            .padding(24)
        }
    }

    private func sizeCard(_ title: String, size: Int64, color: Color) -> some View {
        VStack(spacing: 6) {
            Text(CleanupManager.formatBytes(size))
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(color)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(color.opacity(0.08))
        )
    }

    private func iconForCategory(_ category: String) -> String {
        if category.hasPrefix("Possible App Data") { return "questionmark.folder" }
        if category.contains("AI Models") || category.contains("Stable Diffusion") { return "brain" }
        if category.contains("Virtual Machine") || category.contains("VM") { return "desktopcomputer" }
        if category.contains("Games") { return "gamecontroller" }
        if category.contains("SDK") { return "wrench.and.screwdriver" }
        if category.contains("Docker") { return "cube.box" }
        if category.contains("Profiles") || category.contains("Extensions") { return "person.crop.circle" }

        switch category {
        case "Caches": return "archivebox"
        case "App Support": return "folder.badge.gearshape"
        case "Preferences": return "gearshape"
        case "Container": return "shippingbox"
        case "Group Container": return "square.stack.3d.up"
        case "Saved State": return "rectangle.stack"
        case "Logs": return "doc.text"
        case "Crash Reports": return "exclamationmark.triangle"
        case "WebKit Data": return "globe"
        case "HTTP Storage": return "network"
        default: return "doc"
        }
    }

    // MARK: - Scanning

    private var scanningSection: some View {
        VStack(spacing: 20) {
            Spacer()
            ProgressView(value: uninstaller.scanProgress) {
                Text("Scanning applications...")
                    .font(.headline)
            } currentValueLabel: {
                Text(uninstaller.currentScanItem)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .progressViewStyle(.linear)
            .frame(maxWidth: 400)

            Text("\(Int(uninstaller.scanProgress * 100))%")
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Welcome

    private var welcomeSection: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "trash.square.fill")
                .font(.system(size: 64))
                .foregroundStyle(
                    LinearGradient(colors: [.red, .orange], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            VStack(spacing: 10) {
                Text("App Uninstaller")
                    .font(.title2)
                    .fontWeight(.bold)
                Text("Scan your Mac to find all installed apps and their\nrelated data. Completely remove apps with one click.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - App Row

struct AppRowView: View {
    let app: AppInfo
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 36, height: 36)
                        .cornerRadius(8)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(app.bundleID)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer()

                if app.totalRelatedSize > 0 {
                    Text("+" + CleanupManager.formatBytes(app.totalRelatedSize))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

                Text(CleanupManager.formatBytes(app.totalSize))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(app.totalSize > 500_000_000 ? .red : .secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : (isHovered ? Color.primary.opacity(0.04) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
