//
//  DuplicateFinderView.swift
//  SparkClean
//
//  Created by George Khananaev on 3/6/26.
//

import SwiftUI
import AppKit
import CryptoKit

// MARK: - Duplicate Group Model

struct DuplicateGroup: Identifiable {
    let id = UUID()
    let fileName: String
    let fileSize: Int64
    let paths: [String]
    let isSimilarImage: Bool
    var wastedSize: Int64 {
        if isSimilarImage {
            // For similar images, sum all sizes except the largest
            let sizes = paths.compactMap { path -> Int64? in
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                      let size = attrs[.size] as? Int64 else { return nil }
                return size
            }.sorted(by: >)
            return sizes.dropFirst().reduce(0, +)
        }
        return fileSize * Int64(paths.count - 1)
    }
    var isSelected: Bool = false

    init(fileName: String, fileSize: Int64, paths: [String], isSimilarImage: Bool = false) {
        self.fileName = fileName
        self.fileSize = fileSize
        self.paths = paths
        self.isSimilarImage = isSimilarImage
    }
}

// MARK: - Duplicate Finder Manager

@Observable
class DuplicateFinderManager {
    var duplicateGroups: [DuplicateGroup] = []
    var isScanning = false
    var scanComplete = false
    var scanProgress: Double = 0
    var currentScanItem = ""
    var totalWastedSpace: Int64 = 0
    var searchQuery = ""
    var scanStats = ""

