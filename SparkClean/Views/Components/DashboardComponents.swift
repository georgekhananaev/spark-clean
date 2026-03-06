//
//  DashboardComponents.swift
//  SparkClean
//
//  Created by George Khananaev on 3/6/26.
//

import SwiftUI

// MARK: - Disk Usage Card

struct DiskUsageCardView: View {
    let disk: DiskUsageInfo
    let reclaimable: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Disk Usage", systemImage: "internaldrive")
                    .font(.headline)
                Spacer()
                Text("\(String(format: "%.1f%%", disk.usedPercentage * 100)) used")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .separatorColor).opacity(0.3))

                    HStack(spacing: 0) {
                        let usedNonReclaimable = max(0, disk.usedSpace - reclaimable)
                        RoundedRectangle(cornerRadius: 6)
                            .fill(
                                LinearGradient(
                                    colors: [.blue, .indigo],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(0, geo.size.width * CGFloat(usedNonReclaimable) / CGFloat(disk.totalSpace)))

                        if reclaimable > 0 {
                            RoundedRectangle(cornerRadius: 0)
                                .fill(
                                    LinearGradient(
                                        colors: [.orange, .red],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: max(0, geo.size.width * CGFloat(reclaimable) / CGFloat(disk.totalSpace)))
                        }
                    }
                }
            }
            .frame(height: 20)
            .help("Blue = used space, Orange = reclaimable by SparkClean, Gray = free space")

            HStack(spacing: 20) {
                LegendDot(color: .blue, label: "Used", value: CleanupManager.formatBytes(max(0, disk.usedSpace - reclaimable)))
                LegendDot(color: .orange, label: "Reclaimable", value: CleanupManager.formatBytes(reclaimable))
                LegendDot(color: Color(nsColor: .separatorColor), label: "Free", value: CleanupManager.formatBytes(disk.freeSpace))
            }
            .font(.caption)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Disk usage: \(String(format: "%.1f%%", disk.usedPercentage * 100)) used, \(CleanupManager.formatBytes(disk.freeSpace)) free, \(CleanupManager.formatBytes(reclaimable)) reclaimable")
    }
}

struct LegendDot: View {
    let color: Color
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .fontWeight(.medium)
        }
    }
}

// MARK: - Stat Card

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

// MARK: - Top Category Row

struct TopCategoryRow: View {
    let category: CleanupCategory
    let maxSize: Int64

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: category.icon)
                .foregroundStyle(category.color)
                .frame(width: 20)

            Text(category.name)
                .font(.system(size: 13))
                .frame(width: 200, alignment: .leading)
                .lineLimit(1)

            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 4)
                    .fill(category.color.gradient)
                    .frame(width: max(4, geo.size.width * CGFloat(category.size) / CGFloat(maxSize)))
            }
            .frame(height: 16)

            Text(CleanupManager.formatBytes(category.size))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(category.color)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Group Card

struct GroupCard: View {
    let group: CategoryGroup
    let categories: [CleanupCategory]
    let action: () -> Void
    @State private var isHovered = false

    private var groupSize: Int64 {
        categories.reduce(0) { $0 + $1.size }
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: group.icon)
                        .font(.title3)
                        .foregroundStyle(group.color)
                    Spacer()
                    Text("\(categories.count)")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(group.color.opacity(0.15)))
                        .foregroundStyle(group.color)
                }

                Text(group.rawValue)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(categories.isEmpty ? "—" : CleanupManager.formatBytes(groupSize))
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(categories.isEmpty ? .secondary : group.color)
            }
            .padding(16)
            .opacity(categories.isEmpty ? 0.6 : 1.0)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: isHovered ? group.color.opacity(0.2) : .clear, radius: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isHovered ? group.color.opacity(0.3) : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Size Label

struct SizeLabel: View {
    let size: Int64
    let color: Color

    var body: some View {
        Text(CleanupManager.formatBytes(size))
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(color.opacity(0.1))
            )
    }
}

// MARK: - Disk Mini Stat

struct DiskMiniStat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Sidebar Row

struct SidebarRow: View {
    let label: String
    let icon: String
    let iconColor: Color
    var trailing: String? = nil
    var badgeCount: Int? = nil
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
                    .frame(width: 20)

                Text(label)
                    .foregroundStyle(.primary)

                Spacer()

                if let trailing {
                    Text(trailing)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                if let badgeCount {
                    Text("\(badgeCount)")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(iconColor.opacity(0.7)))
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
                .padding(.horizontal, 4)
        )
    }
}
