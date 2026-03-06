//
//  ContentView.swift
//  SparkClean
//
//  Created by George Khananaev on 3/6/26.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Main Content View

struct ContentView: View {
    @State private var manager = CleanupManager()
    @State private var showCleanAlert = false
    @State private var selectedSidebar: SidebarItem = .dashboard
    @State private var showExportSheet = false
    @State private var showCleanComplete = false
    @State private var exportVerbose = false
    @State private var exportReport = ""
    @State private var isGeneratingReport = false
    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
    @State private var showWhatsNew = false
    @State private var showHelpSheet = false
    @State private var showPrivacyPolicy = false
    @State private var showCleanErrors = false
    @State private var introPlayed = false
    @AppStorage("showIntroVideo") private var showIntroVideo = true

    private func generateAndShowReport(verbose: Bool) {
        exportVerbose = verbose
        isGeneratingReport = true
        exportReport = ""
        showExportSheet = true
        DispatchQueue.global(qos: .userInitiated).async {
            let report = manager.exportDetailedReport(verbose: verbose)
            DispatchQueue.main.async {
                exportReport = report
                isGeneratingReport = false
            }
        }
    }

    var body: some View {
        HSplitView {
            // Sidebar
            VStack(spacing: 0) {
                sidebarContent
            }
            .frame(minWidth: 220, idealWidth: 240, maxWidth: 300)
            .background(Color(nsColor: .windowBackgroundColor))

            // Detail
            Group {
                switch selectedSidebar {
                case .dashboard:
                    DashboardView(
                        manager: manager,
                        showCleanAlert: $showCleanAlert,
                        selectedSidebar: $selectedSidebar,
                        showExportSheet: $showExportSheet,
                        exportVerbose: $exportVerbose,
                        introPlayed: $introPlayed,
                        showIntroVideo: showIntroVideo,
                        onExport: { verbose in generateAndShowReport(verbose: verbose) }
                    )
                case .group(let group):
                    CategoryGroupDetailView(
                        manager: manager,
                        group: group,
                        showCleanAlert: $showCleanAlert
                    )
                case .uninstaller:
                    UninstallerView()
                case .duplicateFinder:
                    DuplicateFinderView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Clean confirmation with safety breakdown
        .sheet(isPresented: $showCleanAlert) {
            CleanConfirmationSheet(manager: manager, isPresented: $showCleanAlert) {
                Task {
                    await manager.clean()
                    showCleanComplete = true
                }
            }
        }
        // Clean complete
        .alert("Cleanup Complete", isPresented: $showCleanComplete) {
            if !manager.cleanErrors.isEmpty {
                Button("Show Errors") { showCleanErrors = true }
            }
            Button("Open Trash") {
                NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.Trash"))
            }
            Button("OK") {}
        } message: {
            let errorNote = manager.cleanErrors.isEmpty ? "" : "\n\n\(manager.cleanErrors.count) items could not be removed."
            Text("Cleaned \(CleanupManager.formatBytes(manager.lastCleanedSize)) across \(manager.lastCleanedCount) categories (\(manager.cleanSuccessCount) succeeded, \(manager.cleanFailCount) had errors).\(errorNote)")
        }
        // Clean errors detail
        .alert("Clean Errors", isPresented: $showCleanErrors) {
            Button("OK") {}
        } message: {
            Text(manager.cleanErrors.prefix(10).joined(separator: "\n") + (manager.cleanErrors.count > 10 ? "\n...and \(manager.cleanErrors.count - 10) more" : ""))
        }
        .sheet(isPresented: $showExportSheet) {
            ExportReportView(report: $exportReport, isGenerating: $isGeneratingReport)
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView {
                UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                showOnboarding = false
            }
        }
        .sheet(isPresented: $showWhatsNew) {
            WhatsNewView()
        }
        .sheet(isPresented: $showHelpSheet) {
            HelpView()
        }
        .sheet(isPresented: $showPrivacyPolicy) {
            PrivacyPolicyView()
        }
        .frame(minWidth: 800, minHeight: 550)
        .onAppear {
            manager.fetchDiskUsage()
            checkWhatsNew()
        }
        .onReceive(NotificationCenter.default.publisher(for: .startScan)) { _ in
            if !manager.isScanning {
                Task { await manager.scan() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectAll)) { _ in
            manager.selectAll()
        }
        .onReceive(NotificationCenter.default.publisher(for: .deselectAll)) { _ in
            manager.deselectAll()
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectSafeOnly)) { _ in
            manager.selectSafeOnly()
        }
        .onReceive(NotificationCenter.default.publisher(for: .exportReport)) { _ in
            if manager.scanComplete {
                generateAndShowReport(verbose: false)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showHelp)) { _ in
            showHelpSheet = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showPrivacyPolicy)) { _ in
            showPrivacyPolicy = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showWhatsNew)) { _ in
            showWhatsNew = true
        }
    }

    private func checkWhatsNew() {
        let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        let lastSeen = UserDefaults.standard.string(forKey: "lastSeenVersion") ?? ""
        if lastSeen != currentVersion && !showOnboarding {
            showWhatsNew = true
            UserDefaults.standard.set(currentVersion, forKey: "lastSeenVersion")
        }
    }

    // MARK: Sidebar Content

    @ViewBuilder
    private var sidebarContent: some View {
        TextField("Filter...", text: $manager.searchQuery)
            .textFieldStyle(.roundedBorder)
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 6)

        List {
            Section {
                SidebarRow(
                    label: "Dashboard",
                    icon: "gauge.with.dots.needle.33percent",
                    iconColor: .accentColor,
                    isSelected: selectedSidebar == .dashboard
                ) {
                    selectedSidebar = .dashboard
                }
            }

            Section("Categories") {
                ForEach(CategoryGroup.allCases) { group in
                    let cats = manager.categoriesForGroup(group)
                    let hasResults = !cats.isEmpty
                    let selectedCats = cats.filter(\.isSelected)
                    let selectedSize = selectedCats.reduce(0) { $0 + $1.selectedSize }
                    let sizeText = hasResults ? CleanupManager.formatBytes(selectedSize) : "—"
                    SidebarRow(
                        label: group.rawValue,
                        icon: group.icon,
                        iconColor: hasResults ? group.color : .gray,
                        trailing: sizeText,
                        badgeCount: hasResults ? selectedCats.count : nil,
                        isSelected: selectedSidebar == .group(group)
                    ) {
                        selectedSidebar = .group(group)
                    }
                    .opacity(hasResults ? 1.0 : 0.5)
                }
            }

            Section("Tools") {
                SidebarRow(
                    label: "Uninstaller",
                    icon: "trash.square",
                    iconColor: .red,
                    isSelected: selectedSidebar == .uninstaller
                ) {
                    selectedSidebar = .uninstaller
                }

                SidebarRow(
                    label: "Duplicate Finder",
                    icon: "doc.on.doc",
                    iconColor: .teal,
                    isSelected: selectedSidebar == .duplicateFinder
                ) {
                    selectedSidebar = .duplicateFinder
                }
            }
        }
        .listStyle(.sidebar)

        // Scan progress
        if manager.isScanning {
            VStack(spacing: 6) {
                ProgressView(value: manager.scanProgress)
                    .progressViewStyle(.linear)
                Text(manager.currentScanItem)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }

        // Clean progress
        if manager.isCleaning {
            VStack(spacing: 6) {
                ProgressView(value: manager.cleanProgress)
                    .progressViewStyle(.linear)
                    .tint(.red)
                Text("Cleaning...")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }

        // Partial scan banner
        if let summary = manager.lastScanSummary, summary.wasPartial {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                Text("Partial scan")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }

        // FDA banner
        if !manager.hasFullDiskAccess && manager.scanComplete {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    Text("Limited Access")
                        .font(.caption2.bold())
                        .foregroundStyle(.orange)
                }
                Text("Some scans need Full Disk Access to find all files.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button("Grant Access") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .font(.caption2)
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.orange.opacity(0.08))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.2), lineWidth: 1))
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }
}

