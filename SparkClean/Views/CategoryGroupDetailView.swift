//
//  CategoryGroupDetailView.swift
//  SparkClean
//
//  Created by George Khananaev on 3/6/26.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct CategoryGroupDetailView: View {
    @Bindable var manager: CleanupManager
    let group: CategoryGroup
    @Binding var showCleanAlert: Bool

    private var groupCategories: [CleanupCategory] {
        manager.categoriesForGroup(group)
    }

    private var groupSize: Int64 {
        groupCategories.reduce(0) { $0 + $1.size }
    }

    private var selectedSize: Int64 {
        groupCategories.filter(\.isSelected).reduce(0) { $0 + $1.size }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: group.icon)
                    .font(.title2)
                    .foregroundStyle(group.color)

                VStack(alignment: .leading, spacing: 2) {
                    Text(group.rawValue)
                        .font(.title3)
                        .fontWeight(.bold)
                    Text("\(groupCategories.count) categories · \(CleanupManager.formatBytes(groupSize)) total")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 8) {
                    Button("Select All") { manager.selectAll(in: group) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                    Button("Deselect All") { manager.deselectAll(in: group) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)

            Divider()

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(groupCategories) { category in
                        CategoryRowView(
                            categoryID: category.id,
                            isSelected: Binding(
                                get: { manager.categories.first(where: { $0.id == category.id })?.isSelected ?? false },
                                set: { newValue in
                                    if let idx = manager.categories.firstIndex(where: { $0.id == category.id }) {
                                        manager.categories[idx].isSelected = newValue
                                    }
                                }
                            ),
                            manager: manager
                        )
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Selected: \(CleanupManager.formatBytes(selectedSize))")
                        .font(.system(size: 12, weight: .medium))
                    Text("\(groupCategories.filter(\.isSelected).count) of \(groupCategories.count) categories")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    showCleanAlert = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "trash")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Clean Selected")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(manager.isScanning || manager.isCleaning || selectedSize == 0)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
    }
}

// MARK: - Category Row

struct CategoryRowView: View {
    let categoryID: UUID
    @Binding var isSelected: Bool
    @Bindable var manager: CleanupManager
    @State private var isHovered = false
    @State private var showDetails = false

    private var category: CleanupCategory {
        manager.categories.first(where: { $0.id == categoryID }) ?? CleanupCategory(
            name: "", icon: "questionmark", color: .gray, description: "",
            group: .system, safetyLevel: .safe, paths: []
        )
    }

    private var isPartiallySelected: Bool {
        guard !category.breakdown.isEmpty else { return false }
        let selectedCount = category.breakdown.filter(\.isSelected).count
        return selectedCount > 0 && selectedCount < category.breakdown.count
    }

    var body: some View {
        HStack(spacing: 14) {
            Button {
                isSelected.toggle()
            } label: {
                Image(systemName: isPartiallySelected ? "minus.square.fill" : (isSelected ? "checkmark.square.fill" : "square"))
                    .font(.system(size: 16))
                    .foregroundStyle(isSelected || isPartiallySelected ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)

            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(category.color.gradient.opacity(0.15))
                    .frame(width: 38, height: 38)

                Image(systemName: category.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(category.color)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(category.name)
                    .font(.system(size: 13, weight: .medium))

                Text("\(category.description) · \(category.selectedFileCount) files")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            HStack(spacing: 3) {
                Image(systemName: category.safetyLevel.icon)
                    .font(.system(size: 9))
                Text(category.safetyLevel.rawValue)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(category.safetyLevel.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(category.safetyLevel.color.opacity(0.12))
            )
            .help(safetyTooltip(category.safetyLevel))
            .accessibilityLabel("Safety level: \(category.safetyLevel.rawValue)")

            if category.isDockerResource {
                Image(systemName: "cube.box")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Docker resource — cleaned via Docker CLI instead of direct file deletion")
                    .accessibilityLabel("Docker resource")
            }

            Button {
                showDetails = true
            } label: {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Show detailed breakdown of files in this category")
            .accessibilityLabel("Show details for \(category.name)")
            .popover(isPresented: $showDetails) {
                PathBreakdownView(categoryID: category.id, manager: manager)
                    .frame(width: 540, height: 380)
            }

            SizeLabel(size: category.selectedSize, color: category.color)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isHovered ? Color.primary.opacity(0.04) : Color.clear)
        )
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.background)
                .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
        )
        .onHover { isHovered = $0 }
        .opacity(isSelected ? 1.0 : 0.55)
        .animation(.easeInOut(duration: 0.15), value: isSelected)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(category.name), \(CleanupManager.formatBytes(category.size)), \(category.safetyLevel.rawValue)")
    }

    private func safetyTooltip(_ level: SafetyLevel) -> String {
        switch level {
        case .safe: "Safe to delete — caches and temp files that rebuild automatically. No risk of data loss."
        case .review: "Review before deleting — user files that may be wanted. Check the contents first."
        case .caution: "Use caution — app data or system files that could affect running applications."
        }
    }
}

// MARK: - Path Breakdown

struct PathBreakdownView: View {
    let categoryID: UUID
    @Bindable var manager: CleanupManager
    @State private var deletingModels: Set<String> = []