    var filteredGroups: [DuplicateGroup] {
        if searchQuery.isEmpty {
            return duplicateGroups
        }
        return duplicateGroups.filter {
            $0.fileName.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    var selectedCount: Int {
        duplicateGroups.filter { $0.isSelected }.count
    }

    var selectedWastedSpace: Int64 {
        duplicateGroups.filter { $0.isSelected }.reduce(0) { $0 + $1.wastedSize }
    }

    // MARK: - Scan Duplicates

    func scanDuplicates() {
        isScanning = true
        scanComplete = false
        duplicateGroups = []
        totalWastedSpace = 0
        scanProgress = 0
        currentScanItem = "Preparing scan..."

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let fm = FileManager.default
            let home = NSHomeDirectory()
            var dirs = [
                "\(home)/Downloads", "\(home)/Desktop", "\(home)/Documents",
                "\(home)/Movies", "\(home)/Music", "\(home)/Pictures"
            ]

            // Add Photos library originals (inside the .photoslibrary package)
            let photosLibPaths = [
                "\(home)/Pictures/Photos Library.photoslibrary/originals",
                "\(home)/Pictures/Photo Library.photoslibrary/originals"
            ]
            for p in photosLibPaths where fm.fileExists(atPath: p) {
                dirs.append(p)
            }

            // Phase 1: Group files by size
            DispatchQueue.main.async {
                self.currentScanItem = "Grouping files by size..."
                self.scanProgress = 0.05
            }

            var sizeGroups: [Int64: [(String, UInt64)]] = [:] // size -> [(path, inode)]
            let minSize: Int64 = 100_000           // 100KB (catches photos)
            let maxSize: Int64 = 2_147_483_648     // 2GB
            var totalFilesScanned = 0
            var totalImagesScanned = 0

            for (dirIndex, dir) in dirs.enumerated() where fm.fileExists(atPath: dir) {
                let dirName = (dir as NSString).lastPathComponent
                let displayName = dir.contains(".photoslibrary") ? "Photos Library" : dirName
                DispatchQueue.main.async {
                    self.currentScanItem = "Scanning \(displayName)..."
                    self.scanProgress = 0.05 + Double(dirIndex) / Double(dirs.count) * 0.30
                }

                // Photos library dirs should not skip package descendants (they're already inside)
                let isPhotosLib = dir.contains(".photoslibrary")
                guard let enumerator = fm.enumerator(
                    at: URL(fileURLWithPath: dir),
                    includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey, .isPackageKey,
                                                  .ubiquitousItemDownloadingStatusKey],
                    options: isPhotosLib ? [.skipsHiddenFiles] : [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { continue }

                for case let url as URL in enumerator {
                    autoreleasepool {
                        guard let rv = try? url.resourceValues(
                            forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey, .isPackageKey,
                                      .ubiquitousItemDownloadingStatusKey]
                        ) else { return }

                        if !isPhotosLib && rv.isPackage == true { enumerator.skipDescendants(); return }
                        if rv.ubiquitousItemDownloadingStatus == .notDownloaded { return }
                        guard rv.isRegularFile == true else { return }

                        let size = Int64(rv.totalFileAllocatedSize ?? 0)
                        totalFilesScanned += 1
                        let ext = url.pathExtension.lowercased()
                        if Self.imageExtensions.contains(ext) { totalImagesScanned += 1 }
                        guard size >= minSize, size <= maxSize else { return }

                        // Get inode for hardlink detection
                        var inode: UInt64 = 0
                        if let attrs = try? fm.attributesOfItem(atPath: url.path),
                           let ino = attrs[.systemFileNumber] as? UInt64 {
                            inode = ino
                        }

                        sizeGroups[size, default: []].append((url.path, inode))
                    }
                }
            }

            // Remove unique sizes
            sizeGroups = sizeGroups.filter { $0.value.count > 1 }

            DispatchQueue.main.async {
                self.currentScanItem = "Comparing file headers..."
                self.scanProgress = 0.40
            }

            // Phase 2: Compare file contents
            var results: [DuplicateGroup] = []
            var totalWasted: Int64 = 0
            let groupCount = sizeGroups.count
            var groupIndex = 0

            for (fileSize, entries) in sizeGroups {
                groupIndex += 1

                if groupIndex % 10 == 0 {
                    let progress = 0.40 + Double(groupIndex) / Double(max(groupCount, 1)) * 0.55
                    DispatchQueue.main.async {
                        self.scanProgress = min(progress, 0.95)
                        self.currentScanItem = "Comparing candidates (\(groupIndex)/\(groupCount))..."
                    }
                }

                // Skip hardlinks (same inode)
                var uniqueInodes: [UInt64: [String]] = [:]
                for (path, inode) in entries {
                    uniqueInodes[inode, default: []].append(path)
                }
                let candidates = uniqueInodes.flatMap { $0.value.count == 1 ? $0.value : [] }
                    + uniqueInodes.filter { $0.value.count > 1 }.map { $0.value.first! }
                guard candidates.count > 1 else { continue }

                // Compare first 4KB header
                var headerGroups: [Data: [String]] = [:]
                for path in candidates {
                    guard let handle = FileHandle(forReadingAtPath: path) else { continue }
                    let header = handle.readData(ofLength: 4096)
                    handle.closeFile()
                    headerGroups[header, default: []].append(path)
                }

                for (_, paths) in headerGroups where paths.count > 1 {
                    // Full SHA256 hash
                    var fullHashGroups: [String: [String]] = [:]
                    for path in paths {
                        if let hash = Self.sha256(ofFile: path) {
                            fullHashGroups[hash, default: []].append(path)
                        }
                    }

                    for (_, dupPaths) in fullHashGroups where dupPaths.count > 1 {
                        let name = (dupPaths[0] as NSString).lastPathComponent
                        let group = DuplicateGroup(
                            fileName: name,
                            fileSize: fileSize,
                            paths: dupPaths
                        )
                        results.append(group)
                        totalWasted += group.wastedSize
                    }
                }
            }

            // Collect paths already found as exact duplicates
            let exactDupPaths = Set(results.flatMap(\.paths))

            // Phase 3: Find visually similar images
            DispatchQueue.main.async {
                self.currentScanItem = "Scanning for similar images..."
                self.scanProgress = 0.70
            }
            let similarImages = self.scanSimilarImages(existingDupPaths: exactDupPaths)
            results.append(contentsOf: similarImages)
            for group in similarImages {
                totalWasted += group.wastedSize
            }

            // Sort by wasted size descending
            results.sort { $0.wastedSize > $1.wastedSize }

            DispatchQueue.main.async {
                self.duplicateGroups = results
                self.totalWastedSpace = totalWasted
                self.scanStats = "Scanned \(totalFilesScanned) files (\(totalImagesScanned) images)"
                self.isScanning = false
                self.scanComplete = true
                self.scanProgress = 1.0
                self.currentScanItem = ""
            }
        }
    }

    // MARK: - Clean Selected

    func cleanSelected() {
        let selected = duplicateGroups.filter { $0.isSelected }
        guard !selected.isEmpty else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            var cleanedGroupIDs: Set<UUID> = []

            for group in selected {
                // Keep the first file, trash the rest
                let pathsToRemove = Array(group.paths.dropFirst())
                var allRemoved = true
                for path in pathsToRemove {
                    let url = URL(fileURLWithPath: path)
                    if (try? fm.trashItem(at: url, resultingItemURL: nil)) == nil {
                        allRemoved = false
                    }
                }
                if allRemoved {
                    cleanedGroupIDs.insert(group.id)
                }
            }

            DispatchQueue.main.async {
                self.duplicateGroups.removeAll { cleanedGroupIDs.contains($0.id) }
                self.totalWastedSpace = self.duplicateGroups.reduce(0) { $0 + $1.wastedSize }
            }
        }
    }

