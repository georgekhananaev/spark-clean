//
//  SettingsView.swift
//  SparkClean
//
//  Created by George Khananaev on 3/6/26.
//

import SwiftUI

struct SettingsView: View {
    @AppStorage("scanNodeModules") private var scanNodeModules = true
    @AppStorage("scanDocker") private var scanDocker = true
    @AppStorage("scanUnusedApps") private var scanUnusedApps = true
    @AppStorage("unusedAppThresholdDays") private var unusedAppThresholdDays = 90
    @AppStorage("largeFileThresholdMB") private var largeFileThresholdMB = 50
    @AppStorage("oldFileThresholdDays") private var oldFileThresholdDays = 30
    @AppStorage("screenshotThresholdDays") private var screenshotThresholdDays = 30
    @AppStorage("preferTrash") private var preferTrash = true
    @AppStorage("scanLargeFiles") private var scanLargeFiles = true
    @AppStorage("scanVirtualEnvironments") private var scanVirtualEnvironments = true
    @AppStorage("screenRecordingThresholdDays") private var screenRecordingThresholdDays = 60
    @AppStorage("scanIOSBackups") private var scanIOSBackups = true
    @AppStorage("scanIMessageAttachments") private var scanIMessageAttachments = true
    @AppStorage("scanBrokenSymlinks") private var scanBrokenSymlinks = true
    @AppStorage("scanScreenRecordings") private var scanScreenRecordings = true
@AppStorage("showIntroVideo") private var showIntroVideo = true

    // Large Files settings
    @AppStorage("largeFileScanDownloads") private var largeFileScanDownloads = true
    @AppStorage("largeFileScanDesktop") private var largeFileScanDesktop = true
    @AppStorage("largeFileScanDocuments") private var largeFileScanDocuments = true
    @AppStorage("largeFileScanMovies") private var largeFileScanMovies = true
    @AppStorage("largeFileScanMusic") private var largeFileScanMusic = true
    @AppStorage("largeFileScanPictures") private var largeFileScanPictures = true
    @AppStorage("largeFileIncludeVideos") private var largeFileIncludeVideos = true
    @AppStorage("largeFileIncludeImages") private var largeFileIncludeImages = true
    @AppStorage("largeFileIncludeArchives") private var largeFileIncludeArchives = true
    @AppStorage("largeFileIncludeInstallers") private var largeFileIncludeInstallers = true
    @AppStorage("largeFileIncludeAudio") private var largeFileIncludeAudio = true
    @AppStorage("largeFileIncludeOther") private var largeFileIncludeOther = true
    @AppStorage("largeFileMaxAgeDays") private var largeFileMaxAgeDays = 0
    @AppStorage("largeFileMaxResults") private var largeFileMaxResults = 100

    var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            scanTab
                .tabItem {
                    Label("Scanning", systemImage: "magnifyingglass")
                }

            largeFilesTab
                .tabItem {
                    Label("Large Files", systemImage: "doc.fill")
                }

            cleanupTab
                .tabItem {
                    Label("Cleanup", systemImage: "trash")
                }

