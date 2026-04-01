# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/), [SemVer](https://semver.org/)

## [Unreleased]

## [1.3.0] - 2026-04-02

### Added
- **cleanup**: Privacy category with 7 scan definitions — Recent Items, Spotlight History, Shell History, Safari History, Chrome History (multi-profile), Firefox Form History, Browser Cookies
- **cleanup**: Admin privilege escalation for root-owned files in main clean pipeline (macOS password dialog)
- **uninstaller**: Admin privilege escalation for uninstalling root-owned apps (e.g., Microsoft Office)
- **uninstaller**: Show in Finder icon in app detail header
- **uninstaller**: Error alert when uninstall fails
- **app**: Admin escalation for Trash Monitor leftover cleanup
- **ui**: Animated stat counters, disk bar transitions, hover effects, section transitions (P6)
- **maintenance**: Clear Time Machine Snapshots task with admin escalation
- **maintenance**: Free APFS Purgeable Space task with defragmentation
- **maintenance**: Per-task estimate badges (TM snapshots, purgeable space, Spotlight index size)
- **maintenance**: Task selection with checkboxes, "Run Selected" button, and confirmation dialog

### Changed
- **ui**: Removed unused Filter search bar from sidebar
- **cleanup**: `~/Library/Safari` added to protected paths blocklist
- **cleanup**: Static `ISO8601DateFormatter` replacing per-call allocation

### Fixed
- **cleanup**: `directorySizeSync` and `directorySizeSyncExcluding` now handle individual files (was silently returning 0 for non-directory paths like shell history files)
- **cleanup**: `runCommand` pipe deadlock — reads data before `waitUntilExit` to prevent hang when output exceeds 64KB
- **ui**: DuplicateFinderManager strong self capture replaced with `[weak self]` to prevent memory leak during long scans
- **ui**: Disk usage bar visual gap fixed — segments now use clipShape instead of per-segment corner radius
- **ui**: DuplicateFinderManager now supports scan cancellation via `cancelRequested` flag
- **ui**: StartupManager `launchctl` toggle only updates UI if command actually succeeded
- **ui**: StartupManager `NSWorkspace.shared.icon` moved to main thread to prevent potential crash

## [1.2.1] - 2026-04-01

### Added
- **app**: GitHub update checker — check for new versions from Settings > About or Support menu, download DMG to user-chosen location
- **settings**: Optional auto-update check on launch (Settings > General > Startup, off by default)

### Changed
- **ui**: Contact Support and Report a Bug links now open GitHub issues instead of showing email address
- **ui**: Privacy policy updated to reflect optional update check network request

### Fixed
- **ui**: Intro video no longer replays when minimizing and restoring the app window
- **settings**: Update check now shows the latest GitHub version in the result

## [1.2.0] - 2026-04-01

### Added
- **app**: New Maintenance view — system maintenance tasks (flush DNS, purge memory, rebuild indexes, etc.)
- **app**: New Startup Manager — view and manage Launch Agents, System Agents, and Daemons
- **uninstaller**: Smart Trash Monitor — detects apps moved to Trash and offers to clean leftover files (caches, preferences, containers, logs, launch agents)
- **uninstaller**: Drag-and-drop `.app` files onto Uninstaller welcome screen for instant analysis
- **uninstaller**: Per-path selection checkboxes — choose exactly which related data to remove
- **uninstaller**: Launch Agent discovery in related data scanning
- **settings**: "Monitor Trash for uninstalled apps" toggle under Smart Cleanup (off by default)

### Changed
- **uninstaller**: Low-confidence items (App Support, Containers, Group Containers, Home Directory data) default to unselected for safety
- **uninstaller**: Only selected related paths are deleted during uninstall (previously removed all)
- **uninstaller**: `calculateAppSize` made accessible for drag-and-drop analysis

### Fixed
- **uninstaller**: Fixed autoreleasepool leak in dirSizeAndCount (same pattern as the v1.1.0 directorySizeSync fix)
- **uninstaller**: Eliminated duplicated file enumeration code in KnownAppData and dotfile scanning
- **trash-monitor**: Thread safety with OSAllocatedUnfairLock replacing bare Set for knownApps
- **trash-monitor**: Fixed potential retain cycle with `[weak self]` in Task closure

