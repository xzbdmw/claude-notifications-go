# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.11.0] - 2026-01-11

### Added
- **Auto-download after plugin auto-update** - binaries now download automatically when hook is first called
  - Previously: after Claude auto-updated the plugin, binary was missing and hooks failed
  - Now: `hook-wrapper.sh` detects missing binary and triggers download on first use
  - Zero downtime: if download fails, hooks exit gracefully without blocking Claude
  - POSIX-compatible wrapper works on macOS, Linux, and Windows (Git Bash)

### Technical
- New `bin/hook-wrapper.sh` - lazy binary download wrapper
- Updated `hooks/hooks.json` - all hooks now use wrapper
- 17 new E2E tests for hook-wrapper covering offline, mock, and real network scenarios

## [1.10.0] - 2026-01-10

### Added
- **`notifyOnTextResponse` config option** - notifications now arrive for text-only responses (e.g., extended thinking "Baked for 32s")
  - Default: `true` (enabled)
  - Set to `false` in config to disable notifications when Claude responds without using tools

### Fixed
- Fixed test flakiness on Go 1.25+ by cleaning up stale state files between test runs

## [1.9.0] - 2026-01-10

### Added
- **Windows CI tests** - install.sh now tested on all 3 platforms (macOS, Linux, Windows)
- **Binary execution verification** - installer now verifies downloaded binary actually runs (`--version` check)
- **Network error diagnostics** - detailed hints for DNS, SSL, timeout, and firewall issues
- **Graceful offline mode** - if GitHub is unreachable but binary exists, uses existing installation

### Improved
- **Cross-platform compatibility** for install.sh:
  - Windows-compatible `ping` syntax (`-n/-w` instead of `-c/-W`)
  - Portable temp directory (`${TMPDIR:-${TEMP:-/tmp}}`)
  - Proper `.bat` wrapper creation on Windows
  - Extended regex with `grep -E` for portability
- **E2E test coverage** - 35+ tests covering offline, mock server, and real network scenarios
- **Utility downloads are now non-blocking** - if sound-preview or list-devices fail, main install continues

### Fixed
- Fixed installer hanging when optional utility downloads fail
- Fixed checksum verification for cross-platform builds

## [1.8.0] - 2026-01-10

### Added
- **double-shot-latte compatibility** 🤝
  - Notifications are now automatically suppressed when running in background judge mode
  - Detects `CLAUDE_HOOK_JUDGE_MODE=true` environment variable set by [double-shot-latte](https://github.com/obra/double-shot-latte) plugin
  - Zero configuration required - just update the plugin and it works automatically
  - Other plugin developers can use the same mechanism to suppress notifications in background Claude instances

### Documentation
- Added **🤝 Plugin Compatibility** section to README
- Documented how other plugins can suppress notifications using `CLAUDE_HOOK_JUDGE_MODE=true`

## [1.7.2] - 2026-01-10

### Improved
- **Auto-update now always works** - `/claude-notifications-go:notifications-init` reliably updates binaries even from old cached plugins
  - Downloads latest `install.sh` directly from GitHub before running
  - Uses `--force` flag to replace existing binaries
  - Cross-platform temp directory (`$TMPDIR`, `$TEMP`, `/tmp` fallback)
  - Fixes: old cached plugins used outdated installer without utility download support

## [1.7.1] - 2026-01-10

### Fixed
- **Installer now downloads utility binaries** ([#14](https://github.com/777genius/claude-notifications-go/issues/14))
  - `sound-preview` and `list-devices` were missing after `/claude-notifications-go:notifications-init`
  - Installer script now downloads all three binaries
  - Creates proper symlinks for all utilities

## [1.7.0] - 2026-01-10

### Added
- **Audio device selection support** 🔊 (thanks @tkaufmann!)
  - Route notification sounds to a specific audio output device
  - New `audioDevice` config option in `notifications.desktop` section
  - New `list-devices` CLI tool to enumerate available audio devices
  - New `--device` flag for `sound-preview` utility

### Changed
- **Audio backend replacement** - Replaced `oto/v3` (beep/speaker) with `malgo` (miniaudio bindings)
  - Better cross-platform audio support
  - Native device enumeration and selection
  - More reliable playback on all platforms

### Fixed
- **Windows CI test failures** - Fixed `.exe` extension handling in cross-platform tests
- **Memory safety** - DeviceID now properly copied instead of storing pointer to freed memory
- **Player state check** - Play() now returns error if player is already closed
- **WaitGroup race condition** - Added `closing` flag to prevent race between Close() and playSoundAsync()
- **CI test resilience** - Audio tests now skip gracefully in CI environments without audio backend

## [1.6.6] - 2026-01-10

### Fixed
- **Ghost notifications after 60 seconds** 👻 ([#11](https://github.com/777genius/claude-notifications-go/issues/11))
  - `idle_prompt` hook was firing 60 seconds after `PreToolUse(AskUserQuestion)`
  - This caused duplicate "Question" notifications with delay
  - Now Notification hook only responds to `permission_prompt`, ignoring `idle_prompt`
  - `AskUserQuestion` is already covered by PreToolUse hook (instant notification)

## [1.6.5] - 2025-12-31

### Fixed
- **Proper Unicode handling for multibyte characters** 🌍 (thanks @patrick-fu!)
  - Text truncation now uses rune count instead of byte count
  - Emoji, CJK, Cyrillic and other multibyte characters no longer get cut mid-character
  - `truncateText` and `extractFirstSentence` work correctly with international text

## [1.6.4] - 2025-12-31

### Fixed
- **CI tests now pass in GitHub Actions** 🧪
  - `TestGetGitBranch_RealRepo` failed in CI due to detached HEAD from PR checkout
  - Now uses isolated temporary git repository with known branch name
  - Added `TestGetGitBranch_DetachedHead` to verify empty string for detached HEAD

## [1.6.3] - 2025-12-26

### Fixed
- **Fixed fallback logic in content lock** 🔒
  - v1.6.2 had a bug: when lock was busy, code still proceeded without lock
  - Now correctly exits when another process holds the lock
  - Only uses fallback on actual errors (e.g., /tmp unavailable)

## [1.6.2] - 2025-12-26

### Fixed
- **Race condition in content-based deduplication** 🔒
  - Stop and Notification hooks were running simultaneously, both passing duplicate check
  - Added shared content lock to serialize duplicate check and state update
  - Now only one hook can check and save notification state at a time
  - Prevents duplicate notifications when different hooks fire near-simultaneously

## [1.6.1] - 2025-12-26

### Fixed
- **Version numbers no longer break sentence extraction** 🔧
  - Text like "Бинарник v1.6.0 установлен!" was incorrectly cut at "v1."
  - Now correctly handles version numbers, decimals, IP addresses
  - Dots after digits are no longer treated as sentence endings

## [1.6.0] - 2025-12-26

### Added
- **Folder name in notification titles** 📁
  - Notification titles now show the project folder name
  - Format: `✅ Completed [session-name] main my-project`
  - Helps identify which project the notification is from

- **Content-based duplicate detection** 🔇
  - Prevents duplicate notifications with similar text within 3 minutes
  - Normalizes messages (ignores trailing dots, case differences)
  - Example: "Completed" and "Question" with same text won't both show
  - Fixes issue where different hooks sent near-identical notifications

## [1.5.0] - 2025-12-25

### Added
- **Git branch name in notifications** 🌿
  - Notification titles now show the current git branch
  - Format: `✅ Completed [session-name] main`
  - Only shown when working in a git repository

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
  - Automatic binary download via `/claude-notifications-go:notifications-init` command

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
