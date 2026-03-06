# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/), [SemVer](https://semver.org/)

## [Unreleased]

### Added
- **ui**: Splash screen intro video on app launch with skip button and settings toggle
- **cleanup**: Ollama model management with per-model deletion via `ollama rm` CLI
- **cleanup**: Large Files category with configurable size, file types, locations, and age filter
- **ui**: Professional clean confirmation sheet with safety breakdown and legal disclaimer
- **ui**: Partial selection indicator (minus checkbox) for categories with mixed selections
- **uninstaller**: Instant app removal from list with success banner and Open Trash button
- **ui**: Dropdown menus (...) on Uninstaller and Duplicate Finder headers
- **app**: Custom About dialog with system info, build details, and Copy Info button
- **app**: Support menu with Help, Contact Support, Report a Bug, Privacy Policy, What's New
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
- **models**: ScanConstants enum with extracted magic numbers
- **models**: ReleaseNote struct for changelog display
- **models**: Stable path-based SwiftUI identifiers replacing random UUIDs
- **project**: Info.plist with privacy usage descriptions for folder access
- **dashboard**: Disk usage bar tooltip and accessibility labels
- **ui**: Safety badge tooltips with detailed explanations
- **ui**: Accessibility labels on category rows, badges, and buttons

### Changed
- **cleanup**: Replace post-clean rescan with instant in-memory state update
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

### Removed
- **cleanup**: iCloud scan categories (Drive, App Data, Photos Library) — problematic and slow
- **cleanup**: Duplicate scan category — replaced by standalone Duplicate Finder tool
- **settings**: iCloud scan toggle removed from settings
- **cleanup**: CryptoKit import from CleanupManager (moved to DuplicateFinderView only)

### Fixed
- **uninstaller**: Fixed inverted trash fallback logic (was != nil, now do/catch)
- **uninstaller**: Added running app termination check before uninstall
- **app**: Fixed Help menu triggering macOS "Help isn't available" system message
- **app**: Fixed version display showing unwanted build number "(1)"

## [1.0.0] - 2026-03-06

### Added
- **app**: Rename project from MacSimpleCleanup to SparkClean
- **cleanup**: Disk cleanup scanning and file management
- **uninstaller**: App uninstaller feature
- **settings**: Settings view for user preferences
- **dashboard**: Dashboard components for stats display
- **models**: Data models for cleanup categories and items
- **assets**: Custom app icon set with all required sizes
- **project**: App entitlements and .gitignore configuration
