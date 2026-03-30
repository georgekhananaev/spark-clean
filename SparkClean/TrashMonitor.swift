//
//  TrashMonitor.swift
//  SparkClean
//
//  Created by George Khananaev on 3/30/26.
//

import Foundation
import AppKit
import UserNotifications

/// Lightweight Trash monitor that detects when .app bundles are moved to Trash
/// and offers to clean leftover files. Uses kernel-level DispatchSource for
/// zero CPU usage when idle.
///
/// Performance characteristics:
/// - Idle: 0% CPU, ~1MB RSS overhead (just the file descriptor)
/// - Triggered: brief spike to scan ~/Library paths, then back to idle
/// - Memory: all scan data is local to the callback, released immediately
@Observable
final class TrashMonitor {
    var lastDetectedApp: DetectedTrashedApp?
    var isEnabled: Bool = false {
        didSet {
            if isEnabled { start() } else { stop() }
        }
    }

    private var source: DispatchSourceFileSystemObject?
    private var trashFD: Int32 = -1
    private var knownApps: Set<String> = []
    private let scanQueue = DispatchQueue(label: "gk.SparkClean.trashMonitor", qos: .utility)

    struct DetectedTrashedApp: Identifiable {
        let id = UUID()
        let appName: String
        let bundleID: String
        let trashedAppPath: String
        let leftovers: [LeftoverItem]
        let totalSize: Int64

        var formattedSize: String {
            CleanupManager.formatBytes(totalSize)
        }
    }

    struct LeftoverItem {
        let path: String
        let category: String
        let size: Int64
    }

    // MARK: - Lifecycle

    func start() {
        guard source == nil else { return }
        let trashPath = NSHomeDirectory() + "/.Trash"

        // Snapshot current .app bundles so we only trigger on new ones
        knownApps = currentTrashApps(at: trashPath)

        trashFD = open(trashPath, O_EVTONLY)
        guard trashFD >= 0 else { return }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: trashFD,
            eventMask: .write,      // fires when files are added/removed
            queue: scanQueue
        )

        src.setEventHandler { [weak self] in
            self?.handleTrashChange()
        }

        src.setCancelHandler { [weak self] in
            guard let self else { return }
            if self.trashFD >= 0 {
                close(self.trashFD)
                self.trashFD = -1
            }
        }

        source = src
        src.resume()

