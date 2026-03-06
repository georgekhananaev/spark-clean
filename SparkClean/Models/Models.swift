//
//  Models.swift
//  SparkClean
//
//  Created by George Khananaev on 3/6/26.
//

import Foundation
import SwiftUI

// MARK: - Category Group

enum CategoryGroup: String, CaseIterable, Identifiable, Codable {
    case system = "System"
    case storage = "Storage"
    case browsers = "Browsers"
    case developer = "Developer Tools"
    case packageManagers = "Package Managers"
    case largeFiles = "Large Files"
    case docker = "Docker"
    case applications = "Applications"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .system: "gearshape.2"
        case .storage: "externaldrive"
        case .browsers: "globe"
        case .developer: "hammer"
        case .packageManagers: "shippingbox"
        case .largeFiles: "doc.fill"
        case .docker: "cube.box"
        case .applications: "app.badge.checkmark"
        }
    }

    var color: Color {
        switch self {
        case .system: .blue
        case .storage: .teal
        case .browsers: .orange
        case .developer: .pink
        case .packageManagers: .green
        case .largeFiles: .orange
        case .docker: .cyan
        case .applications: .purple
        }
    }
}

// MARK: - Safety Level

enum SafetyLevel: String, Codable {
    case safe = "Safe"
    case review = "Review"
    case caution = "Caution"

    var color: Color {
        switch self {
        case .safe: .green
        case .review: .orange
        case .caution: .red
        }
    }

    var icon: String {
        switch self {
        case .safe: "checkmark.shield.fill"
        case .review: "eye.fill"
        case .caution: "exclamationmark.triangle.fill"
        }
    }

    var label: String {
        switch self {
        case .safe: "Safe to delete"
        case .review: "Review before deleting"
        case .caution: "Use caution"
        }
    }
}

// MARK: - Constants

enum ScanConstants {
    static let minCacheSizeBytes: Int64 = 100_000       // 100KB
    static let minSystemCacheSizeBytes: Int64 = 500_000 // 500KB
    static let minNodeModulesSizeBytes: Int64 = 1_000_000 // 1MB
    static let minCacheTotalBytes: Int64 = 500_000      // 500KB
    static let minSystemCacheTotalBytes: Int64 = 1_000_000 // 1MB
    static let installerFileAgeDays = 14
    static let secondsPerDay: Double = 86400
    static let maxBreakdownEntries = 60
    static let maxNodeModulesEntries = 50
    static let minVenvSizeBytes: Int64 = 50_000_000  // 50MB
    static let maxVenvEntries = 50
    static let minDuplicateSizeBytes: Int64 = 1_000_000  // 1MB
    static let maxDuplicateFileSize: Int64 = 2_147_483_648  // 2GB
}

// MARK: - Data Models

struct PathStat: Identifiable {
    var id: String { path }
    let path: String
    let size: Int64
    let fileCount: Int
    var children: [PathStat] = []
    var lastAccessed: Date? = nil
    var isSelected: Bool = true
}

struct CleanupCategory: Identifiable, Equatable {
    static func == (lhs: CleanupCategory, rhs: CleanupCategory) -> Bool {
        lhs.id == rhs.id
    }

    let id = UUID()
    let name: String
    let icon: String
    let color: Color
    var description: String
    let group: CategoryGroup
    let safetyLevel: SafetyLevel
    var paths: [String]
    var breakdown: [PathStat] = []
    var deleteChildrenOnly: Bool = true
    var isDockerResource: Bool = false
    var dockerCleanCommand: [String]? = nil
    var isOllamaResource: Bool = false
    var size: Int64 = 0
    var fileCount: Int = 0
    var isSelected: Bool = true
    var selectedSize: Int64 {
        breakdown.isEmpty ? size : breakdown.filter(\.isSelected).reduce(0) { $0 + $1.size }
    }
    var selectedFileCount: Int {
        breakdown.isEmpty ? fileCount : breakdown.filter(\.isSelected).reduce(0) { $0 + $1.fileCount }
    }
    var selectedPaths: [String] {
        breakdown.isEmpty ? paths : breakdown.filter(\.isSelected).map(\.path)
    }
    var hasPerFileSelection: Bool {
        !breakdown.isEmpty && (safetyLevel == .review || safetyLevel == .caution)
    }
    var exists: Bool = true
}

struct ScanDefinition {
    let name: String
    let icon: String
    let color: Color
    let description: String
    let group: CategoryGroup
    let safetyLevel: SafetyLevel
    let pathResolver: () -> [String]
    let defaultSelected: Bool

    init(
        name: String, icon: String, color: Color,
        description: String, group: CategoryGroup,
        safetyLevel: SafetyLevel = .safe,
        defaultSelected: Bool = true,
        pathResolver: @escaping () -> [String]
    ) {
        self.name = name; self.icon = icon; self.color = color
        self.description = description; self.group = group
        self.safetyLevel = safetyLevel
        self.defaultSelected = defaultSelected
        self.pathResolver = pathResolver
    }
}

struct DiskUsageInfo {
    let totalSpace: Int64
    let usedSpace: Int64
    let freeSpace: Int64
    let purgeableSpace: Int64

    var usedPercentage: Double {
        guard totalSpace > 0 else { return 0 }
        return Double(usedSpace) / Double(totalSpace)
    }
}

struct ScanSummary {
    let totalCategories: Int
    let totalSize: Int64
    let totalFiles: Int
    let scanDuration: TimeInterval
    let timestamp: Date
    var wasPartial: Bool = false
}

// MARK: - Sidebar Selection

enum SidebarItem: Hashable {
    case dashboard
    case group(CategoryGroup)
    case uninstaller
    case duplicateFinder
}