            aboutTab
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 500, height: 560)
    }

    // MARK: General

    private var generalTab: some View {
        Form {
            Section("Startup") {
                Toggle("Show intro video on launch", isOn: $showIntroVideo)
            }

            Section("Core Scans") {
                Toggle("Scan node_modules directories", isOn: $scanNodeModules)
                Toggle("Scan Docker resources", isOn: $scanDocker)
                Toggle("Detect unused applications", isOn: $scanUnusedApps)
            }

            Section {
                Toggle("Scan for large files", isOn: $scanLargeFiles)
                Toggle("Scan virtual environments", isOn: $scanVirtualEnvironments)
            } header: {
                Text("Storage Analysis")
            } footer: {
                Text("Duplicate files can be found using the Duplicate Finder tool.")
            }

            Section("System & Media") {
                Toggle("Scan iOS backups", isOn: $scanIOSBackups)
                Toggle("Scan iMessage attachments", isOn: $scanIMessageAttachments)
                Toggle("Scan broken symlinks", isOn: $scanBrokenSymlinks)
                Toggle("Scan screen recordings", isOn: $scanScreenRecordings)
            }

        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: Scanning

    private var scanTab: some View {
        Form {
            Section("Thresholds") {
                HStack {
                    Text("Unused app threshold")
                    Spacer()
                    Picker("", selection: $unusedAppThresholdDays) {
                        Text("30 days").tag(30)
                        Text("60 days").tag(60)
                        Text("90 days").tag(90)
                        Text("180 days").tag(180)
                        Text("365 days").tag(365)
                    }
                    .frame(width: 120)
                }

                HStack {
                    Text("Old file threshold")
                    Spacer()
                    Picker("", selection: $oldFileThresholdDays) {
                        Text("7 days").tag(7)
                        Text("14 days").tag(14)
                        Text("30 days").tag(30)
                        Text("60 days").tag(60)
                        Text("90 days").tag(90)
                    }
                    .frame(width: 120)
                }

                HStack {
                    Text("Old screenshot threshold")
                    Spacer()
                    Picker("", selection: $screenshotThresholdDays) {
                        Text("7 days").tag(7)
                        Text("14 days").tag(14)
                        Text("30 days").tag(30)
                        Text("60 days").tag(60)
                    }
                    .frame(width: 120)
                }

                HStack {
                    Text("Screen recording threshold")
                    Spacer()
                    Picker("", selection: $screenRecordingThresholdDays) {
                        Text("14 days").tag(14)
                        Text("30 days").tag(30)
                        Text("60 days").tag(60)
                        Text("90 days").tag(90)
                    }
                    .frame(width: 120)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: Large Files

    private var largeFilesTab: some View {
        Form {
            Section {
                HStack {
                    Text("Minimum file size")
                    Spacer()
                    Picker("", selection: $largeFileThresholdMB) {
                        Text("10 MB").tag(10)
                        Text("25 MB").tag(25)
                        Text("50 MB").tag(50)
                        Text("100 MB").tag(100)
                        Text("250 MB").tag(250)
                        Text("500 MB").tag(500)
                        Text("1 GB").tag(1000)
                    }
                    .frame(width: 120)
                }

                HStack {
                    Text("Maximum results")
                    Spacer()
                    Picker("", selection: $largeFileMaxResults) {
                        Text("25").tag(25)
                        Text("50").tag(50)
                        Text("100").tag(100)
                        Text("200").tag(200)
                        Text("500").tag(500)
                    }
                    .frame(width: 120)
                }

                HStack {
                    Text("Only files older than")
                    Spacer()
                    Picker("", selection: $largeFileMaxAgeDays) {
                        Text("Any age").tag(0)
                        Text("7 days").tag(7)
                        Text("14 days").tag(14)
                        Text("30 days").tag(30)
                        Text("60 days").tag(60)
                        Text("90 days").tag(90)
                        Text("180 days").tag(180)
                        Text("365 days").tag(365)
                    }
                    .frame(width: 120)
                }
            } header: {
                Text("Size & Filters")
            } footer: {
                Text("\"Only files older than\" filters by last access date — recently used files are excluded.")
            }

            Section("Scan Locations") {
                Toggle("Downloads", isOn: $largeFileScanDownloads)
                Toggle("Desktop", isOn: $largeFileScanDesktop)
                Toggle("Documents", isOn: $largeFileScanDocuments)
                Toggle("Movies", isOn: $largeFileScanMovies)
                Toggle("Music", isOn: $largeFileScanMusic)
                Toggle("Pictures", isOn: $largeFileScanPictures)
            }

            Section {
                Toggle("Videos (mp4, mov, avi, mkv, wmv, m4v, webm, flv)", isOn: $largeFileIncludeVideos)
                Toggle("Images (raw, cr2, nef, arw, dng, tiff, psd, ai)", isOn: $largeFileIncludeImages)
                Toggle("Archives (zip, tar, gz, 7z, rar, bz2, xz, tgz)", isOn: $largeFileIncludeArchives)
                Toggle("Installers (dmg, pkg, iso)", isOn: $largeFileIncludeInstallers)
                Toggle("Audio (wav, flac, aiff, alac, mp3, m4a, ogg)", isOn: $largeFileIncludeAudio)
                Toggle("Other / Unknown file types", isOn: $largeFileIncludeOther)
            } header: {
                Text("File Types to Include")
            } footer: {
                Text("Disable file types you want to keep. Only enabled types will appear in scan results.")
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: Cleanup

    private var cleanupTab: some View {
        Form {
            Section {
                Toggle("Move files to Trash instead of deleting permanently", isOn: $preferTrash)
            } header: {
                Text("Deletion Behavior")
            } footer: {
                Text("When enabled, files are moved to Trash first. If that fails, they are deleted permanently.")
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: About

    private var aboutTab: some View {
        VStack(spacing: 14) {
            Spacer()

            Image(systemName: "sparkles")
                .font(.system(size: 48))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.blue, .purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Text("SparkClean")
                .font(.title2)
                .fontWeight(.bold)

            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
            Text("Version \(version)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Mac Storage & Cache Cleaner.\nScans caches, temp files, Docker resources,\ndev tools, browsers, and more.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 16) {
                Link("Contact Support", destination: URL(string: "mailto:george@khananaev.com")!)
                    .font(.caption)

                Text("·").foregroundStyle(.tertiary)

                Link("Report a Bug", destination: URL(string: "mailto:george@khananaev.com?subject=SparkClean%20Bug%20Report")!)
                    .font(.caption)
            }

            Text("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Spacer()

            Text("Copyright \u{00A9} 2026 George Khananaev. All rights reserved.")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer().frame(height: 8)
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    SettingsView()
}