    // MARK: - Select Helpers

    func selectAll() {
        for i in duplicateGroups.indices {
            duplicateGroups[i].isSelected = true
        }
    }

    func deselectAll() {
        for i in duplicateGroups.indices {
            duplicateGroups[i].isSelected = false
        }
    }

    // MARK: - SHA256 Streaming Hash

    private static func sha256(ofFile path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { handle.closeFile() }

        var hasher = CryptoKit.SHA256()
        while autoreleasepool(invoking: {
            let data = handle.readData(ofLength: 65536)
            if data.isEmpty { return false }
            hasher.update(data: data)
            return true
        }) {}

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Perceptual Image Hash (dHash)

    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "bmp", "gif", "webp",
        "raw", "cr2", "cr3", "nef", "arw", "dng", "orf", "rw2", "pef", "sr2"
    ]

    /// Difference hash (dHash) — compares adjacent pixel brightness in an 9x8 grid.
    /// Produces a 64-bit hash. Similar images produce similar hashes.
    private static func perceptualHash(ofImage path: String) -> UInt64? {
        guard let image = NSImage(contentsOfFile: path) else { return nil }
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }

        // Create a small 9x8 grayscale version
        let width = 9
        let height = 8
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        guard let cgImage = bitmap.cgImage else { return nil }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height)

        // Compute difference hash: compare each pixel to its right neighbor
        var hash: UInt64 = 0
        for row in 0..<height {
            for col in 0..<(width - 1) {
                let idx = row * width + col
                if pixels[idx] < pixels[idx + 1] {
                    hash |= 1 << UInt64(row * (width - 1) + col)
                }
            }
        }
        return hash
    }

    /// Hamming distance between two hashes
    private static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        return (a ^ b).nonzeroBitCount
    }

    /// Scan for visually similar images (different files that look the same)
    private func scanSimilarImages(existingDupPaths: Set<String>) -> [DuplicateGroup] {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        var dirs = [
            "\(home)/Downloads", "\(home)/Desktop", "\(home)/Documents",
            "\(home)/Pictures"
        ]

        // Add Photos library originals
        let photosLibPaths = [
            "\(home)/Pictures/Photos Library.photoslibrary/originals",
            "\(home)/Pictures/Photo Library.photoslibrary/originals"
        ]
        for p in photosLibPaths where fm.fileExists(atPath: p) {
            dirs.append(p)
        }

        let minImageSize: Int64 = 50_000 // 50KB — images can be small

        // Collect image files
        var imageFiles: [(path: String, size: Int64)] = []

        for dir in dirs where fm.fileExists(atPath: dir) {
            let isPhotosLib = dir.contains(".photoslibrary")
            guard let enumerator = fm.enumerator(
                at: URL(fileURLWithPath: dir),
                includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey, .isPackageKey],
                options: isPhotosLib ? [.skipsHiddenFiles] : [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator {
                autoreleasepool {
                    let ext = url.pathExtension.lowercased()
                    guard Self.imageExtensions.contains(ext) else { return }
                    // Skip files already found as exact duplicates
                    guard !existingDupPaths.contains(url.path) else { return }

                    guard let rv = try? url.resourceValues(
                        forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey, .isPackageKey]
                    ) else { return }
                    if !isPhotosLib && rv.isPackage == true { enumerator.skipDescendants(); return }
                    guard rv.isRegularFile == true else { return }
                    let size = Int64(rv.totalFileAllocatedSize ?? 0)
                    guard size >= minImageSize else { return }

                    imageFiles.append((url.path, size))
                }
            }
        }

        guard imageFiles.count > 1 else { return [] }

        // Compute perceptual hashes
        var hashGroups: [UInt64: [(path: String, size: Int64)]] = [:]
        for (idx, file) in imageFiles.enumerated() {
            if idx % 20 == 0 {
                let progress = 0.70 + Double(idx) / Double(imageFiles.count) * 0.25
                DispatchQueue.main.async {
                    self.scanProgress = min(progress, 0.95)
                    self.currentScanItem = "Analyzing images (\(idx)/\(imageFiles.count))..."
                }
            }
            if let hash = Self.perceptualHash(ofImage: file.path) {
                hashGroups[hash, default: []].append(file)
            }
        }

        // Group similar images (exact hash match = very similar)
        var results: [DuplicateGroup] = []
        var processedHashes = Set<UInt64>()

        for (hash, files) in hashGroups where files.count > 1 {
            guard !processedHashes.contains(hash) else { continue }
            processedHashes.insert(hash)

            // Also find nearby hashes (hamming distance <= 5)
            var allSimilar = files
            for (otherHash, otherFiles) in hashGroups where otherHash != hash {
                if !processedHashes.contains(otherHash) && Self.hammingDistance(hash, otherHash) <= 5 {
                    allSimilar.append(contentsOf: otherFiles)
                    processedHashes.insert(otherHash)
                }
            }

            guard allSimilar.count > 1 else { continue }

            let paths = allSimilar.map(\.path)
            let maxSize = allSimilar.map(\.size).max() ?? 0
            let name = (paths[0] as NSString).lastPathComponent

            results.append(DuplicateGroup(
                fileName: name,
                fileSize: maxSize,
                paths: paths,
                isSimilarImage: true
            ))
        }

        return results
    }
}