// MARK: - Dashboard View

struct DashboardView: View {
    let manager: CleanupManager
    @Binding var showCleanAlert: Bool
    @Binding var selectedSidebar: SidebarItem
    @Binding var showExportSheet: Bool
    @Binding var exportVerbose: Bool
    @Binding var introPlayed: Bool
    var showIntroVideo: Bool
    var onExport: (Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header bar (same pattern as Uninstaller / Duplicate Finder)
            headerSection

            Divider()

            // Content
            if manager.scanComplete {
                ScrollView {
                    VStack(spacing: 20) {
                        if let disk = manager.diskUsage {
                            DiskUsageCardView(disk: disk, reclaimable: manager.overallSize)
                        }

                        if manager.categories.contains(where: { $0.safetyLevel == .safe && $0.isSelected }) {
                            smartRecommendation
                        }

                        summaryStatsGrid
                        topCategoriesSection
                        groupOverviewSection
                    }
                    .padding(20)
                }
                .background(Color(nsColor: .controlBackgroundColor))
            } else if manager.isScanning {
                scanningSection
            } else {
                welcomeSection
            }
        }
    }

    // MARK: Header

    private var headerSection: some View {
        HStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(
                    LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("SparkClean")
                    .font(.title3)
                    .fontWeight(.bold)
                if manager.scanComplete {
                    Text("\(manager.categories.count) categories · \(CleanupManager.formatBytes(manager.overallSize)) reclaimable")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Mac cleanup & storage optimizer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if manager.isScanning {
                Button("Cancel") { manager.cancelScan() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.red)
            }

            if manager.scanComplete {
                Button {
                    showCleanAlert = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "trash")
                            .font(.system(size: 12, weight: .semibold))
                        Text(manager.isCleaning ? "Cleaning..." : "Clean")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(manager.isScanning || manager.isCleaning || manager.totalSize == 0)
            }

            Button {
                Task { await manager.scan() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: manager.isScanning ? "arrow.triangle.2.circlepath" : "magnifyingglass")
                        .font(.system(size: 12, weight: .semibold))
                    Text(manager.isScanning ? "Scanning..." : (manager.scanComplete ? "Rescan" : "Scan"))
                        .font(.system(size: 13, weight: .semibold))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
            }
            .buttonStyle(.borderedProminent)
            .disabled(manager.isScanning || manager.isCleaning)

            if manager.scanComplete {
                Menu {
                    Button("Select Safe Only") { manager.selectSafeOnly() }
                    Button("Select All") { manager.selectAll() }
                    Button("Deselect All") { manager.deselectAll() }
                    Divider()
                    Button("Export Summary Report...") { onExport(false) }
                    Button("Export Detailed Audit Report...") { onExport(true) }
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

    private var sizeGradient: LinearGradient {
        if manager.overallSize > 5_000_000_000 {
            return LinearGradient(colors: [.red, .orange], startPoint: .leading, endPoint: .trailing)
        } else if manager.overallSize > 1_000_000_000 {
            return LinearGradient(colors: [.orange, .yellow], startPoint: .leading, endPoint: .trailing)
        }
        return LinearGradient(colors: [.green, .teal], startPoint: .leading, endPoint: .trailing)
    }

    // MARK: Smart Recommendation

    private var smartRecommendation: some View {
        let safeCats = manager.categories.filter { $0.safetyLevel == .safe && $0.isSelected }
        let safeSize = safeCats.reduce(0 as Int64) { $0 + $1.size }
        return HStack(spacing: 12) {
            Image(systemName: "lightbulb.fill")
                .foregroundStyle(.yellow)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text("Quick Clean Available")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(safeCats.count) safe categories can free \(CleanupManager.formatBytes(safeSize)) with no risk.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Select Safe Only") {
                manager.selectSafeOnly()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.yellow.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.yellow.opacity(0.2), lineWidth: 1)
                )
        )
    }

    // MARK: Summary Stats

    private var summaryStatsGrid: some View {
        HStack(spacing: 14) {
            StatCard(title: "Categories", value: "\(manager.categories.count)", icon: "folder", color: .blue)
            StatCard(title: "Selected", value: CleanupManager.formatBytes(manager.totalSize), icon: "checkmark.circle", color: .green)
            StatCard(title: "Files", value: formatNumber(manager.categories.reduce(0) { $0 + $1.fileCount }), icon: "doc", color: .orange)
            if let summary = manager.lastScanSummary {
                StatCard(
                    title: summary.wasPartial ? "Partial Scan" : "Scan Time",
                    value: String(format: "%.1fs", summary.scanDuration),
                    icon: summary.wasPartial ? "exclamationmark.clock" : "clock",
                    color: summary.wasPartial ? .orange : .purple
                )
            }
        }
    }

    // MARK: Top Categories

    private var topCategoriesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Largest Categories")
                .font(.headline)

            let topCats = manager.categories.sorted { $0.size > $1.size }.prefix(5)
            ForEach(Array(topCats)) { category in
                TopCategoryRow(category: category, maxSize: topCats.first?.size ?? 1)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
    }

    // MARK: Group Overview

    private var groupOverviewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("By Category")
                .font(.headline)

            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible()),
            ], spacing: 12) {
                ForEach(CategoryGroup.allCases) { group in
                    let cats = manager.categoriesForGroup(group)
                    GroupCard(group: group, categories: cats) {
                        selectedSidebar = .group(group)
                    }
                }
            }
        }
    }

    // MARK: Scanning

    private var scanningSection: some View {
        VStack(spacing: 20) {
            Spacer()

            ProgressView(value: manager.scanProgress) {
                Text("Scanning your Mac...")
                    .font(.headline)
            } currentValueLabel: {
                Text(manager.currentScanItem)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .progressViewStyle(.linear)
            .frame(maxWidth: 400)

            Text("\(Int(manager.scanProgress * 100))%")
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)

            if !manager.categories.isEmpty {
                Text("Found \(manager.categories.count) categories (\(CleanupManager.formatBytes(manager.overallSize)) so far)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Welcome

    private var welcomeSection: some View {
        Group {
            if introPlayed || !showIntroVideo {
                readyToScanSection
            } else {
                SplashScreenView {
                    withAnimation(.easeOut(duration: 0.4)) {
                        introPlayed = true
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var readyToScanSection: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [.blue.opacity(0.15), .clear],
                            center: .center,
                            startRadius: 30,
                            endRadius: 120
                        )
                    )
                    .frame(width: 220, height: 220)

                Image(systemName: "magnifyingglass.circle.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.blue, .purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }

            VStack(spacing: 10) {
                Text("Ready to Scan")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("Click **Scan** to deep-scan your Mac for caches, temp files,\norphaned app data, Docker resources, unused apps, and more.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if let disk = manager.diskUsage {
                HStack(spacing: 20) {
                    DiskMiniStat(label: "Total", value: CleanupManager.formatBytes(disk.totalSpace))
                    DiskMiniStat(label: "Used", value: CleanupManager.formatBytes(disk.usedSpace))
                    DiskMiniStat(label: "Free", value: CleanupManager.formatBytes(disk.freeSpace))
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.ultraThinMaterial)
                )
            }

            Spacer()
        }
    }

    private func formatNumber(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}

// MARK: - Clean Confirmation Sheet

struct CleanConfirmationSheet: View {
    let manager: CleanupManager
    @Binding var isPresented: Bool
    let onConfirm: () -> Void

    private var selectedCategories: [CleanupCategory] {
        manager.categories.filter { $0.isSelected && $0.size > 0 }
    }

    private var safeCount: Int { selectedCategories.filter { $0.safetyLevel == .safe }.count }
    private var reviewCount: Int { selectedCategories.filter { $0.safetyLevel == .review }.count }
    private var cautionCount: Int { selectedCategories.filter { $0.safetyLevel == .caution }.count }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.orange)

                Text("Confirm Cleanup")
                    .font(.title2)
                    .fontWeight(.bold)
            }
            .padding(.top, 24)
            .padding(.bottom, 16)

            Divider()

            // Summary
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Overview
                    HStack(spacing: 20) {
                        summaryCard("Total Size", value: CleanupManager.formatBytes(manager.totalSize), color: .blue)
                        summaryCard("Categories", value: "\(selectedCategories.count)", color: .purple)
                        summaryCard("Items", value: "\(manager.totalFiles)", color: .orange)
                    }
                    .padding(.top, 12)

                    // Safety breakdown
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Safety Breakdown")
                            .font(.headline)

                        if safeCount > 0 {
                            safetyRow(level: .safe, count: safeCount)
                        }
                        if reviewCount > 0 {
                            safetyRow(level: .review, count: reviewCount)
                        }
                        if cautionCount > 0 {
                            safetyRow(level: .caution, count: cautionCount)
                        }
                    }

                    // Category list
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Selected for Removal")
                            .font(.headline)

                        ForEach(selectedCategories) { cat in
                            HStack(spacing: 10) {
                                Image(systemName: cat.safetyLevel.icon)
                                    .font(.caption)
                                    .foregroundStyle(cat.safetyLevel.color)
                                    .frame(width: 16)

                                Image(systemName: cat.icon)
                                    .font(.caption)
                                    .foregroundStyle(cat.color)
                                    .frame(width: 16)

                                Text(cat.name)
                                    .font(.callout)

                                Spacer()

                                Text("\(cat.fileCount) items")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Text(CleanupManager.formatBytes(cat.selectedSize))
                                    .font(.callout)
                                    .fontWeight(.medium)
                                    .monospacedDigit()
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(cat.safetyLevel == .caution ? Color.red.opacity(0.06) : Color.primary.opacity(0.03))
                            )
                        }
                    }

                    // Recovery note
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "trash")
                            .font(.title3)
                            .foregroundStyle(.blue)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Recovery")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                            Text("Files will be moved to Trash when possible. You can restore them from Trash before emptying it. Some items (Docker resources, Ollama models) are removed permanently through their respective CLI tools.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.06)))

                    // Disclaimer
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "shield.lefthalf.filled")
                            .font(.title3)
                            .foregroundStyle(.orange)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Disclaimer")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                            Text("By proceeding, you acknowledge that SparkClean is provided \"as is\" without warranty of any kind. The developer assumes no liability for any data loss, system instability, or damages resulting from the use of this application. You are solely responsible for reviewing the items selected for removal and ensuring they are not required by your system or applications. It is strongly recommended to maintain up-to-date backups before performing any cleanup operations.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.06)))
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }
            .frame(maxHeight: 380)

            Divider()

            // Buttons
            HStack(spacing: 12) {
                Button("Cancel") {
                    isPresented = false
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.bordered)
                .controlSize(.large)

                Spacer()

                Button {
                    isPresented = false
                    onConfirm()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "trash")
                        Text("Move to Trash — \(CleanupManager.formatBytes(manager.totalSize))")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
            }
            .padding(20)
        }
        .frame(width: 560)
    }

    private func summaryCard(_ title: String, value: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title3)
                .fontWeight(.bold)
                .foregroundStyle(color)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.08)))
    }

    private func safetyRow(level: SafetyLevel, count: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: level.icon)
                .foregroundStyle(level.color)
                .frame(width: 18)
            Text(level.label)
                .font(.callout)
            Spacer()
            Text("\(count) \(count == 1 ? "category" : "categories")")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 10)
    }
}