    private var category: CleanupCategory {
        manager.categories.first(where: { $0.id == categoryID }) ?? CleanupCategory(
            name: "", icon: "questionmark", color: .gray, description: "",
            group: .system, safetyLevel: .safe, paths: []
        )
    }

    private var hasPerFileSelection: Bool {
        category.hasPerFileSelection
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: category.icon)
                    .foregroundStyle(category.color)
                Text(category.name)
                    .font(.headline)
                Spacer()
                Text("\(category.fileCount) files · \(CleanupManager.formatBytes(category.size))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !category.description.isEmpty {
                Text(category.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if hasPerFileSelection {
                HStack(spacing: 12) {
                    Button("Select All Items") { toggleAllBreakdown(true) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("Deselect All Items") { toggleAllBreakdown(false) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Spacer()
                    Text("Selected: \(CleanupManager.formatBytes(category.selectedSize))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            if category.breakdown.isEmpty {
                VStack {
                    Spacer()
                    Text("No detailed breakdown available")
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(Array(category.breakdown.enumerated()), id: \.element.id) { idx, stat in
                            HStack(alignment: .center, spacing: 12) {
                                if hasPerFileSelection {
                                    Toggle("", isOn: breakdownBinding(for: idx))
                                        .toggleStyle(.checkbox)
                                        .labelsHidden()
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    if category.isOllamaResource || category.isDockerResource {
                                        Text(stat.path)
                                            .font(.system(size: 13, weight: .medium))
                                            .lineLimit(1)
                                    } else {
                                        Text((stat.path as NSString).lastPathComponent)
                                            .font(.system(size: 13, weight: .medium))
                                            .lineLimit(1)
                                        Text((stat.path as NSString).deletingLastPathComponent)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(CleanupManager.formatBytes(stat.size))
                                        .font(.system(size: 12, weight: .semibold))
                                    if stat.fileCount > 0 {
                                        Text("\(stat.fileCount) file\(stat.fileCount == 1 ? "" : "s")")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    if let accessed = stat.lastAccessed {
                                        Text("Last: \(accessed.formatted(date: .abbreviated, time: .omitted))")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }

                                // Show children (duplicate copies)
                                if !stat.children.isEmpty {
                                    Text("\(stat.children.count) copies")
                                        .font(.caption2)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(Color.orange.opacity(0.15)))
                                        .foregroundStyle(.orange)
                                }

                                if category.isOllamaResource {
                                    if deletingModels.contains(stat.path) {
                                        HStack(spacing: 4) {
                                            ProgressView()
                                                .controlSize(.small)
                                            Text("Removing…")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    } else {
                                        Button("Delete") {
                                            deleteOllamaModel(stat.path, at: idx)
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                        .tint(.red)
                                    }
                                } else if !category.isDockerResource {
                                    Button("Reveal") {
                                        let path = stat.path
                                        let revealPath = stat.children.first?.path ?? path
                                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: revealPath)])
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(hasPerFileSelection && !stat.isSelected ? Color.primary.opacity(0.01) : Color.primary.opacity(0.03))
                            )
                            .opacity(hasPerFileSelection && !stat.isSelected ? 0.5 : 1.0)

                            // Show children inline for duplicates
                            if !stat.children.isEmpty {
                                ForEach(stat.children) { child in
                                    HStack(spacing: 8) {
                                        Spacer().frame(width: 28)
                                        Image(systemName: "arrow.turn.down.right")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                        Text(child.path)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                        Spacer()
                                        Text(CleanupManager.formatBytes(child.size))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
    }

    private func breakdownBinding(for index: Int) -> Binding<Bool> {
        Binding(
            get: {
                guard let catIdx = manager.categories.firstIndex(where: { $0.id == category.id }),
                      index < manager.categories[catIdx].breakdown.count else { return true }
                return manager.categories[catIdx].breakdown[index].isSelected
            },
            set: { newValue in
                guard let catIdx = manager.categories.firstIndex(where: { $0.id == category.id }),
                      index < manager.categories[catIdx].breakdown.count else { return }
                manager.categories[catIdx].breakdown[index].isSelected = newValue
            }
        )
    }

    private func toggleAllBreakdown(_ selected: Bool) {
        guard let catIdx = manager.categories.firstIndex(where: { $0.id == category.id }) else { return }
        for i in manager.categories[catIdx].breakdown.indices {
            manager.categories[catIdx].breakdown[i].isSelected = selected
        }
    }

    private func deleteOllamaModel(_ modelName: String, at index: Int) {
        guard let ollamaPath = CleanupManager.findOllama() else { return }
        deletingModels.insert(modelName)
        DispatchQueue.global(qos: .userInitiated).async {
            _ = CleanupManager.runCommand(ollamaPath, arguments: ["rm", modelName])
            DispatchQueue.main.async {
                deletingModels.remove(modelName)
                guard let catIdx = manager.categories.firstIndex(where: { $0.id == categoryID }) else { return }
                if index < manager.categories[catIdx].breakdown.count {
                    let removedSize = manager.categories[catIdx].breakdown[index].size
                    manager.categories[catIdx].breakdown.remove(at: index)
                    manager.categories[catIdx].size -= removedSize
                    manager.categories[catIdx].fileCount -= 1
                }
                // Update description to reflect remaining models
                let remaining = manager.categories[catIdx].breakdown.count
                if remaining == 0 {
                    manager.categories[catIdx].size = 0
                    manager.categories[catIdx].fileCount = 0
                    manager.categories[catIdx].description = "No models installed"
                } else {
                    let totalSize = manager.categories[catIdx].breakdown.reduce(0) { $0 + $1.size }
                    manager.categories[catIdx].description = "\(remaining) model\(remaining == 1 ? "" : "s") installed — \(CleanupManager.formatBytes(totalSize))"
                }
            }
        }
    }
}

// MARK: - Export Report View

struct ExportReportView: View {
    @Binding var report: String
    @Binding var isGenerating: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Scan Report")
                    .font(.headline)
                if isGenerating {
                    ProgressView()
                        .controlSize(.small)
                    Text("Generating...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            if isGenerating {
                Spacer()
                ProgressView("Generating report...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Spacer()
            } else {
                TextEditor(text: .constant(report))
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
            }

            HStack {
                if !isGenerating {
                    Text("\(report.count) characters")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Copy to Clipboard") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report, forType: .string)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isGenerating)

                Button("Save...") {
                    let panel = NSSavePanel()
                    panel.allowedContentTypes = [.plainText]
                    panel.nameFieldStringValue = "SparkClean_Report_\(Date().formatted(date: .numeric, time: .omitted)).txt"
                    if panel.runModal() == .OK, let url = panel.url {
                        try? report.write(to: url, atomically: true, encoding: .utf8)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isGenerating)
            }
        }
        .padding(20)
        .frame(width: 700, height: 550)
    }
}
