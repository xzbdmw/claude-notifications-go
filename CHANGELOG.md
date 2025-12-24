# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.4.2] - 2025-12-24

### Fixed
- **Click-to-focus now works on macOS Sequoia (15.x)** 🎯
  - Removed `-sender` option that was conflicting with `-activate`
  - Trade-off: notifications no longer show custom Claude icon
  - Click-to-focus now reliably activates terminal window

## [1.4.1] - 2025-12-24

### Fixed
- Skip terminal-notifier integration test in CI (no NotificationCenter available)

## [1.4.0] - 2025-12-24

### Added
- **Click-to-focus notifications on macOS** 🎯
  - Clicking a notification activates your terminal window
  - Auto-detects terminal app (Warp, iTerm, Terminal, kitty, Alacritty, etc.)
  - Uses `terminal-notifier` under the hood
  - Enable with `"clickToFocus": true` in desktop config (enabled by default)
  - Manual override: `"terminalBundleID": "com.your.terminal"`

- **Claude icon in notifications** 🤖 *(removed in 1.4.2 due to macOS Sequoia conflict)*
  - Custom Claude icon displayed on the left side of macOS notifications
  - Auto-creates `ClaudeNotifications.app` on first notification
  - ⚠️ Removed in v1.4.2: `-sender` option conflicted with click-to-focus on macOS 15.x

### Changed
- **Shorter notification titles**
  - `✅ Task Completed` → `✅ Completed`
  - `🔍 Review Completed` → `🔍 Review`
  - `❓ Claude Has Questions` → `❓ Question`
  - `📋 Plan Ready for Review` → `📋 Plan`

### Technical
- Terminal bundle ID detection via `__CFBundleIdentifier` and `TERM_PROGRAM`
- ~~Uses `-sender com.claude.notifications` for reliable icon display~~ (removed in 1.4.2)

## [1.3.0] - 2025-12-24

### Added
- **Lark/Feishu webhook support** - New webhook preset for Lark (飞书) notifications
  - Interactive card format with colored headers based on notification status
  - Supports all notification types (Task Complete, Review Complete, Question, Plan Ready)
  - Wide screen mode for better readability
  - Session ID included in notifications
  - Add `"preset": "lark"` to webhook configuration to enable

## [1.2.1] - 2025-12-14

