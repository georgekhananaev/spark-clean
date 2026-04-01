//
//  CleanupManager.swift
//  SparkClean
//
//  Created by George Khananaev on 3/6/26.
//

import Foundation
import SwiftUI
import AppKit
import Dispatch
import os

// MARK: - CleanupManager

@Observable
class CleanupManager {
    var categories: [CleanupCategory] = []
    var isScanning = false
    var scanComplete = false
    var isCleaning = false
    var cleanComplete = false
    var lastCleanedSize: Int64 = 0
    var lastCleanedCount: Int = 0
    var cleanErrors: [String] = []
    var cleanSuccessCount: Int = 0
    var cleanFailCount: Int = 0
    var currentScanItem = ""
    var scanProgress: Double = 0
    var cleanProgress: Double = 0
    var diskUsage: DiskUsageInfo?
    var lastScanSummary: ScanSummary?
    var searchQuery = ""
    var scanErrors: [String] = []
    var hasFullDiskAccess: Bool = true
    private let cancelLock = OSAllocatedUnfairLock(initialState: false)
    private var scanStartTime: Date?
    private let scannedPathsLock = OSAllocatedUnfairLock(initialState: Set<String>())

    var totalSize: Int64 {
        filteredCategories.filter(\.isSelected).reduce(0) { $0 + $1.selectedSize }
    }

    var totalFiles: Int {
        filteredCategories.filter(\.isSelected).reduce(0) { $0 + $1.selectedFileCount }
    }

    var overallSize: Int64 {
        categories.reduce(0) { $0 + $1.size }
    }

    var selectedCategoryCount: Int {
        filteredCategories.filter(\.isSelected).count
    }