## [1.1.0] - 2026-03-30

### Added
- **cleanup**: Memory pressure monitoring via DispatchSourceMemoryPressure — auto-cancels scans under critical system pressure
- **cleanup**: Protected path blocklist (30+ paths) preventing deletion of critical system/user directories
- **cleanup**: Deletion audit log written to ~/Library/Logs/SparkClean/ on every cleanup
- **cleanup**: Path depth guard rejects any path with fewer than 3 components
- **cleanup**: 10 new scan categories — HuggingFace Models, Ollama Model Cache, LM Studio Models, Bazel Cache, Deno Cache, Poetry Cache, Font Caches, Speech Data Cache, Xcode Playground Cache, Provisioning Profiles
- **uninstaller**: Protected path validation to prevent deletion of system paths

### Changed
- **cleanup**: selectAll() now excludes caution-level categories for safety
- **cleanup**: Other App Caches uses deleteChildrenOnly to preserve cache directories
- **cleanup**: Docker scanning no longer double-counts — removed Docker Desktop Data filesystem scan that overlapped with CLI-based Docker scans
- **cleanup**: Old Downloads checks newest file date inside directories instead of directory modification date
- **cleanup**: Large Files scanner checks if parent directory was already scanned by other phases
- **cleanup**: hasMatchingApp tightened to reduce false positives in orphaned app data detection
- **cleanup**: Trash failure no longer silently falls back to permanent deletion

### Fixed
- **cleanup**: Critical memory leak in directorySizeSync — missing autoreleasepool caused 34GB RAM consumption on large directory scans
- **cleanup**: Critical memory leak in perceptualHash — replaced NSImage+tiffRepresentation (~150MB/image) with CGImageSource thumbnail (~1KB/image)
- **cleanup**: scannedPaths set now cleared after scan completes to release retained strings
- **cleanup**: directorySizeSyncExcluding now calls skipDescendants for excluded paths (performance)
- **cleanup**: XCPGDevices no longer double-counted in both Xcode Previews and Playground Cache
- **cleanup**: DuplicateGroup.wastedSize pre-computed at init instead of filesystem I/O on every SwiftUI render
- **cleanup**: sizeGroups in DuplicateFinderView pruned per-directory to limit peak memory
- **cleanup**: SHA256 buffer increased from 64KB to 256KB for fewer syscalls
- **cleanup**: Static ByteCountFormatter and DateFormatter replacing per-call allocation
- **cleanup**: autoreleasepool added to scanBrokenSymlinks, findNodeModulesRecursive, header comparison
- **ui**: NotificationCenter observer leak fixed in SplashScreenView

## [1.0.0] - 2026-03-14