### Fixed
- **Webhook notifications never sent** ([#6](https://github.com/777genius/claude-notifications-go/issues/6))
  - `Shutdown()` now waits for in-flight HTTP requests to complete before exit
  - Added `defer webhookSvc.Shutdown(5s)` to `HandleHook()` for graceful shutdown
  - Previously: `cancel()` was called immediately, interrupting HTTP requests
  - Now: `cancel()` is only called after completion or on timeout

### Added
- E2E test `TestE2E_WebhookGracefulShutdown` - deterministic graceful shutdown verification
- Unit tests for `Shutdown()` + `SendAsync()` combination
- Updated `webhookInterface` to include `Shutdown(timeout)` method

## [1.2.0] - 2025-11-03

### Added
- **Subagent notification control** - New config option `notifyOnSubagentStop`
  - Prevents premature "Completed" notifications when Task agents (subagents) finish
  - Main Claude session continues working without distracting notifications
  - Default: `false` (notifications disabled for subagents)
  - Users can enable via `"notifyOnSubagentStop": true` in config if desired
  - Fixes issue where Plan/Explore agents triggered completion notifications while Claude was still thinking

### Changed
- SubagentStop hook now checks config before sending notifications
- Split SubagentStop and Stop hook handling for better control

### Technical Details
- Added `NotifyOnSubagentStop` boolean field to `NotificationsConfig` struct
- Updated hook handler in `internal/hooks/hooks.go` to respect config setting
- Added comprehensive tests for both enabled and disabled states
- All existing tests pass with new functionality

## [1.1.2] - 2025-10-25

### Fixed
- **Volume control on macOS** 🔊
  - Replaced `effects.Volume` with `effects.Gain` for reliable volume control
  - Volume settings (e.g., 30%) now work correctly on macOS
  - Simplified volume conversion logic (linear instead of logarithmic)
  - Affects both notification sounds and `sound-preview` utility
  - All tests passing with new implementation
- **GitHub Actions build step** - Windows builds now work correctly
  - Added `shell: bash` to build step for all platforms
  - Resolved PowerShell syntax error preventing Windows builds from completing

### Changed
- Simplified `volumeToGain()` function - removed complex logarithmic calculations
- Updated documentation in code to reflect linear gain formula: `output = input * (1 + Gain)`

## [1.1.1] - 2025-10-25

### Fixed
- **Missing sound-preview binary** - fixes `/notifications-settings` sound preview
  - Added `sound-preview` utility to build system
  - Now built for all platforms (darwin, linux, windows)
  - Included in GitHub Releases
  - Supports interactive sound preview during settings configuration
  - Handles MP3, WAV, FLAC, OGG, AIFF formats

## [1.1.0] - 2025-10-25

### Added
- **New notification type: API Error 401** 🔴
  - Detects authentication errors when OAuth token expires
  - Shows "🔴 API Error: 401" with message "Please run /login"
  - Triggered when both "API Error: 401" and "Please run /login" appear in assistant messages
  - Priority detection (checks before tool-based detection)
  - Added comprehensive tests for API error detection

### Improved
- **Binary size optimization** - 30% smaller release binaries
  - Production builds now use `-ldflags="-s -w" -trimpath` flags
  - Binary size reduced from ~10 MB to ~7 MB per platform
  - Faster download times for users (5 seconds instead of 8 seconds)
  - Better privacy (no developer paths in binaries)
  - Deterministic builds across different machines
  - Development builds unchanged (still include debug symbols)

### Changed
- Updated notification count from 5 to 6 types in README
- All tests passing with new features

## [1.0.3] - 2025-10-24

### Fixed
- Critical bug in duration calculation ("Took" time in notifications)
  - User text messages were not being detected in transcript parsing
  - `GetLastUserTimestamp` now correctly parses string content format
  - Duration now shows accurate time (e.g., "Took 5m" instead of "Took 2h 30m")
  - Tool counting now accurate (prevents showing inflated counts like "Edited 32 files")
- Added custom JSON marshaling/unmarshaling for `MessageContent` to handle both string and array content formats

### Technical Details
- Fixed `pkg/jsonl/jsonl.go`: Added `ContentString` field and custom `UnmarshalJSON`/`MarshalJSON` methods
- User messages with `"content": "text"` format now properly parsed (previously only array format worked)
- All existing tests pass + added new tests for string content parsing

## [1.0.2] - 2025-10-23

### Added
- Linux ARM64 support for Raspberry Pi and other ARM64 Linux systems (#2)
  - Native ARM64 runner (`ubuntu-24.04-arm`) for reliable builds
  - Full audio and notification support via CGO
  - Automatic binary download via `/notifications-init` command

### Fixed
- Webhook configuration validation now only runs when webhooks are enabled (#1)
  - Previously caused "invalid webhook preset: none" error even with webhooks disabled
  - Preset and format validation now conditional on `webhook.enabled` flag

### Changed
- Documentation updates for clarity and platform-specific instructions

## [1.0.1] - 2025-10-22

### Added
- Windows ARM64 binary support
- Windows CMD and PowerShell compatibility improvements

### Fixed
- Plugin installation and hook integration issues
- Plugin manifest command paths
- POSIX-compliant OS detection for better cross-platform support

## [1.0.0] - 2025-10-20

### Added
- Initial release of Claude Notifications plugin
- Cross-platform desktop notifications (macOS, Linux, Windows)
- Smart notification system with 5 types:
  - Task Complete
  - Review Complete
  - Question
  - Plan Ready
  - Session Limit Reached
- State machine analysis for accurate notification detection
- Webhook integrations (Slack, Discord, Telegram, Custom)
- Enterprise-grade webhook features:
  - Retry logic with exponential backoff
  - Circuit breaker for fault tolerance
  - Rate limiting with token bucket algorithm
- Audio notification support (MP3, WAV, FLAC, OGG, AIFF)
- Volume control (0-100%)
- Interactive setup wizards
- Two-phase lock deduplication system
- Friendly session names
- Pre-built binaries for all platforms
- GitHub Releases distribution

### Fixed
- Error handling improvements across webhook and notifier packages
- Data race in error handler
- Question notification cooldown system
- Cross-platform path normalization

[1.0.2]: https://github.com/777genius/claude-notifications-go/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/777genius/claude-notifications-go/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/777genius/claude-notifications-go/releases/tag/v1.0.0