// MARK: - Onboarding View

struct OnboardingView: View {
    let onComplete: () -> Void
    @State private var currentStep = 0

    var body: some View {
        VStack(spacing: 0) {
            if currentStep == 0 {
                welcomeStep
            } else {
                permissionsStep
            }
        }
        .frame(width: 520, height: 620)
    }

    // MARK: Step 1 - Welcome

    private var welcomeStep: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "sparkles")
                .font(.system(size: 48))
                .foregroundStyle(
                    LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                )

            Text("Welcome to SparkClean")
                .font(.title)
                .fontWeight(.bold)

            VStack(alignment: .leading, spacing: 14) {
                featureRow(icon: "magnifyingglass", color: .blue,
                    title: "Deep Scan",
                    desc: "Finds caches, temp files, build artifacts, browser data, and more.")

                featureRow(icon: "checkmark.shield.fill", color: .green,
                    title: "Safety Levels",
                    desc: "Every item is labeled Safe, Review, or Caution so you know what's risk-free.")

                featureRow(icon: "trash", color: .orange,
                    title: "Trash First",
                    desc: "Files are moved to Trash by default — you can always recover them.")

                featureRow(icon: "app.badge.checkmark", color: .purple,
                    title: "App Uninstaller",
                    desc: "Completely remove apps and all their hidden data with one click.")

                featureRow(icon: "doc.on.doc", color: .teal,
                    title: "Duplicate Finder",
                    desc: "Find and remove duplicate files wasting disk space.")
            }
            .padding(.horizontal, 20)

            Spacer()

            Button {
                withAnimation { currentStep = 1 }
            } label: {
                HStack(spacing: 6) {
                    Text("Next: Set Up Permissions")
                    Image(systemName: "arrow.right")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Spacer().frame(height: 16)
        }
        .padding(32)
    }

    // MARK: Step 2 - Permissions

    private var permissionsStep: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "lock.shield.fill")
                .font(.system(size: 44))
                .foregroundStyle(
                    LinearGradient(colors: [.orange, .red], startPoint: .topLeading, endPoint: .bottomTrailing)
                )

            Text("Grant Permissions")
                .font(.title2)
                .fontWeight(.bold)

            Text("SparkClean needs access to scan and clean your Mac.\nGrant these permissions for the best experience.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 12) {
                permissionCard(
                    icon: "lock.open.fill",
                    color: .orange,
                    title: "Full Disk Access",
                    desc: "Required to scan Mail, Messages, system caches, and all directories.",
                    importance: "Required",
                    urlString: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
                )

                permissionCard(
                    icon: "folder.fill",
                    color: .blue,
                    title: "Files & Folders",
                    desc: "Access Downloads, Documents, Desktop, and removable volumes.",
                    importance: "Recommended",
                    urlString: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders"
                )

                permissionCard(
                    icon: "gearshape.fill",
                    color: .gray,
                    title: "Automation",
                    desc: "Allows Docker cleanup commands and Finder integration.",
                    importance: "Optional",
                    urlString: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
                )
            }
            .padding(.horizontal, 16)

            Text("You can always change these later in System Settings > Privacy & Security.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            Spacer()

            HStack(spacing: 12) {
                Button("Back") {
                    withAnimation { currentStep = 0 }
                }
                .buttonStyle(.bordered)

                Button("Get Started") {
                    onComplete()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            Spacer().frame(height: 12)
        }
        .padding(28)
    }

    private func permissionCard(icon: String, color: Color, title: String, desc: String, importance: String, urlString: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(importance)
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(importance == "Required" ? Color.red.opacity(0.15) : (importance == "Recommended" ? Color.blue.opacity(0.15) : Color.gray.opacity(0.15)))
                        )
                        .foregroundStyle(importance == "Required" ? .red : (importance == "Recommended" ? .blue : .gray))
                }
                Text(desc)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Button("Open") {
                if let url = URL(string: urlString) {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(color.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.15), lineWidth: 1))
        )
    }

    private func featureRow(icon: String, color: Color, title: String, desc: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(desc).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - What's New View

struct WhatsNewView: View {
    @Environment(\.dismiss) private var dismiss

    private let releases: [ReleaseNote] = [
        ReleaseNote(version: "1.0.0", date: "March 2026", notes: [
            "Deep scan for caches, temp files, logs, and crash reports",
            "Browser cache cleanup (Safari, Chrome, Firefox, Arc, Edge, Brave)",
            "Developer tools cleanup (Xcode, Android, Gradle)",
            "Package manager cache cleanup (npm, pip, Homebrew, CocoaPods, and more)",
            "Docker resource scanning and cleanup",
            "App Uninstaller with related data detection",
            "Safety levels (Safe, Review, Caution) for every category",
            "Detailed export reports",
            "Configurable scan thresholds",
        ]),
    ]

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text("What's New")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(releases) { release in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("v\(release.version)")
                                    .font(.headline)
                                Text(release.date)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(release.notes, id: \.self) { note in
                                HStack(alignment: .top, spacing: 8) {
                                    Text("•")
                                        .foregroundStyle(.secondary)
                                    Text(note)
                                        .font(.body)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 480, height: 420)
    }
}

// MARK: - Help View

struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text("SparkClean Help")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    helpSection("Getting Started",
                        "Click **Scan** to analyze your Mac. SparkClean will find caches, temporary files, build artifacts, and other reclaimable space.")

                    helpSection("Safety Levels",
                        "**Safe** (green): Caches and temp files that rebuild automatically. No risk.\n**Review** (orange): User files like old downloads. Check before deleting.\n**Caution** (red): App data or Docker resources. Could affect running apps.")

                    helpSection("Cleaning",
                        "Select categories you want to clean, then click **Clean**. Files are moved to Trash by default so you can recover them if needed.")

                    helpSection("App Uninstaller",
                        "The Uninstaller finds all installed apps and their hidden data (caches, preferences, containers). Remove everything with one click.")

                    helpSection("Keyboard Shortcuts",
                        "**Cmd+R** — Scan\n**Cmd+E** — Export Report\n**Cmd+Shift+A** — Select All\n**Cmd+Shift+D** — Deselect All\n**Cmd+Shift+S** — Select Safe Only")

                    helpSection("Contact",
                        "Email: george@khananaev.com")
                }
            }
        }
        .padding(24)
        .frame(width: 500, height: 480)
    }

    private func helpSection(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            Text(.init(body))
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Privacy Policy View

struct PrivacyPolicyView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text("Privacy Policy")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Last updated: March 2026")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    policySection("Data Collection",
                        "SparkClean does NOT collect, transmit, or store any personal data. All scanning and cleanup operations happen entirely on your device.")

                    policySection("Network Access",
                        "SparkClean makes NO network requests. The app works completely offline. No analytics, no telemetry, no tracking.")

                    policySection("File Access",
                        "SparkClean reads file metadata (sizes, dates) to identify reclaimable space. It only deletes files you explicitly select and confirm. Files are moved to Trash by default.")

                    policySection("Third-Party Services",
                        "SparkClean does not integrate with any third-party services, advertising networks, or analytics platforms.")

                    policySection("Contact",
                        "For questions about this privacy policy, contact george@khananaev.com")
                }
            }
        }
        .padding(24)
        .frame(width: 500, height: 440)
    }

    private func policySection(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            Text(body)
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    ContentView()
        .frame(width: 900, height: 650)
}