### Added
- **app**: Rename project from MacSimpleCleanup to SparkClean
- **cleanup**: Disk cleanup scanning and file management
- **uninstaller**: App uninstaller feature
- **settings**: Settings view for user preferences
- **dashboard**: Dashboard components for stats display
- **models**: Data models for cleanup categories and items
- **assets**: Custom app icon set with all required sizes
- **project**: App entitlements and .gitignore configuration
- **ui**: Splash screen intro video on app launch with skip button and settings toggle
- **cleanup**: Ollama model management with per-model deletion via `ollama rm` CLI
- **cleanup**: Large Files category with configurable size, file types, locations, and age filter
- **ui**: Professional clean confirmation sheet with safety breakdown and legal disclaimer
- **ui**: Clean confirmation splits items into "Moved to Trash" and "Permanently Deleted" sections
- **ui**: Partial selection indicator (minus checkbox) for categories with mixed selections
- **uninstaller**: Instant app removal from list with success banner and Open Trash button
- **ui**: Dropdown menus (...) on Uninstaller and Duplicate Finder headers
- **app**: Custom About dialog with system info, build details, GitHub repo link, and Copy Info button
- **app**: Support menu with Help, Contact Support, Report a Bug, GitHub Repository, Privacy Policy, What's New
- **app**: Selection menu with Select All, Deselect All, Select Safe Only shortcuts
- **app**: Scan Now (Cmd+R) and Export Report (Cmd+E) keyboard shortcuts
- **ui**: Onboarding flow for first-time users
- **ui**: What's New view with version-based display
- **ui**: Help sheet with usage guide
- **ui**: Privacy Policy view
- **ui**: Clean progress bar in sidebar
- **ui**: Partial scan banner when scan is cancelled
- **ui**: Smart recommendation banner for Quick Clean
- **ui**: Clean complete dialog with Open Trash and Show Errors buttons
- **cleanup**: Error tracking for clean operations with per-category progress
- **cleanup**: Partial scan results preserved on cancel instead of discarding
- **cleanup**: isDeletableFile check before counting file sizes in scan results
- **cleanup**: 30-second timeout on CLI commands (Docker, Ollama, mdfind) to prevent hangs
- **cleanup**: Dynamic Chrome profile discovery instead of hardcoded Default/Profile 1
- **cleanup**: iOS backup entries now show device name instead of UUID
- **models**: ScanConstants enum with extracted magic numbers
- **models**: ReleaseNote struct for changelog display
- **models**: Stable path-based SwiftUI identifiers replacing random UUIDs
- **models**: displayName property on PathStat for human-readable breakdown entries
- **project**: Info.plist with privacy usage descriptions for folder access
- **project**: LICENSE with non-commercial open source terms
- **project**: SUPPORTED.md with tested devices and compatibility info
- **project**: Privacy manifest declares UserDefaults API usage (CA92.1)
- **dashboard**: Disk usage bar tooltip and accessibility labels
- **ui**: Safety badge tooltips with detailed explanations
- **ui**: Accessibility labels on category rows, badges, stat cards, group cards, sidebar badges, onboarding buttons

### Changed
- **cleanup**: Replace post-clean rescan with instant in-memory state update
- **cleanup**: Docker/Ollama clean now checks return values and reports failures
- **cleanup**: scanLargeFiles returns nil when no files found instead of empty category
- **cleanup**: Ollama model deletion finds entry by name instead of array index (race condition fix)
- **ui**: Sidebar and category rows show selected-only sizes and counts
- **ui**: Category rows read live from manager for reactive updates (Ollama delete, etc.)
- **ui**: Dashboard header restructured with icon+title left, buttons right
- **ui**: All categories visible in sidebar before scan (dimmed with "—")
- **settings**: Large Files settings tab with size, locations, file types, and age filter
- **cleanup**: Thread safety with OSAllocatedUnfairLock for scannedPaths and cancelRequested
- **cleanup**: autoreleasepool in cache scanning loops for memory management
- **cleanup**: Replaced try? with do/catch for proper error collection during clean
- **cleanup**: Fixed node_modules depth check (guard depth < maxDepth)
- **settings**: Enhanced About tab with version, system info, and contact links
- **settings**: Version display shows only version number without build number
- **uninstaller**: Combined dirSize/fileCount into single enumeration pass for performance
- **uninstaller**: NSWorkspace icon fetch moved to main thread for thread safety
- **uninstaller**: filteredApps cached and updated on change instead of recomputing every render
- **uninstaller**: selectedApp cleared on rescan to prevent stale data
- **models**: largeFiles category uses yellow color instead of duplicate orange

### Removed
- **cleanup**: iCloud scan categories (Drive, App Data, Photos Library)
- **cleanup**: Duplicate scan category, replaced by standalone Duplicate Finder tool
- **settings**: iCloud scan toggle removed from settings
- **cleanup**: CryptoKit import from CleanupManager (moved to DuplicateFinderView only)
- **app**: Removed unused isHoveringCopy state variable
- **cleanup**: Removed unused modified variable in scanOllamaModels

### Fixed
- **uninstaller**: Trash-only mode no longer falls back to permanent deletion silently
- **uninstaller**: SparkClean excluded from its own uninstaller list
- **uninstaller**: Fixed inverted trash fallback logic
- **uninstaller**: Added running app termination check before uninstall
- **ui**: Division by zero guard on disk usage and category bars
- **ui**: Export report filename uses yyyy-MM-dd instead of locale date with slashes
- **ui**: Fixed com.microsoft.PowerPoint case in cache path
- **ui**: Fixed estimatedSmartScans count to match actual scan count
- **app**: Fixed Help menu triggering macOS "Help isn't available" system message
- **app**: Fixed version display showing unwanted build number "(1)"