    var filteredCategories: [CleanupCategory] {
        if searchQuery.isEmpty { return categories }
        return categories.filter {
            $0.name.localizedCaseInsensitiveContains(searchQuery) ||
            $0.description.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    func categoriesForGroup(_ group: CategoryGroup) -> [CleanupCategory] {
        filteredCategories.filter { $0.group == group }
    }

    func sizeForGroup(_ group: CategoryGroup) -> Int64 {
        categoriesForGroup(group).reduce(0) { $0 + $1.selectedSize }
    }

    func selectAll(in group: CategoryGroup) {
        for i in categories.indices where categories[i].group == group {
            categories[i].isSelected = true
        }
    }

    func deselectAll(in group: CategoryGroup) {
        for i in categories.indices where categories[i].group == group {
            categories[i].isSelected = false
        }
    }

    func selectAll() {
        for i in categories.indices {
            // Never batch-select caution categories — require explicit individual selection
            if categories[i].safetyLevel != .caution {
                categories[i].isSelected = true
            }
        }
    }

    func deselectAll() {
        for i in categories.indices { categories[i].isSelected = false }
    }

    /// Select only safe categories
    func selectSafeOnly() {
        for i in categories.indices {
            categories[i].isSelected = categories[i].safetyLevel == .safe
        }
    }

    static let home = NSHomeDirectory()

    // MARK: - Protected Paths (NEVER delete these)

    /// Paths that must never be deleted — defense-in-depth against scan bugs
    private static let protectedPaths: Set<String> = {
        let h = NSHomeDirectory()
        return [
            "/", "/System", "/usr", "/bin", "/sbin", "/var", "/etc", "/tmp", "/private",
            "/Applications", "/Library", "/Users",
            h,
            "\(h)/Desktop", "\(h)/Documents", "\(h)/Downloads",
            "\(h)/Pictures", "\(h)/Movies", "\(h)/Music",
            "\(h)/Library", "\(h)/Library/Keychains",
            "\(h)/Library/Safari",
            "\(h)/Library/Mail", "\(h)/Library/Preferences",
            "\(h)/Library/Application Support",
            "\(h)/Library/Accounts", "\(h)/Library/Cookies",
            "\(h)/Library/Containers", "\(h)/Library/Group Containers",
            "\(h)/.ssh", "\(h)/.gnupg",
        ]
    }()

    /// Prefixes that are always off-limits
    private static let forbiddenPrefixes: [String] = [
        "/System/", "/usr/", "/bin/", "/sbin/", "/private/var/db/",
    ]

    /// Validate that a path is safe to delete
    private static func isSafePath(_ path: String) -> Bool {
        let resolved = (path as NSString).resolvingSymlinksInPath
        // Never delete a protected root path
        if protectedPaths.contains(resolved) { return false }
        // Never delete anything under forbidden prefixes
        for prefix in forbiddenPrefixes {
            if resolved.hasPrefix(prefix) { return false }
        }
        // Require minimum depth (at least 3 components: / Users / name / something)
        let components = resolved.split(separator: "/")
        if components.count < 3 { return false }
        return true
    }

    // MARK: - Memory Pressure Monitoring

    private var memoryPressureSource: DispatchSourceMemoryPressure?

    func startMemoryMonitoring() {
        memoryPressureSource = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .global(qos: .utility)
        )
        memoryPressureSource?.setEventHandler { [weak self] in
            guard let self else { return }
            let event = self.memoryPressureSource?.data ?? []
            if event.contains(.critical) {
                // Emergency: cancel scan immediately
                self.cancelLock.withLock { $0 = true }
                self.resetScannedPaths()
                Task { @MainActor in
                    self.scanErrors.append("Scan cancelled: system memory pressure critical")
                }
            } else if event.contains(.warning) {
                // Warning: just log it — the autoreleasepool fixes should handle this
                Task { @MainActor in
                    self.scanErrors.append("Warning: elevated memory pressure detected")
                }
            }
        }
        memoryPressureSource?.resume()
    }

    func stopMemoryMonitoring() {
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
    }

    // MARK: - Deletion Audit Log

    private static func writeDeletionLog(entries: [(path: String, size: Int64, trashedOrDeleted: String)]) {
        guard !entries.isEmpty else { return }
        let logDir = "\(home)/Library/Logs/SparkClean"
        let fm = FileManager.default
        try? fm.createDirectory(atPath: logDir, withIntermediateDirectories: true)

        let dateStr = Self.isoFormatter.string(from: Date())
        let logPath = "\(logDir)/cleanup-\(dateStr.replacingOccurrences(of: ":", with: "-")).log"

        var log = "SparkClean Deletion Log — \(dateStr)\n"
        log += String(repeating: "─", count: 60) + "\n"
        for entry in entries {
            log += "[\(entry.trashedOrDeleted)] \(formatBytes(entry.size).padding(toLength: 10, withPad: " ", startingAt: 0)) \(entry.path)\n"
        }
        log += String(repeating: "─", count: 60) + "\n"
        log += "Total: \(entries.count) items\n"

        try? log.write(toFile: logPath, atomically: true, encoding: .utf8)
    }

    // MARK: - Settings

    private var settingScanDocker: Bool {
        UserDefaults.standard.object(forKey: "scanDocker") as? Bool ?? true
    }
    private var settingScanNodeModules: Bool {
        UserDefaults.standard.object(forKey: "scanNodeModules") as? Bool ?? true
    }
    private var settingScanUnusedApps: Bool {
        UserDefaults.standard.object(forKey: "scanUnusedApps") as? Bool ?? true
    }
    private var settingUnusedAppThresholdDays: Int {
        let v = UserDefaults.standard.integer(forKey: "unusedAppThresholdDays")
        return v > 0 ? v : 90
    }
    private var settingLargeFileThresholdMB: Int {
        let v = UserDefaults.standard.integer(forKey: "largeFileThresholdMB")
        return v > 0 ? v : 50
    }
    private var settingOldFileThresholdDays: Int {
        let v = UserDefaults.standard.integer(forKey: "oldFileThresholdDays")
        return v > 0 ? v : 30
    }
    private var settingScreenshotThresholdDays: Int {
        let v = UserDefaults.standard.integer(forKey: "screenshotThresholdDays")
        return v > 0 ? v : 30
    }
    private var settingPreferTrash: Bool {
        UserDefaults.standard.object(forKey: "preferTrash") as? Bool ?? true
    }
    private var settingScanLargeFiles: Bool {
        UserDefaults.standard.object(forKey: "scanLargeFiles") as? Bool ?? true
    }
    private var settingLargeFileScanDirs: [String] {
        var dirs: [String] = []
        if UserDefaults.standard.object(forKey: "largeFileScanDownloads") as? Bool ?? true { dirs.append("\(Self.home)/Downloads") }
        if UserDefaults.standard.object(forKey: "largeFileScanDesktop") as? Bool ?? true { dirs.append("\(Self.home)/Desktop") }
        if UserDefaults.standard.object(forKey: "largeFileScanDocuments") as? Bool ?? true { dirs.append("\(Self.home)/Documents") }
        if UserDefaults.standard.object(forKey: "largeFileScanMovies") as? Bool ?? true { dirs.append("\(Self.home)/Movies") }
        if UserDefaults.standard.object(forKey: "largeFileScanMusic") as? Bool ?? true { dirs.append("\(Self.home)/Music") }
        if UserDefaults.standard.object(forKey: "largeFileScanPictures") as? Bool ?? true { dirs.append("\(Self.home)/Pictures") }
        return dirs
    }
    private var settingLargeFileIncludeVideos: Bool {
        UserDefaults.standard.object(forKey: "largeFileIncludeVideos") as? Bool ?? true
    }
    private var settingLargeFileIncludeImages: Bool {
        UserDefaults.standard.object(forKey: "largeFileIncludeImages") as? Bool ?? true
    }
    private var settingLargeFileIncludeArchives: Bool {
        UserDefaults.standard.object(forKey: "largeFileIncludeArchives") as? Bool ?? true
    }
    private var settingLargeFileIncludeInstallers: Bool {
        UserDefaults.standard.object(forKey: "largeFileIncludeInstallers") as? Bool ?? true
    }
    private var settingLargeFileIncludeAudio: Bool {
        UserDefaults.standard.object(forKey: "largeFileIncludeAudio") as? Bool ?? true
    }
    private var settingLargeFileIncludeOther: Bool {
        UserDefaults.standard.object(forKey: "largeFileIncludeOther") as? Bool ?? true
    }
    private var settingLargeFileMaxAgeDays: Int {
        UserDefaults.standard.integer(forKey: "largeFileMaxAgeDays")
    }
    private var settingLargeFileMaxResults: Int {
        let v = UserDefaults.standard.integer(forKey: "largeFileMaxResults")
        return v > 0 ? v : 100
    }
    private var settingScanVirtualEnvironments: Bool {
        UserDefaults.standard.object(forKey: "scanVirtualEnvironments") as? Bool ?? true
    }
    private var settingScreenRecordingThresholdDays: Int {
        let v = UserDefaults.standard.integer(forKey: "screenRecordingThresholdDays")
        return v > 0 ? v : 60
    }
    private var settingScanIOSBackups: Bool {
        UserDefaults.standard.object(forKey: "scanIOSBackups") as? Bool ?? true
    }
    private var settingScanIMessageAttachments: Bool {
        UserDefaults.standard.object(forKey: "scanIMessageAttachments") as? Bool ?? true
    }
    private var settingScanBrokenSymlinks: Bool {
        UserDefaults.standard.object(forKey: "scanBrokenSymlinks") as? Bool ?? true
    }
    private var settingScanScreenRecordings: Bool {
        UserDefaults.standard.object(forKey: "scanScreenRecordings") as? Bool ?? true
    }


    // MARK: - Scan Definitions
    //
    // SAFETY RULES:
    // - .safe = caches, logs, temp files — rebuilt automatically, no data loss
    // - .review = user files (downloads, screenshots) — might be wanted
    // - .caution = app data, backups — could break things
    //
    // Only .safe categories are selected by default.

    private let scanDefinitions: [ScanDefinition] = [

        // ═══════════ SYSTEM (safe caches & logs) ═══════════

        ScanDefinition(name: "Temp Files", icon: "clock.arrow.circlepath", color: .red,
            description: "macOS temporary directory files — rebuilt automatically",
            group: .system, safetyLevel: .safe) {
            // Resolve symlinks to avoid duplicates (/tmp -> /private/tmp)
            var resolved = Set<String>()
            for p in [NSTemporaryDirectory(), "/tmp", "/private/var/tmp", "/private/tmp"] {
                let canonical = (p as NSString).resolvingSymlinksInPath
                resolved.insert(canonical)
            }
            return Array(resolved)
        },

        ScanDefinition(name: "System Logs", icon: "doc.text", color: .green,
            description: "Old log files — safe to remove, new logs will be created",
            group: .system, safetyLevel: .safe) {
            // Exclude DiagnosticReports subdirectory (scanned separately)
            ["\(home)/Library/Logs", "/Library/Logs"]
        },

        ScanDefinition(name: "Crash Reports", icon: "exclamationmark.triangle", color: .orange,
            description: "App crash reports and diagnostics — safe to remove",
            group: .system, safetyLevel: .safe) {
            ["\(home)/Library/Logs/DiagnosticReports", "/Library/Logs/DiagnosticReports"]
        },

        ScanDefinition(name: "Saved App State", icon: "rectangle.stack", color: .indigo,
            description: "Window positions for app resume — apps will just open fresh",
            group: .system, safetyLevel: .safe) {
            ["\(home)/Library/Saved Application State"]
        },

        ScanDefinition(name: "macOS Update Cache", icon: "arrow.down.circle", color: .blue,
            description: "Already-installed macOS update files",
            group: .system, safetyLevel: .safe) {
            ["/Library/Updates", "\(home)/Library/Caches/com.apple.SoftwareUpdate"]
        },

        ScanDefinition(name: "Trash", icon: "trash", color: .gray,
            description: "Items already in your Trash — empty to reclaim space",
            group: .system, safetyLevel: .review, defaultSelected: false) {
            ["\(home)/.Trash"]
        },

        // ═══════════ BROWSERS (safe — caches rebuild) ═══════════

        ScanDefinition(name: "Safari Cache", icon: "safari", color: .cyan,
            description: "Safari browser cache — will be rebuilt as you browse",
            group: .browsers, safetyLevel: .safe) {
            ["\(home)/Library/Caches/com.apple.Safari",
             "\(home)/Library/Caches/com.apple.Safari.SearchHelper",
             "\(home)/Library/Caches/com.apple.WebKit.Networking"]
        },

        ScanDefinition(name: "Chrome Cache", icon: "globe", color: .yellow,
            description: "Chrome cache, GPU cache, service workers — rebuilt automatically",
            group: .browsers, safetyLevel: .safe) {
            var paths = [
                "\(home)/Library/Caches/Google/Chrome",
                "\(home)/Library/Application Support/Google/Chrome/Default/Service Worker",
                "\(home)/Library/Application Support/Google/Chrome/Default/GPUCache",
                "\(home)/Library/Application Support/Google/Chrome/Default/Code Cache",
                "\(home)/Library/Application Support/Google/Chrome/Default/Cache",
                "\(home)/Library/Application Support/Google/Chrome/ShaderCache",
                "\(home)/Library/Application Support/Google/Chrome/GrShaderCache",
            ]
            // Dynamically discover all Chrome profile directories
            let chromeAppSupport = "\(home)/Library/Application Support/Google/Chrome"
            if let entries = try? FileManager.default.contentsOfDirectory(atPath: chromeAppSupport) {
                for entry in entries where entry.hasPrefix("Profile ") {
                    paths.append("\(chromeAppSupport)/\(entry)/Cache")
                    paths.append("\(chromeAppSupport)/\(entry)/Code Cache")
                    paths.append("\(chromeAppSupport)/\(entry)/Service Worker")
                    paths.append("\(chromeAppSupport)/\(entry)/GPUCache")
                }
            }
            return paths
        },

        ScanDefinition(name: "Firefox Cache", icon: "flame", color: .orange,
            description: "Firefox cache and crash reports",
            group: .browsers, safetyLevel: .safe) {
            ["\(home)/Library/Caches/Firefox",
             "\(home)/Library/Caches/org.mozilla.firefox",
             "\(home)/Library/Application Support/Firefox/Crash Reports"]
        },

        ScanDefinition(name: "Arc Cache", icon: "compass.drawing", color: .blue,
            description: "Arc browser cache",
            group: .browsers, safetyLevel: .safe) {
            ["\(home)/Library/Caches/company.thebrowser.Browser",
             "\(home)/Library/Application Support/Arc/User Data/Default/Service Worker",
             "\(home)/Library/Application Support/Arc/User Data/Default/GPUCache",
             "\(home)/Library/Application Support/Arc/User Data/Default/Code Cache"]
        },

        ScanDefinition(name: "Edge Cache", icon: "globe.americas", color: .cyan,
            description: "Microsoft Edge cache",
            group: .browsers, safetyLevel: .safe) {
            ["\(home)/Library/Caches/com.microsoft.edgemac",
             "\(home)/Library/Application Support/Microsoft Edge/Default/Service Worker",
             "\(home)/Library/Application Support/Microsoft Edge/Default/Code Cache",
             "\(home)/Library/Application Support/Microsoft Edge/Default/GPUCache"]
        },

        ScanDefinition(name: "Brave Cache", icon: "shield", color: .orange,
            description: "Brave browser cache",
            group: .browsers, safetyLevel: .safe) {
            ["\(home)/Library/Caches/BraveSoftware/Brave-Browser",
             "\(home)/Library/Application Support/BraveSoftware/Brave-Browser/Default/Service Worker",
             "\(home)/Library/Application Support/BraveSoftware/Brave-Browser/Default/Code Cache"]
        },

        // ═══════════ PRIVACY (review/caution — user data) ═══════════

        ScanDefinition(name: "Recent Items", icon: "clock.arrow.circlepath", color: .indigo,
            description: "Finder recent items, recent documents, and recent servers lists",
            group: .privacy, safetyLevel: .review, defaultSelected: false) {
            ["\(home)/Library/Application Support/com.apple.sharedfilelist"]
        },

        ScanDefinition(name: "Spotlight History", icon: "magnifyingglass", color: .indigo,
            description: "Spotlight search history and shortcuts — reveals what you've searched for",
            group: .privacy, safetyLevel: .review, defaultSelected: false) {
            ["\(home)/Library/Application Support/com.apple.spotlight.Shortcuts",
             "\(home)/Library/Caches/com.apple.Spotlight"]
        },

        ScanDefinition(name: "Shell History", icon: "terminal", color: .indigo,
            description: "Terminal command history — zsh, bash, Python, Node.js, Ruby REPL",
            group: .privacy, safetyLevel: .review, defaultSelected: false) {
            ["\(home)/.zsh_history",
             "\(home)/.bash_history",
             "\(home)/.python_history",
             "\(home)/.node_repl_history",
             "\(home)/.irb_history",
             "\(home)/.lesshst",
             "\(home)/.wget-hsts"]
        },

        ScanDefinition(name: "Safari History", icon: "safari", color: .indigo,
            description: "Safari browsing history and recent tabs — close Safari first, cannot be undone",
            group: .privacy, safetyLevel: .caution, defaultSelected: false) {
            ["\(home)/Library/Safari/History.db",
             "\(home)/Library/Safari/History.db-wal",
             "\(home)/Library/Safari/History.db-shm",
             "\(home)/Library/Safari/RecentlyClosedTabs.plist",
             "\(home)/Library/Safari/LastSession.plist",
             "\(home)/Library/Safari/Downloads.plist",
             "\(home)/Library/Safari/TopSites.plist"]
        },

        ScanDefinition(name: "Chrome History", icon: "globe", color: .indigo,
            description: "Chrome browsing history across all profiles — close Chrome first, cannot be undone",
            group: .privacy, safetyLevel: .caution, defaultSelected: false) {
            var paths = [
                "\(home)/Library/Application Support/Google/Chrome/Default/History",
                "\(home)/Library/Application Support/Google/Chrome/Default/History-journal",
                "\(home)/Library/Application Support/Google/Chrome/Default/Visited Links",
                "\(home)/Library/Application Support/Google/Chrome/Default/Top Sites",
                "\(home)/Library/Application Support/Google/Chrome/Default/Top Sites-journal",
            ]
            let chromeAppSupport = "\(home)/Library/Application Support/Google/Chrome"
            if let entries = try? FileManager.default.contentsOfDirectory(atPath: chromeAppSupport) {
                for entry in entries where entry.hasPrefix("Profile ") {
                    paths.append("\(chromeAppSupport)/\(entry)/History")
                    paths.append("\(chromeAppSupport)/\(entry)/History-journal")
                    paths.append("\(chromeAppSupport)/\(entry)/Visited Links")
                    paths.append("\(chromeAppSupport)/\(entry)/Top Sites")
                    paths.append("\(chromeAppSupport)/\(entry)/Top Sites-journal")
                }
            }
            return paths
        },

        ScanDefinition(name: "Firefox Form History", icon: "flame", color: .indigo,
            description: "Firefox form autofill data — close Firefox first, cannot be undone",
            group: .privacy, safetyLevel: .caution, defaultSelected: false) {
            var paths: [String] = []
            let profilesDir = "\(home)/Library/Application Support/Firefox/Profiles"
            if let profiles = try? FileManager.default.contentsOfDirectory(atPath: profilesDir) {
                for profile in profiles {
                    paths.append("\(profilesDir)/\(profile)/formhistory.sqlite")
                    paths.append("\(profilesDir)/\(profile)/formhistory.sqlite-wal")
                    paths.append("\(profilesDir)/\(profile)/formhistory.sqlite-shm")
                }
            }
            return paths
        },

        ScanDefinition(name: "Browser Cookies", icon: "birthday.cake", color: .indigo,
            description: "Safari and Chrome cookies — will log you out of all websites, cannot be undone",
            group: .privacy, safetyLevel: .caution, defaultSelected: false) {
            var paths = [
                "\(home)/Library/Cookies/Cookies.binarycookies",
                "\(home)/Library/Cookies/com.apple.Safari.cookies",
                "\(home)/Library/Application Support/Google/Chrome/Default/Cookies",
                "\(home)/Library/Application Support/Google/Chrome/Default/Cookies-journal",
            ]
            let chromeAppSupport = "\(home)/Library/Application Support/Google/Chrome"
            if let entries = try? FileManager.default.contentsOfDirectory(atPath: chromeAppSupport) {
                for entry in entries where entry.hasPrefix("Profile ") {
                    paths.append("\(chromeAppSupport)/\(entry)/Cookies")
                    paths.append("\(chromeAppSupport)/\(entry)/Cookies-journal")
                }
            }
            return paths
        },

        // ═══════════ DEVELOPER (safe — build artifacts rebuild) ═══════════

        ScanDefinition(name: "Xcode Derived Data", icon: "hammer", color: .pink,
            description: "Xcode build artifacts — rebuilt on next build",
            group: .developer, safetyLevel: .safe) {
            ["\(home)/Library/Developer/Xcode/DerivedData"]
        },

        ScanDefinition(name: "Xcode Caches & Device Support", icon: "xmark.bin", color: .indigo,
            description: "Xcode caches, old device support — re-downloaded as needed",
            group: .developer, safetyLevel: .safe) {
            ["\(home)/Library/Caches/com.apple.dt.Xcode",
             "\(home)/Library/Developer/Xcode/iOS DeviceSupport",
             "\(home)/Library/Developer/Xcode/watchOS DeviceSupport",
             "\(home)/Library/Developer/Xcode/tvOS DeviceSupport",
             "\(home)/Library/Developer/Xcode/macOS DeviceSupport",
             "\(home)/Library/Developer/CoreSimulator/Caches",
             "\(home)/Library/Developer/Xcode/Products"]
        },

        ScanDefinition(name: "Xcode Previews", icon: "rectangle.on.rectangle", color: .pink,
            description: "SwiftUI preview build data — rebuilt automatically",
            group: .developer, safetyLevel: .safe) {
            ["\(home)/Library/Developer/Xcode/UserData/Previews"]
        },

        ScanDefinition(name: "Xcode Archives", icon: "archivebox", color: .purple,
            description: "Old build archives — may contain release builds you need",
            group: .developer, safetyLevel: .review, defaultSelected: false) {
            ["\(home)/Library/Developer/Xcode/Archives"]
        },

        ScanDefinition(name: "iOS Simulators", icon: "iphone.gen3", color: .indigo,
            description: "Simulator devices & runtimes — re-downloaded from Xcode",
            group: .developer, safetyLevel: .review, defaultSelected: false) {
            ["\(home)/Library/Developer/CoreSimulator/Devices",
             "/Library/Developer/CoreSimulator/Volumes",
             "/Library/Developer/CoreSimulator/Images"]
        },

        ScanDefinition(name: "Android / Gradle", icon: "cpu", color: .green,
            description: "Android build caches and Gradle — rebuilt on next build",
            group: .developer, safetyLevel: .safe) {
            ["\(home)/.gradle/caches", "\(home)/.gradle/wrapper/dists",
             "\(home)/.gradle/daemon", "\(home)/.android/cache"]
        },

        // ═══════════ PACKAGE MANAGERS (safe — caches re-download) ═══════════

        ScanDefinition(name: "Homebrew Cache", icon: "mug", color: .brown,
            description: "Downloaded packages — re-downloaded on next install",
            group: .packageManagers, safetyLevel: .safe) {
            ["\(home)/Library/Caches/Homebrew", "/opt/homebrew/Caches",
             "\(home)/Library/Logs/Homebrew"]
        },

        ScanDefinition(name: "CocoaPods Cache", icon: "shippingbox", color: .brown,
            description: "Pod cache — re-downloaded on pod install",
            group: .packageManagers, safetyLevel: .safe) {
            ["\(home)/Library/Caches/CocoaPods"]
        },

        ScanDefinition(name: "SPM Cache", icon: "swift", color: .orange,
            description: "Swift Package Manager cache — re-downloaded as needed",
            group: .packageManagers, safetyLevel: .safe) {
            ["\(home)/Library/Caches/org.swift.swiftpm", "\(home)/Library/org.swift.swiftpm"]
        },

        ScanDefinition(name: "npm / Yarn / pnpm / Bun", icon: "shippingbox", color: .red,
            description: "JS package caches — re-downloaded on install",
            group: .packageManagers, safetyLevel: .safe) {
            ["\(home)/.npm", "\(home)/Library/Caches/Yarn", "\(home)/.yarn/cache",
             "\(home)/Library/pnpm/store", "\(home)/.pnpm-store",
             "\(home)/.bun/install/cache"]
        },

        ScanDefinition(name: "pip / Conda", icon: "puzzlepiece", color: .green,
            description: "Python package caches — re-downloaded on install",
            group: .packageManagers, safetyLevel: .safe) {
            ["\(home)/Library/Caches/pip", "\(home)/.cache/pip",
             "\(home)/.conda/pkgs", "\(home)/anaconda3/pkgs", "\(home)/miniconda3/pkgs"]
        },

        ScanDefinition(name: "Ruby Gems", icon: "diamond", color: .red,
            description: "Gem cache — re-downloaded on install",
            group: .packageManagers, safetyLevel: .safe) {
            ["\(home)/.gem", "\(home)/.bundle/cache"]
        },

        ScanDefinition(name: "Go Cache", icon: "server.rack", color: .cyan,
            description: "Go build and module caches",
            group: .packageManagers, safetyLevel: .safe) {
            ["\(home)/Library/Caches/go-build", "\(home)/go/pkg/mod/cache"]
        },

        ScanDefinition(name: "Cargo / Rust", icon: "gearshape.2", color: .orange,
            description: "Cargo registry and build cache",
            group: .packageManagers, safetyLevel: .safe) {
            ["\(home)/.cargo/registry", "\(home)/.cargo/git"]
        },

        ScanDefinition(name: "Maven", icon: "building.columns", color: .indigo,
            description: "Maven local repository cache",
            group: .packageManagers, safetyLevel: .safe) {
            ["\(home)/.m2/repository"]
        },

        ScanDefinition(name: "Composer / NuGet / Dart", icon: "cube", color: .purple,
            description: "PHP, .NET, Dart package caches",
            group: .packageManagers, safetyLevel: .safe) {
            ["\(home)/.composer/cache", "\(home)/.nuget/packages", "\(home)/.pub-cache"]
        },

        // ═══════════ DOCKER ═══════════
        // NOTE: Docker Desktop Data scan definition REMOVED to prevent double-counting.
        // The Docker.raw VM disk inside ~/Library/Containers/com.docker.docker/Data
        // contains ALL images, containers, volumes, and build cache. Showing its
        // filesystem size PLUS the Docker CLI-reported sizes was double-counting.
        // Docker cleanup is now handled exclusively via the CLI-based scans below
        // (Docker Images, Docker Containers, Docker Build Cache) which give accurate
        // per-resource sizes. Users who want to fully remove Docker can use the Uninstaller.

        ScanDefinition(name: "Docker Logs & Config", icon: "cube.box", color: .blue,
            description: "Docker Desktop logs and config files — safe to clean",
            group: .docker, safetyLevel: .safe) {
            ["\(home)/Library/Caches/com.docker.docker",
             "\(home)/Library/Logs/Docker Desktop",
             "\(home)/.docker/buildx",
             "\(home)/.docker/cli-plugins"]
        },

        // ═══════════ APPLICATIONS (safe — app caches rebuild) ═══════════

        ScanDefinition(name: "VS Code / Cursor Cache", icon: "curlybraces", color: .blue,
            description: "IDE caches and logs — rebuilt automatically",
            group: .applications, safetyLevel: .safe) {
            ["\(home)/Library/Caches/com.microsoft.VSCode",
             "\(home)/Library/Application Support/Code/Cache",
             "\(home)/Library/Application Support/Code/CachedData",
             "\(home)/Library/Application Support/Code/CachedExtensionVSIXs",
             "\(home)/Library/Application Support/Code/logs",
             "\(home)/Library/Application Support/Code/Service Worker",
             "\(home)/Library/Application Support/Code/Code Cache",
             "\(home)/Library/Application Support/Cursor/Cache",
             "\(home)/Library/Application Support/Cursor/CachedData",
             "\(home)/Library/Application Support/Cursor/Code Cache",
             "\(home)/Library/Application Support/Cursor/logs",
             "\(home)/Library/Caches/com.todesktop.runtime.Cursor"]
        },

        ScanDefinition(name: "JetBrains IDEs Cache", icon: "chevron.left.forwardslash.chevron.right", color: .orange,
            description: "IntelliJ, WebStorm, PyCharm caches/logs — rebuilt on launch",
            group: .applications, safetyLevel: .safe) {
            ["\(home)/Library/Caches/JetBrains", "\(home)/Library/Logs/JetBrains"]
        },

        ScanDefinition(name: "Adobe Cache", icon: "paintbrush", color: .red,
            description: "Adobe media cache — rebuilt when editing",
            group: .applications, safetyLevel: .safe) {
            ["\(home)/Library/Caches/Adobe",
             "\(home)/Library/Application Support/Adobe/Common/Media Cache Files",
             "\(home)/Library/Application Support/Adobe/Common/Media Cache"]
        },

        ScanDefinition(name: "Spotify Cache", icon: "music.note", color: .green,
            description: "Spotify offline cache — music re-streams on demand",
            group: .applications, safetyLevel: .safe) {
            ["\(home)/Library/Caches/com.spotify.client",
             "\(home)/Library/Application Support/Spotify/PersistentCache"]
        },

        ScanDefinition(name: "Slack Cache", icon: "number", color: .purple,
            description: "Slack cache — rebuilt when you open channels",
            group: .applications, safetyLevel: .safe) {
            ["\(home)/Library/Caches/com.tinyspeck.slackmacgap",
             "\(home)/Library/Application Support/Slack/Cache",
             "\(home)/Library/Application Support/Slack/Service Worker",
             "\(home)/Library/Application Support/Slack/Code Cache"]
        },

        ScanDefinition(name: "Discord Cache", icon: "bubble.left.and.bubble.right", color: .indigo,
            description: "Discord cache — rebuilt automatically",
            group: .applications, safetyLevel: .safe) {
            ["\(home)/Library/Caches/com.hnc.Discord",
             "\(home)/Library/Application Support/discord/Cache",
             "\(home)/Library/Application Support/discord/Code Cache",
             "\(home)/Library/Application Support/discord/GPUCache"]
        },

        ScanDefinition(name: "Teams Cache", icon: "person.3", color: .blue,
            description: "Microsoft Teams cache",
            group: .applications, safetyLevel: .safe) {
            ["\(home)/Library/Caches/com.microsoft.teams2",
             "\(home)/Library/Application Support/Microsoft/Teams/Cache",
             "\(home)/Library/Application Support/Microsoft Teams/Cache"]
        },

        ScanDefinition(name: "Zoom Cache", icon: "video", color: .blue,
            description: "Zoom cache — rebuilt on meetings",
            group: .applications, safetyLevel: .safe) {
            ["\(home)/Library/Caches/us.zoom.xos"]
        },

        ScanDefinition(name: "Telegram Cache", icon: "paperplane", color: .blue,
            description: "Telegram media cache — re-downloaded from cloud",
            group: .applications, safetyLevel: .safe) {
            ["\(home)/Library/Caches/ru.keepcoder.Telegram"]
        },

        ScanDefinition(name: "Microsoft Office Cache", icon: "doc.richtext", color: .blue,
            description: "Office app caches — rebuilt on use",
            group: .applications, safetyLevel: .safe) {
            ["\(home)/Library/Caches/com.microsoft.Word",
             "\(home)/Library/Caches/com.microsoft.Excel",
             "\(home)/Library/Caches/com.microsoft.PowerPoint",
             "\(home)/Library/Caches/com.microsoft.Outlook"]
        },

        ScanDefinition(
            name: "Quick Look Cache", icon: "eye.square", color: .gray,
            description: "Thumbnail previews — rebuilds automatically",
            group: .system, safetyLevel: .safe
        ) {
            ["\(home)/Library/Caches/com.apple.QuickLook.thumbnailcache",
             "\(home)/Library/Caches/com.apple.QuickLookThumbnailing"]
        },

        // ═══════════ AI / ML TOOLS (high impact — models can be huge) ═══════════

        ScanDefinition(name: "HuggingFace Models Cache", icon: "brain", color: .purple,
            description: "Downloaded ML models — re-downloaded on demand",
            group: .developer, safetyLevel: .review, defaultSelected: false) {
            ["\(home)/.cache/huggingface"]
        },

        ScanDefinition(name: "Ollama Model Cache", icon: "brain.head.profile", color: .green,
            description: "Ollama model blobs — re-pulled with ollama pull",
            group: .developer, safetyLevel: .review, defaultSelected: false) {
            ["\(home)/.ollama/models"]
        },

        ScanDefinition(name: "LM Studio Models", icon: "cpu.fill", color: .indigo,
            description: "LM Studio model files — re-downloaded from hub",
            group: .developer, safetyLevel: .review, defaultSelected: false) {
            ["\(home)/.cache/lm-studio"]
        },

        // ═══════════ ADDITIONAL DEVELOPER CACHES ═══════════

        ScanDefinition(name: "Bazel Cache", icon: "hammer.fill", color: .gray,
            description: "Bazel build system cache — rebuilt on next build",
            group: .developer, safetyLevel: .safe) {
            ["\(home)/.cache/bazel", "\(home)/.cache/bazelisk"]
        },

        ScanDefinition(name: "Deno Cache", icon: "d.circle", color: .teal,
            description: "Deno module cache — re-downloaded on run",
            group: .packageManagers, safetyLevel: .safe) {
            ["\(home)/Library/Caches/deno", "\(home)/.deno"]
        },

        ScanDefinition(name: "Poetry Cache", icon: "text.book.closed", color: .purple,
            description: "Poetry Python package cache — re-downloaded on install",
            group: .packageManagers, safetyLevel: .safe) {
            ["\(home)/Library/Caches/pypoetry", "\(home)/.cache/pypoetry"]
        },

        // ═══════════ ADDITIONAL SYSTEM CLEANUP ═══════════

        ScanDefinition(name: "Font Caches", icon: "textformat", color: .gray,
            description: "Font rendering caches — rebuilt automatically on login",
            group: .system, safetyLevel: .safe) {
            ["\(home)/Library/Caches/com.apple.FontRegistry",
             "/Library/Caches/com.apple.ATS"]
        },

        ScanDefinition(name: "Speech Data Cache", icon: "waveform", color: .blue,
            description: "Speech recognition cache — rebuilt when needed",
            group: .system, safetyLevel: .safe) {
            ["\(home)/Library/Caches/com.apple.SpeechRecognitionCore"]
        },

        ScanDefinition(name: "Xcode Playground Cache", icon: "play.rectangle", color: .pink,
            description: "Swift Playground execution data — rebuilt on run",
            group: .developer, safetyLevel: .safe) {
            ["\(home)/Library/Developer/Xcode/UserData/Playgrounds",
             "\(home)/Library/Developer/XCPGDevices"]
        },

        ScanDefinition(name: "Provisioning Profiles", icon: "shield.checkered", color: .indigo,
            description: "iOS/macOS provisioning profiles — re-downloaded from developer portal",
            group: .developer, safetyLevel: .review, defaultSelected: false) {
            ["\(home)/Library/MobileDevice/Provisioning Profiles"]
        },
    ]

    // MARK: - Disk Usage

    func fetchDiskUsage() {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfFileSystem(forPath: NSHomeDirectory()) else { return }
        let total = (attrs[.systemSize] as? Int64) ?? 0
        let free = (attrs[.systemFreeSize] as? Int64) ?? 0
        let used = total - free
        let url = URL(fileURLWithPath: "/")
        let purgeableBytes: Int64
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let available = values.volumeAvailableCapacityForImportantUsage {
            purgeableBytes = available - free
        } else {
            purgeableBytes = 0
        }
        diskUsage = DiskUsageInfo(totalSpace: total, usedSpace: used, freeSpace: free, purgeableSpace: max(0, purgeableBytes))
    }

    // MARK: - Main Scan

    func scan() async {
        await MainActor.run {
            isScanning = true
            scanComplete = false
            cleanComplete = false
            categories = []
            currentScanItem = ""
            scanProgress = 0
            scanErrors = []
            scanStartTime = Date()
        }
        cancelLock.withLock { $0 = false }
        resetScannedPaths()
        startMemoryMonitoring()

        fetchDiskUsage()
        checkFullDiskAccess()

        let scanDocker = settingScanDocker
        let scanNodeModules = settingScanNodeModules
        let scanUnusedApps = settingScanUnusedApps
        let scanIOSBackups = settingScanIOSBackups
        let scanIMessage = settingScanIMessageAttachments
        let scanBrokenSymlinks = settingScanBrokenSymlinks
        let scanScreenRecordings = settingScanScreenRecordings
        let scanVenvs = settingScanVirtualEnvironments
        let scanLargeFiles = settingScanLargeFiles
        let estimatedSmartScans = 6 + (scanDocker ? 3 : 0) + (scanUnusedApps ? 1 : 0) + (scanNodeModules ? 1 : 0) + 2 + 1 + (scanIOSBackups ? 1 : 0) + (scanIMessage ? 1 : 0) + (scanBrokenSymlinks ? 1 : 0) + (scanScreenRecordings ? 1 : 0) + (scanVenvs ? 1 : 0) + (scanLargeFiles ? 1 : 0)

        // Phase 1: Specific known-safe targets
        // First pass: collect all paths so we can detect parent-child overlaps
        let totalDefs = scanDefinitions.count
        var allResolvedPaths: [[String]] = []
        for definition in scanDefinitions {
            let resolved = definition.pathResolver().map { ($0 as NSString).resolvingSymlinksInPath }
            allResolvedPaths.append(resolved)
        }

        for (index, definition) in scanDefinitions.enumerated() {
            if cancelRequested { break }

            await MainActor.run { currentScanItem = definition.name }

            let resolvedPaths = allResolvedPaths[index]
            let fm = FileManager.default
            let existingPaths = resolvedPaths.filter { fm.fileExists(atPath: $0) }

            if !existingPaths.isEmpty {
                var breakdown: [PathStat] = []
                var combinedSize: Int64 = 0
                var combinedCount: Int = 0

                for path in existingPaths {
                    if cancelRequested { break }
                    // Check if this path is a parent of another scan's path — if so,
                    // exclude the child from this scan's size calculation
                    var childPaths: [String] = []
                    for (otherIdx, otherPaths) in allResolvedPaths.enumerated() where otherIdx != index {
                        for otherPath in otherPaths where otherPath.hasPrefix(path + "/") {
                            childPaths.append(otherPath)
                        }
                    }

                    let (size, count): (Int64, Int)
                    if childPaths.isEmpty {
                        (size, count) = await directorySize(path)
                    } else {
                        (size, count) = await directorySizeExcluding(path, excludedPaths: childPaths)
                    }

                    if size > 0 {
                        breakdown.append(PathStat(path: path, size: size, fileCount: count))
                        combinedSize += size
                        combinedCount += count
                        insertScannedPath(path)
                    }
                }

                if combinedSize > 0 {
                    let category = CleanupCategory(
                        name: definition.name, icon: definition.icon,
                        color: definition.color, description: definition.description,
                        group: definition.group, safetyLevel: definition.safetyLevel,
                        paths: existingPaths, breakdown: breakdown,
                        deleteChildrenOnly: true,
                        size: combinedSize, fileCount: combinedCount,
                        isSelected: definition.defaultSelected
                    )
                    await MainActor.run { categories.append(category) }
                }
            }

            await MainActor.run {
                scanProgress = Double(index + 1) / Double(totalDefs + estimatedSmartScans)
            }
        }

        // Phase 2: Comprehensive walkers + smart scans
        var smartScans: [(String, () async -> CleanupCategory?)] = [
            // SAFE: Cache directory walkers (caches always rebuild)
            ("Scanning all app caches...",       { await self.scanAllCaches() }),
            ("Scanning system caches...",        { await self.scanSystemCaches() }),
            // REVIEW: User file scanners (need user decision)
            ("Scanning old screenshots...",      { await self.scanOldScreenshots() }),
            ("Scanning installer files...",      { await self.scanInstallerFiles() }),
            ("Scanning old downloads...",        { await self.scanOldDownloads() }),
        ]

        if scanDocker {
            smartScans.append(("Scanning Docker images...",      { await self.scanDockerImages() }))
            smartScans.append(("Scanning Docker containers...",  { await self.scanDockerStoppedContainers() }))
            smartScans.append(("Scanning Docker build cache...", { await self.scanDockerBuildCache() }))
        }
        // Ollama models (always scan if installed — fast CLI call)
        smartScans.append(("Scanning Ollama models...",     { await self.scanOllamaModels() }))

        if scanUnusedApps {
            smartScans.append(("Scanning unused apps...",        { await self.scanUnusedApplications() }))
        }
        if scanNodeModules {
            smartScans.append(("Scanning node_modules...",       { await self.scanNodeModules() }))
        }

        // Always scan these
        smartScans.append(("Scanning mail attachments...",   { await self.scanMailAttachments() }))
        smartScans.append(("Scanning app leftovers...",      { await self.scanOrphanedAppData() }))

        // Conditionally enabled scans
        smartScans.append(("Scanning iOS software updates...", { await self.scanIPSWFiles() }))  // Always scan (small/fast)
        if scanIOSBackups {
            smartScans.append(("Scanning iOS backups...",        { await self.scanIOSBackups() }))
        }
        if scanIMessage {
            smartScans.append(("Scanning iMessage attachments...", { await self.scanIMessageAttachments() }))
        }
        if scanBrokenSymlinks {
            smartScans.append(("Scanning broken symlinks...",     { await self.scanBrokenSymlinks() }))
        }
        if scanScreenRecordings {
            smartScans.append(("Scanning screen recordings...",   { await self.scanScreenRecordings() }))
        }

        // iCloud and duplicate scanning removed — handled by standalone tools

        if scanVenvs {
            smartScans.append(("Scanning virtual environments...", { await self.scanVirtualEnvironments() }))
        }
        if scanLargeFiles {
            smartScans.append(("Scanning large files...",     { await self.scanLargeFiles() }))
        }
        // Duplicate scanning moved to standalone Duplicate Finder tool

        let totalSmartScans = smartScans.count
        for (index, (name, scanner)) in smartScans.enumerated() {
            if cancelRequested { break }
            await MainActor.run { currentScanItem = name }

            if let category = await scanner() {
                await MainActor.run { categories.append(category) }
            }

            await MainActor.run {
                scanProgress = Double(totalDefs + index + 1) / Double(totalDefs + totalSmartScans)
            }
        }

        if cancelRequested {
            // Keep partial results instead of discarding everything
            let scanDuration = Date().timeIntervalSince(scanStartTime ?? Date())
            await MainActor.run {
                isScanning = false
                scanComplete = !categories.isEmpty
                currentScanItem = ""
                scanProgress = 0
                if !categories.isEmpty {
                    categories.sort { $0.size > $1.size }
                    lastScanSummary = ScanSummary(
                        totalCategories: categories.count, totalSize: overallSize,
                        totalFiles: categories.reduce(0) { $0 + $1.fileCount },
                        scanDuration: scanDuration, timestamp: Date(),
                        wasPartial: true
                    )
                }
            }
            // Release scan-only data
            resetScannedPaths()
            stopMemoryMonitoring()
            return
        }

        let scanDuration = Date().timeIntervalSince(scanStartTime ?? Date())
        await MainActor.run {
            categories.sort { $0.size > $1.size }
            isScanning = false; scanComplete = true
            currentScanItem = ""; scanProgress = 1.0
            lastScanSummary = ScanSummary(
                totalCategories: categories.count, totalSize: overallSize,
                totalFiles: categories.reduce(0) { $0 + $1.fileCount },
                scanDuration: scanDuration, timestamp: Date(),
                wasPartial: false
            )
        }
        // Release scan-only data
        resetScannedPaths()
        stopMemoryMonitoring()
    }

    func cancelScan() { cancelLock.withLock { $0 = true } }

    private var cancelRequested: Bool {
        cancelLock.withLock { $0 }
    }

    private func insertScannedPath(_ path: String) {
        scannedPathsLock.withLock { $0.insert(path) }
    }

    private func isPathScanned(_ path: String) -> Bool {
        scannedPathsLock.withLock { $0.contains(path) }
    }

    private func scannedPathsSnapshot() -> Set<String> {
        scannedPathsLock.withLock { $0 }
    }

    private func resetScannedPaths() {
        scannedPathsLock.withLock { $0.removeAll() }
    }

    private func checkFullDiskAccess() {
        let testPath = "\(Self.home)/Library/Mail"
        let fm = FileManager.default
        hasFullDiskAccess = fm.isReadableFile(atPath: testPath)
    }

    // MARK: - Clean

    func clean() async {
        let cleanedSize = categories.filter(\.isSelected).reduce(0) { $0 + $1.selectedSize }
        let cleanedCount = selectedCategoryCount
        await MainActor.run {
            isCleaning = true
            cleanProgress = 0
            cleanErrors = []
            cleanSuccessCount = 0
            cleanFailCount = 0
        }

        let selectedCategories = categories.filter(\.isSelected)
        let useTrash = settingPreferTrash
        let totalCategories = selectedCategories.count

        for (catIndex, category) in selectedCategories.enumerated() {
            if category.isDockerResource, let command = category.dockerCleanCommand {
                let success = await runDockerClean(command: command)
                await MainActor.run {
                    if success {
                        cleanSuccessCount += 1
                    } else {
                        cleanFailCount += 1
                        cleanErrors.append("Failed to clean Docker resource: \(category.name)")
                    }
                    cleanProgress = Double(catIndex + 1) / Double(totalCategories)
                }
                continue
            }

            if category.isOllamaResource {
                let success = await runOllamaClean(category: category)
                await MainActor.run {
                    if success {
                        cleanSuccessCount += 1
                    } else {
                        cleanFailCount += 1
                        cleanErrors.append("Failed to clean Ollama resource: \(category.name)")
                    }
                    cleanProgress = Double(catIndex + 1) / Double(totalCategories)
                }
                continue
            }

            let paths = category.paths
            let deleteChildrenOnly = category.deleteChildrenOnly
            let categoryName = category.name
            let usePerFile = category.hasPerFileSelection
            let effectivePaths: [String]
            if usePerFile {
                effectivePaths = category.selectedPaths
            } else {
                effectivePaths = paths
            }
            let effectiveDeleteChildrenOnly = usePerFile ? false : deleteChildrenOnly

            let errors: [String] = await withCheckedContinuation { (continuation: CheckedContinuation<[String], Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let fm = FileManager.default
                    var localErrors: [String] = []
                    var auditLog: [(path: String, size: Int64, trashedOrDeleted: String)] = []
                    var needsAdminPaths: [String] = []
                    let uid = getuid()

                    func isOwnedByUser(_ path: String) -> Bool {
                        guard let attrs = try? fm.attributesOfItem(atPath: path),
                              let ownerID = attrs[.ownerAccountID] as? UInt32 else { return false }
                        return ownerID == uid
                    }

                    func deleteItem(at url: URL) {
                        let path = url.path
                        // Safety: reject protected paths
                        if !Self.isSafePath(path) {
                            localErrors.append("\(categoryName): Blocked deletion of protected path — \(url.lastPathComponent)")
                            return
                        }

                        // Get size for audit log
                        let fileSize: Int64 = (try? fm.attributesOfItem(atPath: path))?[.size] as? Int64 ?? 0

                        if useTrash {
                            if (try? fm.trashItem(at: url, resultingItemURL: nil)) != nil {
                                auditLog.append((path: path, size: fileSize, trashedOrDeleted: "TRASH"))
                            } else {
                                // Trash failed — collect for admin escalation
                                needsAdminPaths.append(path)
                            }
                        } else {
                            do {
                                try fm.removeItem(at: url)
                                auditLog.append((path: path, size: fileSize, trashedOrDeleted: "DELETE"))
                            } catch {
                                localErrors.append("\(categoryName): Failed to remove \(url.lastPathComponent) — \(error.localizedDescription)")
                            }
                        }
                    }

                    if effectiveDeleteChildrenOnly {
                        for path in effectivePaths {
                            let contents: [String]
                            do {
                                contents = try fm.contentsOfDirectory(atPath: path)
                            } catch {
                                continue
                            }
                            for item in contents {
                                autoreleasepool {
                                    let fullPath = (path as NSString).appendingPathComponent(item)
                                    deleteItem(at: URL(fileURLWithPath: fullPath))
                                }
                            }
                        }
                    } else {
                        for path in effectivePaths {
                            deleteItem(at: URL(fileURLWithPath: path))
                        }
                    }

                    // Escalate failed paths via admin privileges
                    if !needsAdminPaths.isEmpty {
                        let trashDir = NSHomeDirectory() + "/.Trash"
                        let tempScript = NSTemporaryDirectory() + "sparkclean_clean_\(ProcessInfo.processInfo.processIdentifier).sh"
                        var script = "#!/bin/bash\nset -e\n"
                        for path in needsAdminPaths {
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

                        DispatchQueue.main.sync {
                            var error: NSDictionary?
                            let appleScript = NSAppleScript(source: appleScriptSource)
                            appleScript?.executeAndReturnError(&error)
                            if error != nil {
                                for p in needsAdminPaths {
                                    localErrors.append("\(categoryName): Admin required — \((p as NSString).lastPathComponent)")
                                }
                            } else {
                                for p in needsAdminPaths {
                                    auditLog.append((path: p, size: 0, trashedOrDeleted: "TRASH(admin)"))
                                }
                            }
                        }
                        try? fm.removeItem(atPath: tempScript)
                    }

                    // Write deletion audit log
                    Self.writeDeletionLog(entries: auditLog)

                    continuation.resume(returning: localErrors)
                }
            }

            await MainActor.run {
                if errors.isEmpty {
                    cleanSuccessCount += 1
                } else {
                    cleanFailCount += 1
                    cleanErrors.append(contentsOf: errors)
                }
                cleanProgress = Double(catIndex + 1) / Double(totalCategories)
            }
        }

        await MainActor.run {
            isCleaning = false
            cleanComplete = true
            lastCleanedSize = cleanedSize
            lastCleanedCount = cleanedCount

            // Update categories in-place instead of rescanning
            for i in categories.indices {
                if categories[i].isSelected {
                    if categories[i].hasPerFileSelection {
                        // Remove only selected breakdown items
                        let remainingBreakdown = categories[i].breakdown.filter { !$0.isSelected }
                        categories[i].breakdown = remainingBreakdown
                        categories[i].size = remainingBreakdown.reduce(0) { $0 + $1.size }
                        categories[i].fileCount = remainingBreakdown.reduce(0) { $0 + $1.fileCount }
                    } else {
                        // Entire category was cleaned
                        categories[i].size = 0
                        categories[i].fileCount = 0
                        categories[i].breakdown = []
                    }
                }
            }
            // Remove empty categories
            categories.removeAll(where: { $0.size == 0 && $0.fileCount == 0 })
        }
    }

    // MARK: - Size Calculation

    private func directorySize(_ path: String) async -> (Int64, Int) {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.directorySizeSync(path))
            }
        }
    }

    private func directorySizeExcluding(_ path: String, excludedPaths: [String]) async -> (Int64, Int) {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.directorySizeSyncExcluding(path, excludedPaths: excludedPaths))
            }
        }
    }

    private static func directorySizeSync(_ path: String) -> (Int64, Int) {
        let fm = FileManager.default
        var totalSize: Int64 = 0
        var count = 0

        // Handle individual files (not directories)
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue {
            let url = URL(fileURLWithPath: path)
            if let rv = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]) {
                return (Int64(rv.totalFileAllocatedSize ?? rv.fileSize ?? 0), 1)
            }
            return (0, 0)
        }

        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey],
            options: [],
            errorHandler: nil
        ) else {
            return (0, 0)
        }

        while let obj = enumerator.nextObject() {
            guard let fileURL = obj as? URL else { continue }
            autoreleasepool {
                guard let rv = try? fileURL.resourceValues(
                    forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey]
                ) else { return }
                if rv.isRegularFile == true {
                    totalSize += Int64(rv.totalFileAllocatedSize ?? rv.fileSize ?? 0)
                    count += 1
                }
            }
        }

        return (totalSize, count)
    }

    private static func directorySizeSyncExcluding(_ path: String, excludedPaths: [String]) -> (Int64, Int) {
        let fm = FileManager.default
        var totalSize: Int64 = 0
        var count = 0

        // Handle individual files (not directories)
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue {
            let url = URL(fileURLWithPath: path)
            if let rv = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]) {
                return (Int64(rv.totalFileAllocatedSize ?? rv.fileSize ?? 0), 1)
            }
            return (0, 0)
        }

        let excludedWithSlash = excludedPaths.map { $0 + "/" }

        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey],
            options: [],
            errorHandler: nil
        ) else {
            return (0, 0)
        }

        let excludedSet = Set(excludedPaths)
        while let obj = enumerator.nextObject() {
            guard let fileURL = obj as? URL else { continue }
            let filePath = fileURL.path
            // Skip excluded subtrees entirely — skip descendants for performance
            if excludedSet.contains(filePath) || excludedWithSlash.contains(where: { filePath.hasPrefix($0) }) {
                enumerator.skipDescendants()
                continue
            }
            autoreleasepool {
                guard let rv = try? fileURL.resourceValues(
                    forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey]
                ) else { return }
                if rv.isRegularFile == true {
                    totalSize += Int64(rv.totalFileAllocatedSize ?? rv.fileSize ?? 0)
                    count += 1
                }
            }
        }

        return (totalSize, count)
    }

    // MARK: - Comprehensive Cache Walkers (SAFE — caches always rebuild)

    /// Walks ~/Library/Caches — finds ALL app caches not already covered by specific scans
    private func scanAllCaches() async -> CleanupCategory? {
        let fm = FileManager.default
        let dir = "\(Self.home)/Library/Caches"
        guard fm.fileExists(atPath: dir) else { return nil }

        let scannedSnapshot = scannedPathsSnapshot()
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let entries = try? fm.contentsOfDirectory(atPath: dir) else {
                    continuation.resume(returning: nil)
                    return
                }

                var paths: [String] = []
                var breakdown: [PathStat] = []
                var totalSize: Int64 = 0
                var totalCount: Int = 0

                // Pre-compute sorted scanned paths for efficient overlap detection
                let sortedScanned = scannedSnapshot.sorted()

                for entry in entries {
                    autoreleasepool {
                    let fullPath = (dir as NSString).appendingPathComponent(entry)
                    // Skip entries already covered by specific scans
                    if scannedSnapshot.contains(fullPath) { return }
                    // Efficient overlap check: binary search for child/parent paths
                    let fullPathSlash = fullPath + "/"
                    if sortedScanned.contains(where: { $0.hasPrefix(fullPathSlash) || fullPath.hasPrefix($0 + "/") }) { return }

                    let (sz, ct) = Self.directorySizeSync(fullPath)
                    if sz > ScanConstants.minCacheSizeBytes {
                        paths.append(fullPath)
                        breakdown.append(PathStat(path: fullPath, size: sz, fileCount: ct))
                        totalSize += sz
                        totalCount += ct
                    }
                    } // autoreleasepool
                }

                guard totalSize > ScanConstants.minCacheTotalBytes, !paths.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }

                var sorted = breakdown
                sorted.sort { $0.size > $1.size }

                continuation.resume(returning: CleanupCategory(
                    name: "Other App Caches", icon: "archivebox", color: .blue,
                    description: "\(paths.count) app caches — safe to remove, rebuilt automatically",
                    group: .system, safetyLevel: .safe,
                    paths: paths, breakdown: Array(sorted.prefix(60)),
                    deleteChildrenOnly: true,
                    size: totalSize, fileCount: totalCount,
                    isSelected: true
                ))
            }
        }
    }

    /// Walks /Library/Caches — system-level caches
    private func scanSystemCaches() async -> CleanupCategory? {
        let fm = FileManager.default
        let dir = "/Library/Caches"
        guard fm.fileExists(atPath: dir) else { return nil }

        let scannedSnapshot = scannedPathsSnapshot()
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let entries = try? fm.contentsOfDirectory(atPath: dir) else {
                    continuation.resume(returning: nil)
                    return
                }

                var paths: [String] = []
                var breakdown: [PathStat] = []
                var totalSize: Int64 = 0
                var totalCount: Int = 0

                for entry in entries {
                    autoreleasepool {
                    let fullPath = (dir as NSString).appendingPathComponent(entry)
                    if scannedSnapshot.contains(fullPath) { return }

                    let (sz, ct) = Self.directorySizeSync(fullPath)
                    if sz > ScanConstants.minSystemCacheSizeBytes {
                        paths.append(fullPath)
                        breakdown.append(PathStat(path: fullPath, size: sz, fileCount: ct))
                        totalSize += sz
                        totalCount += ct
                    }
                    } // autoreleasepool
                }

                guard totalSize > ScanConstants.minSystemCacheTotalBytes, !paths.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }

                var sorted = breakdown
                sorted.sort { $0.size > $1.size }

                continuation.resume(returning: CleanupCategory(
                    name: "System Caches", icon: "internaldrive.fill", color: .blue,
                    description: "\(paths.count) system-level caches — safe to remove",
                    group: .system, safetyLevel: .safe,
                    paths: paths, breakdown: Array(sorted.prefix(60)),
                    deleteChildrenOnly: false,
                    size: totalSize, fileCount: totalCount,
                    isSelected: true
                ))
            }
        }
    }

    // MARK: - User File Scanners (REVIEW — user should check before deleting)

    /// Old files in Downloads (>30 days old)
    private func scanOldDownloads() async -> CleanupCategory? {
        let olderThanDays = settingOldFileThresholdDays
        let threshold = Date().addingTimeInterval(-Double(olderThanDays) * 86400)

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let fm = FileManager.default
                let downloads = "\(Self.home)/Downloads"
                guard fm.fileExists(atPath: downloads) else {
                    continuation.resume(returning: nil)
                    return
                }

                var filePaths: [String] = []
                var breakdown: [PathStat] = []
                var totalSize: Int64 = 0

                guard let contents = try? fm.contentsOfDirectory(
                    at: URL(fileURLWithPath: downloads),
                    includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .totalFileAllocatedSizeKey, .fileSizeKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                ) else {
                    continuation.resume(returning: nil)
                    return
                }

                for url in contents {
                    autoreleasepool {
                        guard let rv = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .totalFileAllocatedSizeKey, .fileSizeKey, .contentModificationDateKey]) else { return }

                        if rv.isRegularFile == true {
                            let modDate = rv.contentModificationDate ?? Date.distantPast
                            guard modDate < threshold else { return }
                            let size = Int64(rv.totalFileAllocatedSize ?? rv.fileSize ?? 0)
                            if size > 0 {
                                filePaths.append(url.path)
                                self.insertScannedPath(url.path)
                                breakdown.append(PathStat(path: url.path, size: size, fileCount: 1))
                                totalSize += size
                            }
                        } else if rv.isDirectory == true {
                            // For directories, check the NEWEST file inside — not the dir's own mod date.
                            // A directory mod date only updates when direct children are added/removed,
                            // so it can be stale even when files deep inside are actively used.
                            let newestDate = Self.newestFileDate(in: url.path) ?? Date.distantPast
                            guard newestDate < threshold else { return }
                            let (size, count) = Self.directorySizeSync(url.path)
                            if size > 0 {
                                filePaths.append(url.path)
                                self.insertScannedPath(url.path)
                                breakdown.append(PathStat(path: url.path, size: size, fileCount: count))
                                totalSize += size
                            }
                        }
                    }
                }

                guard !filePaths.isEmpty, totalSize > 0 else {
                    continuation.resume(returning: nil)
                    return
                }

                var sorted = breakdown
                sorted.sort { $0.size > $1.size }
                let totalFileCount = sorted.reduce(0) { $0 + $1.fileCount }

                continuation.resume(returning: CleanupCategory(
                    name: "Old Downloads (>\(olderThanDays)d)", icon: "arrow.down.circle.fill", color: .blue,
                    description: "\(filePaths.count) old items in Downloads — review before deleting",
                    group: .system, safetyLevel: .review,
                    paths: filePaths, breakdown: Array(sorted.prefix(60)),
                    deleteChildrenOnly: false,
                    size: totalSize, fileCount: totalFileCount,
                    isSelected: false
                ))
            }
        }
    }

    /// Old screenshots
    private func scanOldScreenshots() async -> CleanupCategory? {
        let olderThanDays = settingScreenshotThresholdDays
        let threshold = Date().addingTimeInterval(-Double(olderThanDays) * 86400)
        let dirs = ["\(Self.home)/Desktop", "\(Self.home)/Downloads", "\(Self.home)/Documents"]

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let fm = FileManager.default
                var filePaths: [String] = []
                var breakdown: [PathStat] = []
                var totalSize: Int64 = 0

                for dir in dirs where fm.fileExists(atPath: dir) {
                    guard let contents = try? fm.contentsOfDirectory(
                        at: URL(fileURLWithPath: dir),
                        includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .totalFileAllocatedSizeKey],
                        options: [.skipsHiddenFiles]
                    ) else { continue }

                    for url in contents {
                        let name = url.lastPathComponent.lowercased()
                        guard name.hasPrefix("screenshot") || name.hasPrefix("screen shot") ||
                              name.hasPrefix("screen recording") || name.hasPrefix("cleanshot")
                        else { continue }
                        guard let rv = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .totalFileAllocatedSizeKey]),
                              rv.isRegularFile == true,
                              let modDate = rv.contentModificationDate, modDate < threshold else { continue }
                        let size = Int64(rv.totalFileAllocatedSize ?? rv.fileSize ?? 0)
                        guard size > 0 else { continue }

                        filePaths.append(url.path)
                        self.insertScannedPath(url.path)
                        breakdown.append(PathStat(path: url.path, size: size, fileCount: 1))
                        totalSize += size
                    }
                }

                guard !filePaths.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }

                breakdown.sort { $0.size > $1.size }

                continuation.resume(returning: CleanupCategory(
                    name: "Old Screenshots (>\(olderThanDays)d)", icon: "camera.viewfinder", color: .teal,
                    description: "\(filePaths.count) old screenshots — likely safe to delete",
                    group: .system, safetyLevel: .review,
                    paths: filePaths, breakdown: breakdown,
                    deleteChildrenOnly: false,
                    size: totalSize, fileCount: filePaths.count,
                    isSelected: false
                ))
            }
        }
    }

    /// Old installer files in Downloads
    private func scanInstallerFiles() async -> CleanupCategory? {
        let olderThanDays = 14
        let threshold = Date().addingTimeInterval(-Double(olderThanDays) * 86400)
        let extensions: Set<String> = ["dmg", "pkg", "iso"]

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let fm = FileManager.default
                let downloads = "\(Self.home)/Downloads"
                guard fm.fileExists(atPath: downloads) else {
                    continuation.resume(returning: nil)
                    return
                }

                var filePaths: [String] = []
                var breakdown: [PathStat] = []
                var totalSize: Int64 = 0

                guard let enumerator = fm.enumerator(
                    at: URL(fileURLWithPath: downloads),
                    includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .totalFileAllocatedSizeKey],
                    options: [.skipsSubdirectoryDescendants],
                    errorHandler: nil
                ) else {
                    continuation.resume(returning: nil)
                    return
                }

                for case let url as URL in enumerator {
                    guard extensions.contains(url.pathExtension.lowercased()) else { continue }
                    guard let rv = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .totalFileAllocatedSizeKey]),
                          rv.isRegularFile == true else { continue }
                    let size = Int64(rv.totalFileAllocatedSize ?? rv.fileSize ?? 0)
                    let modDate = rv.contentModificationDate ?? Date.distantPast
                    if modDate < threshold && size > 0 {
                        filePaths.append(url.path)
                        self.insertScannedPath(url.path)
                        breakdown.append(PathStat(path: url.path, size: size, fileCount: 1))
                        totalSize += size
                    }
                }

                guard !filePaths.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }

                breakdown.sort { $0.size > $1.size }

                continuation.resume(returning: CleanupCategory(
                    name: "Old Installers (>\(olderThanDays)d)", icon: "doc.zipper", color: .brown,
                    description: "\(filePaths.count) old DMG/PKG files — already installed, safe to remove",
                    group: .system, safetyLevel: .review,
                    paths: filePaths, breakdown: breakdown,
                    deleteChildrenOnly: false,
                    size: totalSize, fileCount: filePaths.count,
                    isSelected: false
                ))
            }
        }
    }

    // MARK: - Unused Applications

    private func scanUnusedApplications() async -> CleanupCategory? {
        let thresholdDays = settingUnusedAppThresholdDays
        let threshold = Date().addingTimeInterval(-Double(thresholdDays) * 86400)

        let candidates: [(path: String, lastUsed: Date, displayName: String)] = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let fm = FileManager.default
                let appDirs = ["/Applications", "\(Self.home)/Applications"]
                var results: [(path: String, lastUsed: Date, displayName: String)] = []

                let systemApps: Set<String> = [
                    "Safari", "Mail", "Messages", "FaceTime", "Maps", "Photos",
                    "Music", "TV", "News", "Stocks", "Podcasts", "Books",
                    "App Store", "System Preferences", "System Settings",
                    "Preview", "TextEdit", "Calculator", "Dictionary",
                    "Font Book", "Keychain Access", "Terminal", "Activity Monitor",
                    "Console", "Disk Utility", "Migration Assistant", "Automator",
                    "Xcode", "Finder", "Siri", "Clock", "Weather", "Freeform",
                    "Passwords", "iPhone Mirroring", "Instruments", "FileMerge",
                    "Shortcuts", "Notes", "Reminders", "Calendar", "Contacts",
                    "Home", "Voice Memos", "Photo Booth", "Image Capture",
                    "Grapher", "Chess", "Stickies",
                ]

                // Get currently running app bundle IDs to exclude
                let runningBundleIDs = Self.getRunningAppBundleIDs()

                for dir in appDirs where fm.fileExists(atPath: dir) {
                    guard let contents = try? fm.contentsOfDirectory(
                        at: URL(fileURLWithPath: dir),
                        includingPropertiesForKeys: [.isPackageKey],
                        options: [.skipsHiddenFiles]
                    ) else { continue }

                    for url in contents where url.pathExtension == "app" {
                        let appName = url.deletingPathExtension().lastPathComponent
                        if systemApps.contains(appName) { continue }

                        // Skip currently running apps
                        if let bundleID = Bundle(url: url)?.bundleIdentifier,
                           runningBundleIDs.contains(bundleID) { continue }

                        // Multi-signal last-used detection
                        let lastUsed = Self.getBestLastUsedDate(for: url.path, appName: appName)

                        if let lastUsed = lastUsed, lastUsed < threshold {
                            results.append((url.path, lastUsed, appName))
                        }
                        // If we have NO signal at all, skip (don't assume unused)
                    }
                }

                continuation.resume(returning: results)
            }
        }

        guard !candidates.isEmpty else { return nil }

        var appPaths: [String] = []
        var breakdown: [PathStat] = []
        var totalSize: Int64 = 0
        var totalCount: Int = 0

        for candidate in candidates {
            if cancelRequested { break }
            let (size, count) = await directorySize(candidate.path)
            if size > 0 {
                appPaths.append(candidate.path)
                breakdown.append(PathStat(
                    path: candidate.path, size: size, fileCount: count,
                    lastAccessed: candidate.lastUsed
                ))
                totalSize += size
                totalCount += count
            }
        }

        guard totalSize > 0, !appPaths.isEmpty else { return nil }
        breakdown.sort { $0.size > $1.size }

        return CleanupCategory(
            name: "Unused Apps (>\(thresholdDays)d)", icon: "app.dashed", color: .gray,
            description: "\(appPaths.count) apps not opened in \(thresholdDays)+ days",
            group: .applications, safetyLevel: .caution,
            paths: appPaths, breakdown: breakdown,
            deleteChildrenOnly: false,
            size: totalSize, fileCount: totalCount,
            isSelected: false
        )
    }

    /// Multi-signal detection for app last-used date. Uses the most recent of:
    /// 1. Spotlight kMDItemLastUsedDate
    /// 2. contentAccessDate on the app bundle
    /// 3. Recent modification of app preferences plist
    /// 4. Recent modification of app support data
    private static func getBestLastUsedDate(for appPath: String, appName: String) -> Date? {
        var dates: [Date] = []

        // Signal 1: Spotlight metadata
        if let spotlightDate = getSpotlightLastUsedDate(for: appPath) {
            dates.append(spotlightDate)
        }

        // Signal 2: contentAccessDate on the app bundle
        let appURL = URL(fileURLWithPath: appPath)
        if let rv = try? appURL.resourceValues(forKeys: [.contentAccessDateKey]),
           let accessDate = rv.contentAccessDate {
            dates.append(accessDate)
        }

        // Signal 3: Check preferences plist modification
        if let bundleID = Bundle(url: appURL)?.bundleIdentifier {
            let prefsPath = "\(home)/Library/Preferences/\(bundleID).plist"
            if let attrs = try? FileManager.default.attributesOfItem(atPath: prefsPath),
               let modDate = attrs[.modificationDate] as? Date {
                dates.append(modDate)
            }

            // Signal 4: Check app support folder modification
            let supportPath = "\(home)/Library/Application Support/\(appName)"
            if let attrs = try? FileManager.default.attributesOfItem(atPath: supportPath),
               let modDate = attrs[.modificationDate] as? Date {
                dates.append(modDate)
            }

            // Also check support folder by bundle ID
            let supportPath2 = "\(home)/Library/Application Support/\(bundleID)"
            if let attrs = try? FileManager.default.attributesOfItem(atPath: supportPath2),
               let modDate = attrs[.modificationDate] as? Date {
                dates.append(modDate)
            }
        }

        // Return the most recent signal (most optimistic — if any signal says "used recently", trust it)
        return dates.max()
    }

    /// Get bundle IDs of all currently running applications
    private static func getRunningAppBundleIDs() -> Set<String> {
        var ids = Set<String>()
        for app in NSWorkspace.shared.runningApplications {
            if let bundleID = app.bundleIdentifier {
                ids.insert(bundleID)
            }
        }
        return ids
    }

    private static func getSpotlightLastUsedDate(for path: String) -> Date? {
        guard let output = runCommand("/usr/bin/mdls", arguments: ["-name", "kMDItemLastUsedDate", "-raw", path]) else {
            return nil
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "(null)" || trimmed.isEmpty { return nil }
        return spotlightDateFormatter.date(from: trimmed)
    }

    // MARK: - Docker CLI

    private func scanDockerImages() async -> CleanupCategory? {
        guard let dockerPath = Self.findDocker() else { return nil }
        guard let output = Self.runCommand(dockerPath, arguments: [
            "images", "--format", "{{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.ID}}\t{{.CreatedSince}}"
        ]) else { return nil }

        let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }

        var breakdown: [PathStat] = []
        var totalSize: Int64 = 0

        for line in lines {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 3 else { continue }
            let sizeBytes = Self.parseDockerSize(parts[1])
            totalSize += sizeBytes
            let created = parts.count > 3 ? parts[3] : ""
            breakdown.append(PathStat(
                path: "\(parts[0]) (\(parts[2].prefix(12))) — \(created)",
                size: sizeBytes, fileCount: 1
            ))
        }

        guard totalSize > 0 else { return nil }
        breakdown.sort { $0.size > $1.size }

        return CleanupCategory(
            name: "Docker Images", icon: "shippingbox.circle", color: .blue,
            description: "\(breakdown.count) images — prunes unused images",
            group: .docker, safetyLevel: .review,
            paths: [], breakdown: breakdown,
            deleteChildrenOnly: false, isDockerResource: true,
            dockerCleanCommand: ["image", "prune", "-a", "-f"],
            size: totalSize, fileCount: breakdown.count, isSelected: false
        )
    }

    private func scanDockerStoppedContainers() async -> CleanupCategory? {
        guard let dockerPath = Self.findDocker() else { return nil }
        guard let output = Self.runCommand(dockerPath, arguments: [
            "ps", "-a", "--filter", "status=exited",
            "--format", "{{.Names}}\t{{.Size}}\t{{.ID}}\t{{.Status}}"
        ]) else { return nil }

        let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }

        var breakdown: [PathStat] = []
        var totalSize: Int64 = 0

        for line in lines {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 3 else { continue }
            let sizeBytes = Self.parseDockerSize(parts[1])
            totalSize += sizeBytes
            let status = parts.count > 3 ? parts[3] : ""
            breakdown.append(PathStat(
                path: "\(parts[0]) (\(parts[2].prefix(12))) — \(status)",
                size: sizeBytes, fileCount: 1
            ))
        }

        guard !breakdown.isEmpty else { return nil }
        breakdown.sort { $0.size > $1.size }

        return CleanupCategory(
            name: "Docker Stopped Containers", icon: "stop.circle", color: .orange,
            description: "\(breakdown.count) stopped containers",
            group: .docker, safetyLevel: .safe,
            paths: [], breakdown: breakdown,
            deleteChildrenOnly: false, isDockerResource: true,
            dockerCleanCommand: ["container", "prune", "-f"],
            size: totalSize, fileCount: breakdown.count, isSelected: false
        )
    }

    private func scanDockerBuildCache() async -> CleanupCategory? {
        guard let dockerPath = Self.findDocker() else { return nil }
        guard let dfOutput = Self.runCommand(dockerPath, arguments: [
            "system", "df", "--format", "{{.Type}}\t{{.Size}}\t{{.Reclaimable}}"
        ]) else { return nil }

        for line in dfOutput.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: "\t")
            if parts.count >= 3 && parts[0] == "Build Cache" {
                let totalSize = Self.parseDockerSize(parts[1])
                guard totalSize > 0 else { return nil }
                return CleanupCategory(
                    name: "Docker Build Cache", icon: "hammer.circle", color: .teal,
                    description: "Build cache — \(parts[2]) reclaimable",
                    group: .docker, safetyLevel: .safe,
                    paths: [],
                    breakdown: [PathStat(path: "Build cache (\(parts[2]) reclaimable)", size: totalSize, fileCount: 1)],
                    deleteChildrenOnly: false, isDockerResource: true,
                    dockerCleanCommand: ["builder", "prune", "-f"],
                    size: totalSize, fileCount: 1, isSelected: false
                )
            }
        }
        return nil
    }

    private func runDockerClean(command: [String]) async -> Bool {
        guard let dockerPath = Self.findDocker() else { return false }
        return Self.runCommand(dockerPath, arguments: command) != nil
    }

    private func runOllamaClean(category: CleanupCategory) async -> Bool {
        guard let ollamaPath = Self.findOllama() else { return false }
        // Remove each selected model individually via `ollama rm <model>`
        let selectedModels = category.hasPerFileSelection
            ? category.breakdown.filter(\.isSelected).map(\.path)
            : category.breakdown.map(\.path)
        var anySuccess = false
        for model in selectedModels {
            if Self.runCommand(ollamaPath, arguments: ["rm", model]) != nil {
                anySuccess = true
            }
        }
        return anySuccess
    }

    // MARK: - node_modules

    // MARK: - Ollama Models Scanner

    private func scanOllamaModels() async -> CleanupCategory? {
        guard let ollamaPath = Self.findOllama() else { return nil }
        guard let output = Self.runCommand(ollamaPath, arguments: ["list"]) else { return nil }

        let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
        guard lines.count > 1 else { return nil }

        var breakdown: [PathStat] = []
        var totalSize: Int64 = 0

        // Parse each model line: split by 2+ whitespace chars
        for line in lines.dropFirst() {
            let columns = line.replacingOccurrences(
                of: "\\s{2,}", with: "\t",
                options: .regularExpression
            ).components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            guard columns.count >= 3 else { continue }

            let modelName = columns[0]
            let sizeStr = columns[2]
            let sizeBytes = Self.parseDockerSize(sizeStr)

            totalSize += sizeBytes
            breakdown.append(PathStat(
                path: modelName,
                size: sizeBytes, fileCount: 1
            ))
        }

        guard !breakdown.isEmpty else { return nil }
        breakdown.sort { $0.size > $1.size }

        return CleanupCategory(
            name: "Ollama Models", icon: "brain.head.profile", color: .purple,
            description: "\(breakdown.count) model\(breakdown.count == 1 ? "" : "s") installed — \(Self.formatBytes(totalSize))",
            group: .developer, safetyLevel: .review,
            paths: [], breakdown: breakdown,
            deleteChildrenOnly: false, isOllamaResource: true,
            size: totalSize, fileCount: breakdown.count, isSelected: false
        )
    }

    private func scanNodeModules() async -> CleanupCategory? {
        let fm = FileManager.default
        var searchDirs = [
            "\(Self.home)/Projects", "\(Self.home)/Developer",
            "\(Self.home)/Documents", "\(Self.home)/Desktop",
            "\(Self.home)/GitHub", "\(Self.home)/repos",
            "\(Self.home)/code", "\(Self.home)/src",
            "\(Self.home)/dev", "\(Self.home)/workspace",
            "\(Self.home)/Work", "\(Self.home)/Sites",
        ]

        if let topLevel = try? fm.contentsOfDirectory(atPath: Self.home) {
            for dir in topLevel where !dir.hasPrefix(".") {
                let fullPath = (Self.home as NSString).appendingPathComponent(dir)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue,
                   !["Library", "Applications", "Music", "Movies", "Pictures",
                    "Downloads", "Public"].contains(dir),
                   !searchDirs.contains(fullPath) {
                    searchDirs.append(fullPath)
                }
            }
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let fm = FileManager.default
                var found: [String] = []
                var breakdown: [PathStat] = []
                var totalSize: Int64 = 0
                var totalCount: Int = 0

                for searchDir in searchDirs where fm.fileExists(atPath: searchDir) {
                    Self.findNodeModulesRecursive(
                        in: searchDir, depth: 0, maxDepth: 6, fm: fm,
                        found: &found, breakdown: &breakdown,
                        totalSize: &totalSize, totalCount: &totalCount
                    )
                }

                guard !found.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }

                breakdown.sort { $0.size > $1.size }

                continuation.resume(returning: CleanupCategory(
                    name: "node_modules", icon: "shippingbox.fill", color: .green,
                    description: "\(found.count) node_modules — run npm install to restore",
                    group: .packageManagers, safetyLevel: .safe,
                    paths: found, breakdown: Array(breakdown.prefix(50)),
                    deleteChildrenOnly: false,
                    size: totalSize, fileCount: totalCount,
                    isSelected: true
                ))
            }
        }
    }

    private static func findNodeModulesRecursive(
        in dir: String, depth: Int, maxDepth: Int, fm: FileManager,
        found: inout [String], breakdown: inout [PathStat],
        totalSize: inout Int64, totalCount: inout Int
    ) {
        guard depth < maxDepth else { return }
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return }

        for entry in entries {
            autoreleasepool {
                let fullPath = (dir as NSString).appendingPathComponent(entry)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue else { return }

                if entry == "node_modules" {
                    let (sz, ct) = directorySizeSync(fullPath)
                    if sz > 1_000_000 {
                        found.append(fullPath)
                        breakdown.append(PathStat(path: fullPath, size: sz, fileCount: ct))
                        totalSize += sz
                        totalCount += ct
                    }
                } else if !entry.hasPrefix(".") && entry != "Library" {
                    findNodeModulesRecursive(
                        in: fullPath, depth: depth + 1, maxDepth: maxDepth, fm: fm,
                        found: &found, breakdown: &breakdown,
                        totalSize: &totalSize, totalCount: &totalCount
                    )
                }
            }
        }
    }

    // MARK: - Mail Attachments

    private func scanMailAttachments() async -> CleanupCategory? {
        let mailDir = "\(Self.home)/Library/Mail"
        let fm = FileManager.default
        guard fm.fileExists(atPath: mailDir) else { return nil }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                // Mail Downloads contains cached attachments
                let attachmentsDir = "\(Self.home)/Library/Mail Downloads"
                var paths: [String] = []
                var breakdown: [PathStat] = []
                var totalSize: Int64 = 0
                var totalCount: Int = 0

                if fm.fileExists(atPath: attachmentsDir) {
                    let (sz, ct) = Self.directorySizeSync(attachmentsDir)
                    if sz > 100_000 {
                        paths.append(attachmentsDir)
                        breakdown.append(PathStat(path: attachmentsDir, size: sz, fileCount: ct))
                        totalSize += sz
                        totalCount += ct
                    }
                }

                // Also check Containers mail downloads
                let containerMail = "\(Self.home)/Library/Containers/com.apple.mail/Data/Library/Mail Downloads"
                if fm.fileExists(atPath: containerMail) {
                    let (sz, ct) = Self.directorySizeSync(containerMail)
                    if sz > 100_000 {
                        paths.append(containerMail)
                        breakdown.append(PathStat(path: containerMail, size: sz, fileCount: ct))
                        totalSize += sz
                        totalCount += ct
                    }
                }

                guard totalSize > 500_000, !paths.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }

                continuation.resume(returning: CleanupCategory(
                    name: "Mail Attachments", icon: "envelope.badge.shield.half.filled", color: .blue,
                    description: "Cached mail attachment downloads — re-downloaded from server",
                    group: .system, safetyLevel: .safe,
                    paths: paths, breakdown: breakdown,
                    deleteChildrenOnly: true,
                    size: totalSize, fileCount: totalCount,
                    isSelected: true
                ))
            }
        }
    }

    // MARK: - Orphaned App Data

    private func scanOrphanedAppData() async -> CleanupCategory? {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let fm = FileManager.default
                // Get list of installed app bundle IDs
                let installedBundleIDs = Self.getInstalledAppBundleIDs()

                var orphanPaths: [String] = []
                var breakdown: [PathStat] = []
                var totalSize: Int64 = 0
                var totalCount: Int = 0

                // Check ~/Library/Application Support for orphaned app data
                let supportDir = "\(Self.home)/Library/Application Support"
                if let entries = try? fm.contentsOfDirectory(atPath: supportDir) {
                    for entry in entries {
                        // Skip system/common directories
                        let skipNames: Set<String> = [
                            "com.apple.TCC", "com.apple.sharedfilelist",
                            "AddressBook", "CloudDocs", "CrashReporter",
                            "FileProvider", "Knowledge", "SyncServices",
                            "CallHistoryDB", "CallHistoryTransactions",
                            "Accounts", "iLifeMediaBrowser",
                        ]
                        if entry.hasPrefix("com.apple.") || skipNames.contains(entry) { continue }
                        // Skip our own app data
                        let ownID = Bundle.main.bundleIdentifier ?? "gk.SparkClean"
                        if entry == ownID || entry == "gk.SparkClean" || entry == "SparkClean" { continue }

                        // Check if this looks like a bundle ID or app name
                        let fullPath = (supportDir as NSString).appendingPathComponent(entry)
                        // If it matches a bundle ID pattern and the app isn't installed
                        if entry.contains(".") && entry.count > 5 {
                            if !installedBundleIDs.contains(entry) &&
                               !Self.hasMatchingApp(name: entry, bundleIDs: installedBundleIDs) {
                                let (sz, ct) = Self.directorySizeSync(fullPath)
                                if sz > 1_000_000 { // >1MB
                                    orphanPaths.append(fullPath)
                                    breakdown.append(PathStat(path: fullPath, size: sz, fileCount: ct))
                                    totalSize += sz
                                    totalCount += ct
                                }
                            }
                        }
                    }
                }

                // Check ~/Library/Preferences for orphaned plists
                let prefsDir = "\(Self.home)/Library/Preferences"
                // System plists that are NOT app leftovers (macOS services, agents, daemons)
                let systemPlistPrefixes: [String] = [
                    "com.apple.", "com.microsoft.", "group.",
                    "NSGlobalDomain", "Apple", "systemgroup.",
                ]
                let systemPlistNames: Set<String> = [
                    ".GlobalPreferences", ".GlobalPreferences_m",
                    "loginwindow", "pbs", "systempreferences",
                    "diagnostics_agent", "sharedfilelistd",
                    "ContextStoreAgent", "ScopedBookmarkAgent",
                    "MobileMeAccounts", "familycircled",
                    "mbuseragent", "icloudmailagent",
                    "knowledge-agent", "remindd",
                    "sharingd", "rapportd", "CloudPhotosConfiguration",
                    "symbolichotkeys", "spaces", "dock",
                    "HIToolbox", "universalaccess",
                    "embeddedBinaryValidationUtility",
                    "APMAnalyticsSuiteName", "APMExperimentSuiteName",
                    "WirelessRadioManagerModule", "CoreBluetooth",
                    "UserEventAgent-Aqua", "UserEventAgent-System",
                    "talagent", "cmfsyncagent",
                ]
                // Exclude our own app's bundle ID
                let ownBundlePrefix = Bundle.main.bundleIdentifier ?? "gk.SparkClean"

                if let entries = try? fm.contentsOfDirectory(atPath: prefsDir) {
                    for entry in entries where entry.hasSuffix(".plist") {
                        let bundleID = String(entry.dropLast(6)) // remove .plist
                        // Skip system prefixes
                        if systemPlistPrefixes.contains(where: { bundleID.hasPrefix($0) }) { continue }
                        // Skip known system plist names
                        if systemPlistNames.contains(bundleID) { continue }
                        // Skip our own app
                        if bundleID.hasPrefix(ownBundlePrefix) || bundleID == "gk.SparkClean" { continue }
                        // Skip plists that don't look like bundle IDs (no dots = likely system)
                        if !bundleID.contains(".") { continue }

                        if !installedBundleIDs.contains(bundleID) &&
                           !Self.hasMatchingApp(name: bundleID, bundleIDs: installedBundleIDs) {
                            let fullPath = (prefsDir as NSString).appendingPathComponent(entry)
                            if let attrs = try? fm.attributesOfItem(atPath: fullPath),
                               let sz = attrs[.size] as? Int64, sz > 0 {
                                orphanPaths.append(fullPath)
                                breakdown.append(PathStat(path: fullPath, size: sz, fileCount: 1))
                                totalSize += sz
                                totalCount += 1
                            }
                        }
                    }
                }

                guard totalSize > 1_000_000, !orphanPaths.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }

                breakdown.sort { $0.size > $1.size }

                continuation.resume(returning: CleanupCategory(
                    name: "App Leftovers", icon: "trash.slash", color: .purple,
                    description: "\(orphanPaths.count) leftover files from uninstalled apps",
                    group: .applications, safetyLevel: .review,
                    paths: orphanPaths, breakdown: Array(breakdown.prefix(60)),
                    deleteChildrenOnly: false,
                    size: totalSize, fileCount: totalCount,
                    isSelected: false
                ))
            }
        }
    }

    private static func getInstalledAppBundleIDs() -> Set<String> {
        let fm = FileManager.default
        var ids = Set<String>()
        for dir in ["/Applications", "\(home)/Applications"] {
            guard let contents = try? fm.contentsOfDirectory(
                at: URL(fileURLWithPath: dir),
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in contents where url.pathExtension == "app" {
                if let bundle = Bundle(url: url), let id = bundle.bundleIdentifier {
                    ids.insert(id)
                }
                // Also add the app name as a pseudo-ID
                ids.insert(url.deletingPathExtension().lastPathComponent)
            }
        }
        return ids
    }

    private static func hasMatchingApp(name: String, bundleIDs: Set<String>) -> Bool {
        let nameLower = name.lowercased()
        // Direct match
        if bundleIDs.contains(where: { $0.lowercased() == nameLower }) { return true }

        // Extract last component of bundle-ID-style names (e.g. "org.mozilla.firefox" -> "firefox")
        // Only match if the extracted name is specific enough (>= 5 chars) to avoid false positives
        let components = name.components(separatedBy: ".")
        if components.count >= 3, let appName = components.last, appName.count >= 5 {
            let appNameLower = appName.lowercased()
            for bundleID in bundleIDs {
                let idComponents = bundleID.lowercased().components(separatedBy: ".")
                if let idAppName = idComponents.last, idAppName == appNameLower { return true }
            }
        }

        // Check if any installed bundle ID shares the same domain-reversed prefix
        // e.g. "com.example.app" matches "com.example.app.helper"
        if components.count >= 3 {
            let prefix = components.prefix(3).joined(separator: ".").lowercased()
            for bundleID in bundleIDs {
                if bundleID.lowercased().hasPrefix(prefix) { return true }
            }
        }

        return false
    }

    // MARK: - New Feature Scans

    /// Feature 1: Large Files Scanner
    private func scanLargeFiles() async -> CleanupCategory? {
        let thresholdMB = settingLargeFileThresholdMB
        let thresholdBytes = Int64(thresholdMB) * 1_000_000
        let dirs = settingLargeFileScanDirs
        let includeVideos = settingLargeFileIncludeVideos
        let includeImages = settingLargeFileIncludeImages
        let includeArchives = settingLargeFileIncludeArchives
        let includeInstallers = settingLargeFileIncludeInstallers
        let includeAudio = settingLargeFileIncludeAudio
        let includeOther = settingLargeFileIncludeOther
        let maxAgeDays = settingLargeFileMaxAgeDays
        let maxResults = settingLargeFileMaxResults

        let packageExtensions: Set<String> = ["vmwarevm", "pvs", "fcpbundle", "sparseimage", "sparsebundle",
                                               "photoslibrary", "band", "logicx", "rtfd", "pages", "numbers", "key"]
        let videoExts: Set<String> = ["mp4", "mov", "avi", "mkv", "wmv", "flv", "webm", "m4v", "ts", "mts", "vob", "mpg", "mpeg"]
        let imageExts: Set<String> = ["raw", "cr2", "cr3", "nef", "arw", "dng", "tiff", "tif", "psd", "ai", "bmp", "svg", "eps"]
        let archiveExts: Set<String> = ["zip", "tar", "gz", "7z", "rar", "bz2", "xz", "tgz", "zst", "lz", "cab", "sit", "sitx"]
        let installerExts: Set<String> = ["dmg", "pkg", "iso", "msi", "app"]
        let audioExts: Set<String> = ["wav", "flac", "aiff", "aif", "alac", "mp3", "m4a", "ogg", "wma", "ape", "dsd", "dsf"]

        guard !dirs.isEmpty else { return nil }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let fm = FileManager.default
                var filePaths: [String] = []
                var breakdown: [PathStat] = []
                var totalSize: Int64 = 0
                let ageThreshold: Date? = maxAgeDays > 0
                    ? Date().addingTimeInterval(-Double(maxAgeDays) * 86400) : nil

                for dir in dirs where fm.fileExists(atPath: dir) {
                    guard let enumerator = fm.enumerator(
                        at: URL(fileURLWithPath: dir),
                        includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey, .isPackageKey,
                                                      .isSymbolicLinkKey, .contentAccessDateKey,
                                                      .ubiquitousItemDownloadingStatusKey],
                        options: [.skipsHiddenFiles, .skipsPackageDescendants]
                    ) else { continue }

                    for case let url as URL in enumerator {
                        autoreleasepool {
                            guard let rv = try? url.resourceValues(
                                forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey, .isPackageKey,
                                          .isSymbolicLinkKey, .contentAccessDateKey,
                                          .ubiquitousItemDownloadingStatusKey]
                            ) else { return }

                            if rv.ubiquitousItemDownloadingStatus == .notDownloaded { return }
                            if rv.isSymbolicLink == true { return }
                            let ext = url.pathExtension.lowercased()
                            if rv.isPackage == true || packageExtensions.contains(ext) {
                                enumerator.skipDescendants()
                                return
                            }
                            guard rv.isRegularFile == true else { return }
                            if isPathScanned(url.path) { return }
                            // Also skip files inside directories already scanned by other phases
                            // (e.g., a large file inside a folder flagged by "Old Downloads")
                            let parentDir = (url.path as NSString).deletingLastPathComponent
                            if isPathScanned(parentDir) { return }

                            let size = Int64(rv.totalFileAllocatedSize ?? 0)
                            guard size >= thresholdBytes else { return }

                            // File age filter
                            if let ageThreshold, let accessed = rv.contentAccessDate, accessed > ageThreshold { return }

                            let path = url.path
                            if path.contains(".app/Contents/") || path.contains(".framework/") { return }

                            // File type filter
                            let isVideo = videoExts.contains(ext)
                            let isImage = imageExts.contains(ext)
                            let isArchive = archiveExts.contains(ext)
                            let isInstaller = installerExts.contains(ext)
                            let isAudio = audioExts.contains(ext)
                            let isKnown = isVideo || isImage || isArchive || isInstaller || isAudio

                            if isVideo && !includeVideos { return }
                            if isImage && !includeImages { return }
                            if isArchive && !includeArchives { return }
                            if isInstaller && !includeInstallers { return }
                            if isAudio && !includeAudio { return }
                            if !isKnown && !includeOther { return }

                            filePaths.append(path)
                            insertScannedPath(path)

                            breakdown.append(PathStat(path: path, size: size, fileCount: 1,
                                                       lastAccessed: rv.contentAccessDate))
                            totalSize += size
                        }
                    }
                }

                breakdown.sort { $0.size > $1.size }
                let capped = Array(breakdown.prefix(maxResults))
                let cappedPaths = capped.map(\.path)
                guard !filePaths.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }

                let cappedSize = capped.reduce(0 as Int64) { $0 + $1.size }

                continuation.resume(returning: CleanupCategory(
                    name: "Large Files (>\(thresholdMB) MB)", icon: "doc.fill", color: .orange,
                    description: "\(filePaths.count) large files across user directories",
                    group: .largeFiles, safetyLevel: .review,
                    paths: cappedPaths, breakdown: capped,
                    deleteChildrenOnly: false,
                    size: cappedSize, fileCount: capped.count,
                    isSelected: false
                ))
            }
        }
    }

    /// Feature 2: Virtual Environments Scanner
    private func scanVirtualEnvironments() async -> CleanupCategory? {
        let projectDirs = [
            "\(Self.home)/Projects", "\(Self.home)/Developer", "\(Self.home)/Documents",
            "\(Self.home)/Desktop", "\(Self.home)/GitHub", "\(Self.home)/repos",
            "\(Self.home)/code", "\(Self.home)/src", "\(Self.home)/dev",
            "\(Self.home)/workspace", "\(Self.home)/Work", "\(Self.home)/Sites"
        ]
        let fixedPaths: [(String, String)] = [
            ("\(Self.home)/.virtualenvs", "virtualenvwrapper"),
            ("\(Self.home)/.local/share/virtualenvs", "pipenv"),
            ("\(Self.home)/.conda/envs", "conda"),
            ("\(Self.home)/anaconda3/envs", "anaconda"),
            ("\(Self.home)/miniconda3/envs", "miniconda"),
        ]
        let skipDirs: Set<String> = [".git", "node_modules", "Pods", "DerivedData", "build", ".build",
                                       "__pycache__", ".tox", ".mypy_cache"]

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let fm = FileManager.default
                var filePaths: [String] = []
                var breakdown: [PathStat] = []
                var totalSize: Int64 = 0

                func isVenv(_ dirPath: String) -> Bool {
                    let cfg = (dirPath as NSString).appendingPathComponent("pyvenv.cfg")
                    let activate = (dirPath as NSString).appendingPathComponent("bin/activate")
                    return fm.fileExists(atPath: cfg) || fm.fileExists(atPath: activate)
                }

                // Search project directories for venvs
                func searchDir(_ base: String, depth: Int) {
                    guard depth < 4, fm.fileExists(atPath: base) else { return }
                    guard let entries = try? fm.contentsOfDirectory(atPath: base) else { return }
                    for entry in entries {
                        if skipDirs.contains(entry) { continue }
                        let full = (base as NSString).appendingPathComponent(entry)
                        var isDir: ObjCBool = false
                        guard fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue else { continue }

                        if (entry == "venv" || entry == ".venv" || entry == "env") && isVenv(full) {
                            addVenv(full, type: "Python venv")
                        } else if entry == "vendor" {
                            let bundlePath = (full as NSString).appendingPathComponent("bundle")
                            if fm.fileExists(atPath: bundlePath) {
                                addVenv(bundlePath, type: "Ruby Bundler")
                            }
                        } else {
                            searchDir(full, depth: depth + 1)
                        }
                    }
                }

                func addVenv(_ path: String, type _: String) {
                    if isPathScanned(path) { return }
                    let (size, count) = Self.directorySizeSync(path)
                    guard size >= ScanConstants.minVenvSizeBytes else { return }
                    filePaths.append(path)
                    insertScannedPath(path)
                    breakdown.append(PathStat(path: path, size: size, fileCount: count))
                    totalSize += size
                }

                // Scan fixed paths (virtualenvwrapper, pipenv, conda)
                for (basePath, type) in fixedPaths {
                    guard fm.fileExists(atPath: basePath),
                          let entries = try? fm.contentsOfDirectory(atPath: basePath) else { continue }
                    for entry in entries {
                        if entry == "base" { continue } // Skip conda base
                        let full = (basePath as NSString).appendingPathComponent(entry)
                        addVenv(full, type: type)
                    }
                }

                // Scan project directories
                for dir in projectDirs where fm.fileExists(atPath: dir) {
                    searchDir(dir, depth: 0)
                }

                guard !filePaths.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }

                breakdown.sort { $0.size > $1.size }
                let capped = Array(breakdown.prefix(ScanConstants.maxVenvEntries))

                continuation.resume(returning: CleanupCategory(
                    name: "Virtual Environments", icon: "terminal", color: .green,
                    description: "\(filePaths.count) Python/Ruby virtual environments",
                    group: .packageManagers, safetyLevel: .review,
                    paths: filePaths, breakdown: capped,
                    deleteChildrenOnly: false,
                    size: totalSize, fileCount: filePaths.count,
                    isSelected: false
                ))
            }
        }
    }

    /// Feature 3: iOS Device Backups
    private func scanIOSBackups() async -> CleanupCategory? {
        let backupDir = "\(Self.home)/Library/Application Support/MobileSync/Backup"
        let fm = FileManager.default
        guard fm.fileExists(atPath: backupDir) else { return nil }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let entries = try? fm.contentsOfDirectory(atPath: backupDir) else {
                    continuation.resume(returning: nil)
                    return
                }

                var filePaths: [String] = []
                var breakdown: [PathStat] = []
                var totalSize: Int64 = 0

                for entry in entries {
                    let full = (backupDir as NSString).appendingPathComponent(entry)
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue else { continue }

                    let (size, count) = Self.directorySizeSync(full)
                    guard size > 0 else { continue }

                    // Try to read device name from Info.plist
                    var _deviceName = entry
                    let infoPlist = (full as NSString).appendingPathComponent("Info.plist")
                    if let data = fm.contents(atPath: infoPlist),
                       let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] {
                        if let name = plist["Device Name"] as? String {
                            _deviceName = name
                        }
                        if let date = plist["Last Backup Date"] as? Date {
                            let fmt = DateFormatter()
                            fmt.dateStyle = .medium
                            _deviceName += " (\(fmt.string(from: date)))"
                        }
                    }
                    filePaths.append(full)
                    breakdown.append(PathStat(path: full, size: size, fileCount: count, displayName: _deviceName))
                    totalSize += size
                }

                guard !filePaths.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }

                breakdown.sort { $0.size > $1.size }

                continuation.resume(returning: CleanupCategory(
                    name: "iOS Device Backups", icon: "iphone", color: .blue,
                    description: "\(filePaths.count) device backup(s) — review before deleting",
                    group: .system, safetyLevel: .review,
                    paths: filePaths, breakdown: breakdown,
                    deleteChildrenOnly: false,
                    size: totalSize, fileCount: filePaths.count,
                    isSelected: false
                ))
            }
        }
    }

    /// Feature 4: iOS Software Updates (IPSW)
    private func scanIPSWFiles() async -> CleanupCategory? {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let fm = FileManager.default
                var filePaths: [String] = []
                var breakdown: [PathStat] = []
                var totalSize: Int64 = 0

                // Direct path
                let directPath = "\(Self.home)/Library/iTunes/iPhone Software Updates"
                if fm.fileExists(atPath: directPath) {
                    let (size, count) = Self.directorySizeSync(directPath)
                    if size > 0 {
                        filePaths.append(directPath)
                        breakdown.append(PathStat(path: directPath, size: size, fileCount: count))
                        totalSize += size
                    }
                }

                // Group Containers wildcard
                let groupDir = "\(Self.home)/Library/Group Containers"
                if let containers = try? fm.contentsOfDirectory(atPath: groupDir) {
                    for container in containers {
                        let ipswPath = (groupDir as NSString).appendingPathComponent(container + "/iPhone Software Updates")
                        if fm.fileExists(atPath: ipswPath) {
                            let (size, count) = Self.directorySizeSync(ipswPath)
                            if size > 0 {
                                filePaths.append(ipswPath)
                                breakdown.append(PathStat(path: ipswPath, size: size, fileCount: count))
                                totalSize += size
                            }
                        }
                    }
                }

                guard !filePaths.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }

                continuation.resume(returning: CleanupCategory(
                    name: "iOS Software Updates", icon: "arrow.down.app", color: .blue,
                    description: "Downloaded firmware files (IPSW) — no longer needed after update",
                    group: .system, safetyLevel: .safe,
                    paths: filePaths, breakdown: breakdown,
                    deleteChildrenOnly: false,
                    size: totalSize, fileCount: filePaths.count,
                    isSelected: true
                ))
            }
        }
    }

    /// Feature 5: iMessage Attachments
    private func scanIMessageAttachments() async -> CleanupCategory? {
        let attachDir = "\(Self.home)/Library/Messages/Attachments"
        let fm = FileManager.default
        guard fm.isReadableFile(atPath: attachDir) else { return nil }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let (size, count) = Self.directorySizeSync(attachDir)
                guard size > ScanConstants.minCacheSizeBytes else {
                    continuation.resume(returning: nil)
                    return
                }

                continuation.resume(returning: CleanupCategory(
                    name: "iMessage Attachments", icon: "message.fill", color: .green,
                    description: "Cached message attachments — deleting creates 'Missing Attachment' placeholders in Messages. May re-download if Messages in iCloud is enabled.",
                    group: .system, safetyLevel: .caution,
                    paths: [attachDir],
                    breakdown: [PathStat(path: attachDir, size: size, fileCount: count)],
                    deleteChildrenOnly: true,
                    size: size, fileCount: count,
                    isSelected: false
                ))
            }
        }
    }

    /// Feature 7: Screen Recordings
    private func scanScreenRecordings() async -> CleanupCategory? {
        let thresholdDays = settingScreenRecordingThresholdDays
        let threshold = Date().addingTimeInterval(-Double(thresholdDays) * 86400)
        let minSize: Int64 = 50_000_000 // 50MB

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let fm = FileManager.default
                var filePaths: [String] = []
                var breakdown: [PathStat] = []
                var totalSize: Int64 = 0

                // Try mdfind first for fast detection
                var spotlightPaths: Set<String> = []
                if let output = Self.runCommand("/usr/bin/mdfind", arguments: ["kMDItemIsScreenCapture == 1"]) {
                    for line in output.components(separatedBy: "\n") where !line.isEmpty {
                        spotlightPaths.insert(line)
                    }
                }

                let dirs = ["\(Self.home)/Desktop", "\(Self.home)/Movies"]
                for dir in dirs where fm.fileExists(atPath: dir) {
                    guard let contents = try? fm.contentsOfDirectory(
                        at: URL(fileURLWithPath: dir),
                        includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey, .contentModificationDateKey],
                        options: [.skipsHiddenFiles]
                    ) else { continue }

                    for url in contents {
                        let ext = url.pathExtension.lowercased()
                        guard ext == "mov" || ext == "mp4" else { continue }

                        let isScreenRecording = spotlightPaths.contains(url.path) ||
                            url.lastPathComponent.lowercased().hasPrefix("screen recording") ||
                            url.lastPathComponent.lowercased().hasPrefix("simulator screen recording") ||
                            url.lastPathComponent.lowercased().hasPrefix("capture")

                        guard isScreenRecording else { continue }
                        guard let rv = try? url.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey, .contentModificationDateKey]),
                              rv.isRegularFile == true else { continue }

                        let size = Int64(rv.totalFileAllocatedSize ?? rv.fileSize ?? 0)
                        let modDate = rv.contentModificationDate ?? Date.distantPast
                        guard size >= minSize, modDate < threshold else { continue }
                        guard !isPathScanned(url.path) else { continue }

                        filePaths.append(url.path)
                        insertScannedPath(url.path)
                        breakdown.append(PathStat(path: url.path, size: size, fileCount: 1))
                        totalSize += size
                    }
                }

                guard !filePaths.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }

                breakdown.sort { $0.size > $1.size }

                continuation.resume(returning: CleanupCategory(
                    name: "Screen Recordings (>\(thresholdDays)d)", icon: "record.circle", color: .teal,
                    description: "\(filePaths.count) old screen recordings over 50 MB",
                    group: .storage, safetyLevel: .review,
                    paths: filePaths, breakdown: breakdown,
                    deleteChildrenOnly: false,
                    size: totalSize, fileCount: filePaths.count,
                    isSelected: false
                ))
            }
        }
    }

    /// Feature 8: Broken Symlinks
    private func scanBrokenSymlinks() async -> CleanupCategory? {
        let dirs = [
            "\(Self.home)/Library",
            "/usr/local/bin",
            "/opt/homebrew/bin"
        ]
        let excludeDirs: Set<String> = ["Keychains", "Group Containers", "Mail",
                                        "Caches", "Containers", "Developer"]

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let fm = FileManager.default
                var filePaths: [String] = []
                var breakdown: [PathStat] = []

                for dir in dirs where fm.fileExists(atPath: dir) {
                    guard let enumerator = fm.enumerator(
                        at: URL(fileURLWithPath: dir),
                        includingPropertiesForKeys: [.isSymbolicLinkKey],
                        options: [.skipsPackageDescendants]
                    ) else { continue }

                    while let obj = enumerator.nextObject() {
                        guard let url = obj as? URL else { continue }
                        autoreleasepool {
                            // Skip excluded directories
                            let components = url.pathComponents
                            if components.contains(where: { excludeDirs.contains($0) }) {
                                enumerator.skipDescendants()
                                return
                            }

                            guard let rv = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
                                  rv.isSymbolicLink == true else { return }

                            // Detect broken symlink
                            guard let target = try? fm.destinationOfSymbolicLink(atPath: url.path) else { return }
                            let resolvedTarget: String
                            if target.hasPrefix("/") {
                                resolvedTarget = target
                            } else {
                                resolvedTarget = ((url.path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(target)
                            }

                            // Skip if target is on external volume
                            if resolvedTarget.hasPrefix("/Volumes/") { return }

                            if !fm.fileExists(atPath: resolvedTarget) {
                                filePaths.append(url.path)
                                breakdown.append(PathStat(path: url.path, size: 0, fileCount: 1))
                            }
                        }
                    }
                }

                guard !filePaths.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }

                continuation.resume(returning: CleanupCategory(
                    name: "Broken Symlinks (\(filePaths.count) found)", icon: "link", color: .gray,
                    description: "Symbolic links pointing to nonexistent targets",
                    group: .system, safetyLevel: .review,
                    paths: filePaths, breakdown: breakdown,
                    deleteChildrenOnly: false,
                    size: 0, fileCount: filePaths.count,
                    isSelected: false
                ))
            }
        }
    }

    // MARK: - Helpers

    /// Find the newest file modification date inside a directory (for accurate age checks).
    /// Returns nil if the directory is empty or unreadable.
    private static func newestFileDate(in path: String) -> Date? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        var newest: Date?
        var checked = 0
        while let obj = enumerator.nextObject() {
            guard let url = obj as? URL else { continue }
            autoreleasepool {
                guard let rv = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                      rv.isRegularFile == true,
                      let mod = rv.contentModificationDate else { return }
                if newest == nil || mod > newest! { newest = mod }
            }
            checked += 1
            // Early exit: if we find ANY recent file, the directory is active
            if checked > 500 { break }
        }
        return newest
    }

    static func findDocker() -> String? {
        for path in ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "/usr/bin/docker"] {
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return nil
    }

    static func findOllama() -> String? {
        for path in ["/usr/local/bin/ollama", "/opt/homebrew/bin/ollama", "/usr/bin/ollama"] {
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return nil
    }

    static func runCommand(_ path: String, arguments: [String], timeout: TimeInterval = 30) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()

            // Terminate the process if it exceeds the timeout
            let timeoutWorkItem = DispatchWorkItem {
                if process.isRunning {
                    process.terminate()
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)

            // Read pipe data BEFORE waitUntilExit to prevent deadlock when output exceeds pipe buffer (~64KB)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            timeoutWorkItem.cancel()

            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    static func parseDockerSize(_ str: String) -> Int64 {
        let trimmed = str.trimmingCharacters(in: .whitespaces)
        let pattern = /^([\d.]+)\s*(B|KB|MB|GB|TB|kB)/
        guard let match = trimmed.firstMatch(of: pattern) else { return 0 }
        let value = Double(match.1) ?? 0
        switch String(match.2).uppercased() {
        case "B": return Int64(value)
        case "KB": return Int64(value * 1_000)
        case "MB": return Int64(value * 1_000_000)
        case "GB": return Int64(value * 1_000_000_000)
        case "TB": return Int64(value * 1_000_000_000_000)
        default: return 0
        }
    }

    // MARK: - Export Report

    func exportReport() -> String {
        exportDetailedReport(verbose: false)
    }

    func exportDetailedReport(verbose: Bool) -> String {
        let dateStr = Date().formatted(date: .long, time: .standard)
        var r = """
        ╔═══════════════════════════════════════════════════════════════════╗
        ║  SparkClean - Detailed Scan Audit Report                        ║
        ║  Generated: \(dateStr)\(String(repeating: " ", count: max(0, 40 - dateStr.count)))║
        ╚═══════════════════════════════════════════════════════════════════╝

        """

        // System info
        r += "SYSTEM INFORMATION\n"
        r += String(repeating: "─", count: 60) + "\n"
        r += "  macOS Version: \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        r += "  Machine:       \(Self.runCommand("/usr/sbin/sysctl", arguments: ["-n", "hw.model"]) ?? "Unknown")\n"
        r += "  User:          \(NSUserName())\n"
        r += "  Home:          \(Self.home)\n\n"

        if let disk = diskUsage {
            r += "DISK USAGE\n"
            r += String(repeating: "─", count: 60) + "\n"
            r += "  Total Space:     \(Self.formatBytes(disk.totalSpace))\n"
            r += "  Used Space:      \(Self.formatBytes(disk.usedSpace)) (\(String(format: "%.1f%%", disk.usedPercentage * 100)))\n"
            r += "  Free Space:      \(Self.formatBytes(disk.freeSpace))\n"
            r += "  Purgeable:       \(Self.formatBytes(disk.purgeableSpace))\n"
            r += "  Reclaimable:     \(Self.formatBytes(overallSize))\n"
            r += "  Selected:        \(Self.formatBytes(totalSize))\n\n"
        }

        if let summary = lastScanSummary {
            r += "SCAN SUMMARY\n"
            r += String(repeating: "─", count: 60) + "\n"
            r += "  Categories:      \(summary.totalCategories)\n"
            r += "  Total Files:     \(summary.totalFiles)\n"
            r += "  Total Size:      \(Self.formatBytes(summary.totalSize))\n"
            r += "  Scan Duration:   \(String(format: "%.2f", summary.scanDuration))s\n"
            r += "  Scan Time:       \(summary.timestamp.formatted(date: .abbreviated, time: .standard))\n\n"
        }

        r += "═══════════════════════════════════════════════════════════════════\n"
        r += "DETAILED FINDINGS BY CATEGORY\n"
        r += "═══════════════════════════════════════════════════════════════════\n\n"

        for group in CategoryGroup.allCases {
            let groupCats = categoriesForGroup(group)
            guard !groupCats.isEmpty else { continue }

            r += "┌─── \(group.rawValue.uppercased()) ─── \(Self.formatBytes(sizeForGroup(group))) total\n"
            r += "│\n"

            for (catIdx, cat) in groupCats.enumerated() {
                let isLast = catIdx == groupCats.count - 1
                let prefix = isLast ? "└" : "├"
                let childPrefix = isLast ? "  " : "│ "
                let marker = cat.isSelected ? "✓" : "○"

                r += "\(prefix)── [\(marker)] \(cat.name)\n"
                r += "\(childPrefix)   Safety:      \(cat.safetyLevel.rawValue) — \(cat.safetyLevel.label)\n"
                r += "\(childPrefix)   Description: \(cat.description)\n"
                r += "\(childPrefix)   Total Size:  \(Self.formatBytes(cat.size))\n"
                r += "\(childPrefix)   File Count:  \(cat.fileCount)\n"
                r += "\(childPrefix)   Selected:    \(cat.isSelected ? "Yes" : "No")\n"

                if cat.isDockerResource {
                    r += "\(childPrefix)   Type:        Docker resource (cleaned via Docker CLI)\n"
                    if let cmd = cat.dockerCleanCommand {
                        r += "\(childPrefix)   Command:     docker \(cmd.joined(separator: " "))\n"
                    }
                }

                if cat.isOllamaResource {
                    r += "\(childPrefix)   Type:        Ollama model (cleaned via `ollama rm`)\n"
                }

                if !cat.paths.isEmpty {
                    r += "\(childPrefix)   Paths:\n"
                    for path in cat.paths {
                        r += "\(childPrefix)     → \(path)\n"
                    }
                }

                // Detailed breakdown — ALL entries, not just top 5
                if !cat.breakdown.isEmpty {
                    r += "\(childPrefix)   Breakdown (\(cat.breakdown.count) entries):\n"
                    for stat in cat.breakdown {
                        let name = (stat.path as NSString).lastPathComponent
                        let dir = (stat.path as NSString).deletingLastPathComponent
                        r += "\(childPrefix)     ┊ \(Self.formatBytes(stat.size).padding(toLength: 10, withPad: " ", startingAt: 0)) \(name)\n"
                        if verbose {
                            r += "\(childPrefix)     ┊            Path: \(stat.path)\n"
                            r += "\(childPrefix)     ┊            Dir:  \(dir)\n"
                            r += "\(childPrefix)     ┊            Files: \(stat.fileCount)\n"
                            if let accessed = stat.lastAccessed {
                                r += "\(childPrefix)     ┊            Last Accessed: \(accessed.formatted(date: .abbreviated, time: .standard))\n"
                            }
                        }
                    }
                }

                r += "\(childPrefix)\n"
            }
            r += "\n"
        }

        // Safety summary
        r += "═══════════════════════════════════════════════════════════════════\n"
        r += "SAFETY AUDIT SUMMARY\n"
        r += "═══════════════════════════════════════════════════════════════════\n\n"

        let safeCats = categories.filter { $0.safetyLevel == .safe }
        let reviewCats = categories.filter { $0.safetyLevel == .review }
        let cautionCats = categories.filter { $0.safetyLevel == .caution }

        let safeSize = safeCats.reduce(0 as Int64) { $0 + $1.size }
        let reviewSize = reviewCats.reduce(0 as Int64) { $0 + $1.size }
        let cautionSize = cautionCats.reduce(0 as Int64) { $0 + $1.size }

        r += "  ✓ SAFE (\(safeCats.count) categories, \(Self.formatBytes(safeSize))):\n"
        r += "    Caches, temp files, logs — automatically rebuilt. No risk of data loss.\n"
        for cat in safeCats {
            r += "    • \(cat.name): \(Self.formatBytes(cat.size))\n"
        }

        r += "\n  ⚠ REVIEW (\(reviewCats.count) categories, \(Self.formatBytes(reviewSize))):\n"
        r += "    User files that may be wanted — review before deleting.\n"
        for cat in reviewCats {
            r += "    • \(cat.name): \(Self.formatBytes(cat.size))\n"
        }

        r += "\n  ✕ CAUTION (\(cautionCats.count) categories, \(Self.formatBytes(cautionSize))):\n"
        r += "    App data or system files — could cause issues if deleted.\n"
        for cat in cautionCats {
            r += "    • \(cat.name): \(Self.formatBytes(cat.size))\n"
        }

        r += "\n═══════════════════════════════════════════════════════════════════\n"
        r += "END OF REPORT\n"
        r += "═══════════════════════════════════════════════════════════════════\n"

        return r
    }

    // MARK: - Formatting

    private static let isoFormatter = ISO8601DateFormatter()

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useAll]
        f.countStyle = .file
        return f
    }()

    static func formatBytes(_ bytes: Int64) -> String {
        byteFormatter.string(fromByteCount: bytes)
    }

    private static let spotlightDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