// MARK: - App Info (Uninstaller)

struct AppInfo: Identifiable, Equatable {
    static func == (lhs: AppInfo, rhs: AppInfo) -> Bool {
        lhs.id == rhs.id
    }

    let id = UUID()
    let name: String
    let bundleID: String
    let path: String
    let icon: NSImage?
    var appSize: Int64 = 0
    var relatedPaths: [RelatedPath] = []
    var totalRelatedSize: Int64 = 0

    var totalSize: Int64 {
        appSize + totalRelatedSize
    }
}

struct RelatedPath: Identifiable {
    let id = UUID()
    let path: String
    let category: String
    let size: Int64
    let fileCount: Int
}

enum AppSortOrder: String, CaseIterable {
    case name = "Name"
    case totalSize = "Total Size"
    case appSize = "App Size"
    case relatedSize = "Related Data"
}

// MARK: - Release Notes

struct ReleaseNote: Identifiable {
    let id = UUID()
    let version: String
    let date: String
    let notes: [String]
}

// MARK: - Known App Data Paths

struct KnownAppDataEntry {
    let path: String
    let description: String
    let safetyNote: String
}

enum KnownAppData {
    static let paths: [String: [KnownAppDataEntry]] = [
        // AI/ML Apps
        "com.ollama.ollama": [
            KnownAppDataEntry(path: "~/.ollama", description: "AI Models & Configuration", safetyNote: "Models must be re-downloaded after deletion")
        ],
        "com.lmstudio.app": [
            KnownAppDataEntry(path: "~/.lmstudio", description: "AI Models & Configuration", safetyNote: "Models must be re-downloaded")
        ],
        "com.nomic.gpt4all": [
            KnownAppDataEntry(path: "~/Library/Application Support/nomic.ai", description: "AI Models", safetyNote: "")
        ],
        "com.diffusionbee.diffusionbee": [
            KnownAppDataEntry(path: "~/.diffusionbee", description: "Stable Diffusion Models", safetyNote: "")
        ],
        // Virtualization
        "com.docker.docker": [
            KnownAppDataEntry(path: "~/.docker", description: "Docker CLI Configuration", safetyNote: ""),
            KnownAppDataEntry(path: "~/Library/Containers/com.docker.docker/Data/vms", description: "Docker VM Disk Image", safetyNote: "Contains all containers and images")
        ],
        "io.podman.desktop": [
            KnownAppDataEntry(path: "~/.local/share/containers/podman", description: "Podman VM & Containers", safetyNote: "")
        ],
        "com.utmapp.UTM": [
            KnownAppDataEntry(path: "~/Library/Containers/com.utmapp.UTM/Data/Documents", description: "Virtual Machines", safetyNote: "VMs will be permanently deleted")
        ],
        "com.parallels.desktop.console": [
            KnownAppDataEntry(path: "~/Parallels", description: "Virtual Machines", safetyNote: "VMs will be permanently deleted")
        ],
        // Development
        "com.google.android.studio": [
            KnownAppDataEntry(path: "~/.android/avd", description: "Android Virtual Devices", safetyNote: ""),
            KnownAppDataEntry(path: "~/Library/Android/sdk", description: "Android SDK", safetyNote: "Must re-download if needed")
        ],
        // Databases
        "com.postgresapp.Postgres2": [
            KnownAppDataEntry(path: "/opt/homebrew/var/postgres", description: "PostgreSQL Data", safetyNote: "WARNING: Contains all databases"),
            KnownAppDataEntry(path: "/usr/local/var/postgres", description: "PostgreSQL Data (Intel)", safetyNote: "WARNING: Contains all databases")
        ],
        // Media
        "com.adobe.PremierePro": [
            KnownAppDataEntry(path: "~/Library/Application Support/Adobe/Common/Media Cache Files", description: "Adobe Media Cache", safetyNote: "Shared across Adobe apps")
        ],
        // Communication
        "ru.keepcoder.Telegram": [
            KnownAppDataEntry(path: "~/Library/Group Containers/6N38VVP8K2.telegram", description: "Telegram Data & Media", safetyNote: "")
        ],
        "com.tinyspeck.slackmacgap": [
            KnownAppDataEntry(path: "~/Library/Application Support/Slack/Cache", description: "Slack Media Cache", safetyNote: ""),
            KnownAppDataEntry(path: "~/Library/Application Support/Slack/Service Worker", description: "Slack Service Workers", safetyNote: "")
        ],
        // Gaming
        "com.valvesoftware.steam": [
            KnownAppDataEntry(path: "~/Library/Application Support/Steam/steamapps", description: "Steam Games Library", safetyNote: "All installed games will be deleted")
        ],
        "com.epicgames.EpicGamesLauncher": [
            KnownAppDataEntry(path: "/Users/Shared/Epic Games", description: "Epic Games Library", safetyNote: "All installed games will be deleted")
        ],
        // Cloud Storage
        "com.google.drivefs": [
            KnownAppDataEntry(path: "~/Library/Application Support/Google/DriveFS", description: "Google Drive Cache", safetyNote: "Local cache only — cloud files safe")
        ],
        // Browsers
        "com.google.Chrome": [
            KnownAppDataEntry(path: "~/Library/Application Support/Google/Chrome", description: "Chrome Profiles & Extensions", safetyNote: "All bookmarks, history, extensions")
        ],
        "org.mozilla.firefox": [
            KnownAppDataEntry(path: "~/Library/Application Support/Firefox/Profiles", description: "Firefox Profiles", safetyNote: "All bookmarks, history, extensions")
        ],
    ]
}