        // Request notification permission (idempotent)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func stop() {
        source?.cancel()
        source = nil
        knownApps.removeAll()
    }

    deinit {
        stop()
    }

    // MARK: - Detection

    private func handleTrashChange() {
        let trashPath = NSHomeDirectory() + "/.Trash"
        let current = currentTrashApps(at: trashPath)
        let newApps = current.subtracting(knownApps)
        knownApps = current

        for appPath in newApps {
            scanLeftovers(for: appPath)
        }
    }

    private func currentTrashApps(at trashPath: String) -> Set<String> {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: trashPath) else { return [] }
        var apps = Set<String>()
        for item in contents where item.hasSuffix(".app") {
            apps.insert((trashPath as NSString).appendingPathComponent(item))
        }
        return apps
    }

    // MARK: - Leftover Scanning (lightweight, single-app)

    private func scanLeftovers(for trashedAppPath: String) {
        let fm = FileManager.default
        let home = NSHomeDirectory()

        // Extract app info from the trashed bundle
        let appName = ((trashedAppPath as NSString).lastPathComponent as NSString).deletingPathExtension
        let bundleID: String
        if let bundle = Bundle(path: trashedAppPath), let id = bundle.bundleIdentifier {
            bundleID = id
        } else {
            bundleID = ""
        }

        guard !appName.isEmpty else { return }

        // Quick scan for leftovers — only check existence, compute size only for found items
        var leftovers: [LeftoverItem] = []
        var totalSize: Int64 = 0

        let candidates: [(path: String, category: String)] = {
            var c: [(String, String)] = []
            if !bundleID.isEmpty {
                c.append(("\(home)/Library/Caches/\(bundleID)", "Caches"))
                c.append(("\(home)/Library/Application Support/\(bundleID)", "App Support"))
                c.append(("\(home)/Library/Preferences/\(bundleID).plist", "Preferences"))
                c.append(("\(home)/Library/Containers/\(bundleID)", "Container"))
                c.append(("\(home)/Library/Saved Application State/\(bundleID).savedState", "Saved State"))
                c.append(("\(home)/Library/Logs/\(bundleID)", "Logs"))
                c.append(("\(home)/Library/HTTPStorages/\(bundleID)", "HTTP Storage"))
                c.append(("\(home)/Library/WebKit/\(bundleID)", "WebKit Data"))
            }
            // Also check by app name
            c.append(("\(home)/Library/Application Support/\(appName)", "App Support"))
            c.append(("\(home)/Library/Caches/\(appName)", "Caches"))
            c.append(("\(home)/Library/Logs/\(appName)", "Logs"))
            return c
        }()

        // Check LaunchAgents
        let launchAgentDirs = [
            "\(home)/Library/LaunchAgents",
            "/Library/LaunchAgents"
        ]

        for dir in launchAgentDirs {
            if let entries = try? fm.contentsOfDirectory(atPath: dir) {
                for entry in entries where entry.hasSuffix(".plist") {
                    let matches = (!bundleID.isEmpty && entry.contains(bundleID)) ||
                                  entry.lowercased().contains(appName.lowercased())
                    if matches {
                        let path = (dir as NSString).appendingPathComponent(entry)
                        let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? Int64 ?? 0
                        leftovers.append(LeftoverItem(path: path, category: "Launch Agent", size: size))
                        totalSize += size
                    }
                }
            }
        }

        var seen = Set<String>()
        for (path, category) in candidates {
            guard fm.fileExists(atPath: path) else { continue }
            let resolved = (path as NSString).resolvingSymlinksInPath
            guard !seen.contains(resolved) else { continue }
            seen.insert(resolved)

            autoreleasepool {
                let size: Int64
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                    size = quickDirSize(path)
                } else {
                    size = (try? fm.attributesOfItem(atPath: path))?[.size] as? Int64 ?? 0
                }
                if size > 0 {
                    leftovers.append(LeftoverItem(path: path, category: category, size: size))
                    totalSize += size
                }
            }
        }

        // Only notify if leftovers are substantial (> 1MB)
        guard totalSize > 1_000_000 else { return }

        let detected = DetectedTrashedApp(
            appName: appName,
            bundleID: bundleID,
            trashedAppPath: trashedAppPath,
            leftovers: leftovers,
            totalSize: totalSize
        )

        Task { @MainActor in
            self.lastDetectedApp = detected
        }

        sendNotification(appName: appName, size: totalSize)
    }

    /// Quick directory size — caps at 10,000 files to stay fast
    private func quickDirSize(_ path: String) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey],
            options: [],
            errorHandler: nil
        ) else { return 0 }

        var total: Int64 = 0
        var count = 0
        let maxFiles = 10_000

        while let obj = enumerator.nextObject() {
            guard let url = obj as? URL else { continue }
            autoreleasepool {
                guard let rv = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { return }
                if rv.isRegularFile == true {
                    total += Int64(rv.totalFileAllocatedSize ?? 0)
                    count += 1
                }
            }
            if count >= maxFiles { break }
        }
        return total
    }

    // MARK: - Notification

    private func sendNotification(appName: String, size: Int64) {
        let content = UNMutableNotificationContent()
        content.title = "SparkClean"
        content.body = "\(appName) left \(CleanupManager.formatBytes(size)) of data behind. Open SparkClean to clean up."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "trashMonitor-\(UUID().uuidString)",
            content: content,
            trigger: nil // deliver immediately
        )

        UNUserNotificationCenter.current().add(request) { _ in }
    }
}