// MARK: - Duplicate Finder View

struct DuplicateFinderView: View {
    @State private var manager = DuplicateFinderManager()
    @State private var expandedGroupIDs: Set<UUID> = []
    @State private var showCleanAlert = false
    @State private var isCleaning = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerSection

            Divider()

            if manager.isScanning {
                scanningSection
            } else if manager.scanComplete {
                if manager.filteredGroups.isEmpty {
                    noResultsSection
                } else {
                    duplicateListSection
                }

                Divider()

                bottomBar
            } else {
                welcomeSection
            }
        }
        .alert("Clean Duplicates?", isPresented: $showCleanAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Move to Trash", role: .destructive) {
                isCleaning = true
                manager.cleanSelected()
                isCleaning = false
            }
        } message: {
            Text("This will keep the first copy of each selected group and move \(manager.selectedCount) duplicate group(s) (\(CleanupManager.formatBytes(manager.selectedWastedSpace))) to Trash.")
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(spacing: 14) {
            Image(systemName: "doc.on.doc")
                .font(.title2)
                .foregroundStyle(.teal)

            VStack(alignment: .leading, spacing: 2) {
                Text("Duplicate Finder")
                    .font(.title3)
                    .fontWeight(.bold)
                if manager.scanComplete {
                    Text("\(manager.duplicateGroups.count) groups found, \(CleanupManager.formatBytes(manager.totalWastedSpace)) wasted · \(manager.scanStats)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if manager.scanComplete {
                TextField("Search duplicates...", text: $manager.searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
            }

            Button {
                manager.scanDuplicates()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                    Text(manager.isScanning ? "Scanning..." : (manager.scanComplete ? "Rescan" : "Scan"))
                        .font(.system(size: 13, weight: .semibold))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
            }
            .buttonStyle(.borderedProminent)
            .tint(.teal)
            .disabled(manager.isScanning)

            if manager.scanComplete {
                Menu {
                    Button("Select All") { manager.selectAll() }
                    Button("Deselect All") { manager.deselectAll() }
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

    // MARK: - Scanning

    private var scanningSection: some View {
        VStack(spacing: 20) {
            Spacer()
            ProgressView(value: manager.scanProgress) {
                Text("Scanning for duplicates...")
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
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Welcome

    private var welcomeSection: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "doc.on.doc.fill")
                .font(.system(size: 64))
                .foregroundStyle(
                    LinearGradient(colors: [.teal, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            VStack(spacing: 10) {
                Text("Duplicate Finder")
                    .font(.title2)
                    .fontWeight(.bold)
                Text("Scan your common folders for duplicate files.\nFree up space by removing unnecessary copies.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - No Results

    private var noResultsSection: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checkmark.circle")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text(manager.searchQuery.isEmpty ? "No Duplicates Found" : "No Matches")
                .font(.title3)
                .fontWeight(.semibold)
            Text(manager.searchQuery.isEmpty
                 ? "Your files look clean — no duplicate files were detected.\n\(manager.scanStats)"
                 : "No duplicate groups match your search.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Duplicate List

    private var duplicateListSection: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(Array(manager.filteredGroups.enumerated()), id: \.element.id) { index, group in
                    DuplicateGroupRow(
                        group: group,
                        isExpanded: expandedGroupIDs.contains(group.id),
                        onToggleSelect: {
                            if let realIndex = manager.duplicateGroups.firstIndex(where: { $0.id == group.id }) {
                                manager.duplicateGroups[realIndex].isSelected.toggle()
                            }
                        },
                        onToggleExpand: {
                            if expandedGroupIDs.contains(group.id) {
                                expandedGroupIDs.remove(group.id)
                            } else {
                                expandedGroupIDs.insert(group.id)
                            }
                        }
                    )
                }
            }
            .padding(12)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 16) {
            if manager.selectedCount > 0 {
                Text("\(manager.selectedCount) group\(manager.selectedCount == 1 ? "" : "s") selected, \(CleanupManager.formatBytes(manager.selectedWastedSpace)) wasted")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                Text("No groups selected")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button {
                showCleanAlert = true
            } label: {
                HStack(spacing: 8) {
                    if isCleaning {
                        ProgressView()
                            .controlSize(.small)
                        Text("Cleaning...")
                            .font(.system(size: 13, weight: .semibold))
                    } else {
                        Image(systemName: "trash")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Clean Selected")
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(manager.selectedCount == 0 || isCleaning)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }
}

// MARK: - Duplicate Group Row

struct DuplicateGroupRow: View {
    let group: DuplicateGroup
    let isExpanded: Bool
    let onToggleSelect: () -> Void
    let onToggleExpand: () -> Void
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main row
            HStack(spacing: 12) {
                // Checkbox
                Button(action: onToggleSelect) {
                    Image(systemName: group.isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18))
                        .foregroundStyle(group.isSelected ? .teal : .secondary)
                }
                .buttonStyle(.plain)

                // Expand/collapse
                Button(action: onToggleExpand) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                }
                .buttonStyle(.plain)

                // File info
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(group.fileName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if group.isSimilarImage {
                            Text("SIMILAR IMAGE")
                                .font(.system(size: 8, weight: .bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.purple.opacity(0.15)))
                                .foregroundStyle(.purple)
                        } else {
                            Text("EXACT")
                                .font(.system(size: 8, weight: .bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.teal.opacity(0.15)))
                                .foregroundStyle(.teal)
                        }
                    }
                    Text("\(group.paths.count) copies\(group.isSimilarImage ? " (visually identical)" : "")")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                // File size
                Text(CleanupManager.formatBytes(group.fileSize))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)

                // Wasted space
                Text("+" + CleanupManager.formatBytes(group.wastedSize) + " wasted")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(group.wastedSize > 100_000_000 ? .red : .orange)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture {
                onToggleExpand()
            }

            // Expanded paths
            if isExpanded {
                Divider()
                    .padding(.horizontal, 12)

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(group.paths.enumerated()), id: \.offset) { index, path in
                        HStack(spacing: 10) {
                            if index == 0 {
                                Text("Keep")
                                    .font(.system(size: 10, weight: .bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.green.opacity(0.15)))
                                    .foregroundStyle(.green)
                            } else {
                                Text("Remove")
                                    .font(.system(size: 10, weight: .bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.red.opacity(0.15)))
                                    .foregroundStyle(.red)
                            }

                            Text(path)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Spacer()

                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "folder")
                                        .font(.system(size: 10))
                                    Text("Reveal")
                                        .font(.system(size: 10, weight: .medium))
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(group.isSelected ? Color.teal.opacity(0.08) : (isHovered ? Color.primary.opacity(0.04) : Color.primary.opacity(0.02)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(group.isSelected ? Color.teal.opacity(0.25) : Color.primary.opacity(0.06), lineWidth: 1)
        )
        .onHover { isHovered = $0 }
    }
}
