package notifier

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/gen2brain/beeep"

	"github.com/777genius/claude-notifications/internal/analyzer"
	"github.com/777genius/claude-notifications/internal/config"
	"github.com/777genius/claude-notifications/internal/logging"
	"github.com/777genius/claude-notifications/internal/platform"
)

// Notifier sends desktop notifications
type Notifier struct {
	cfg *config.Config
}

// New creates a new notifier
func New(cfg *config.Config) *Notifier {
	return &Notifier{
		cfg: cfg,
	}
}

// SendDesktop sends a desktop notification using the configured method
// Methods: "osc9", "terminal-notifier", "beeep", "auto" (default)
// On macOS with clickToFocus enabled and method=auto, uses terminal-notifier for click-to-focus support
func (n *Notifier) SendDesktop(status analyzer.Status, message string) error {
	if !n.cfg.IsDesktopEnabled() {
		logging.Debug("Desktop notifications disabled, skipping")
		return nil
	}

	statusInfo, exists := n.cfg.GetStatusInfo(string(status))
	if !exists {
		return fmt.Errorf("unknown status: %s", status)
	}

	// Extract session name and git branch from message
	// Format: "[session-name|branch] actual message" or "[session-name] actual message"
	sessionName, gitBranch, cleanMessage := extractSessionInfo(message)

	// Build proper title with session name and git branch
	// Format: "✅ Completed [brave-ocean] main" or "✅ Completed [brave-ocean]"
	title := statusInfo.Title
	if sessionName != "" {
		if gitBranch != "" {
			title = fmt.Sprintf("%s [%s] %s", title, sessionName, gitBranch)
		} else {
			title = fmt.Sprintf("%s [%s]", title, sessionName)
		}
	}

	// Get app icon path if configured
	appIcon := n.cfg.Notifications.Desktop.AppIcon
	if appIcon != "" && !platform.FileExists(appIcon) {
		logging.Warn("App icon not found: %s, using default", appIcon)
		appIcon = ""
	}

	method := n.cfg.Notifications.Desktop.Method

	// Handle explicit method selection
	switch method {
	case "osc9":
		// OSC9: Terminal escape sequence notification (iTerm2, kitty, etc.)
		return n.sendWithOSC9(title, cleanMessage)

	case "terminal-notifier":
		// terminal-notifier: macOS only with click-to-focus
		if platform.IsMacOS() && IsTerminalNotifierAvailable() {
			if err := n.sendWithTerminalNotifier(title, cleanMessage); err != nil {
				logging.Warn("terminal-notifier failed, falling back to beeep: %v", err)
				return n.sendWithBeeep(title, cleanMessage, appIcon)
			}
			return nil
		}
		logging.Debug("terminal-notifier not available or not on macOS, falling back to beeep")
		return n.sendWithBeeep(title, cleanMessage, appIcon)

	case "beeep":
		// beeep: Cross-platform desktop notifications
		return n.sendWithBeeep(title, cleanMessage, appIcon)

	default:
		// "auto" or "": Use smart defaults
		// macOS: Try terminal-notifier for click-to-focus support
		if platform.IsMacOS() && n.cfg.Notifications.Desktop.ClickToFocus {
			if IsTerminalNotifierAvailable() {
				if err := n.sendWithTerminalNotifier(title, cleanMessage); err != nil {
					logging.Warn("terminal-notifier failed, falling back to beeep: %v", err)
					// Fall through to beeep
				} else {
					logging.Debug("Desktop notification sent via terminal-notifier: title=%s", title)
					return nil
				}
			} else {
				logging.Debug("terminal-notifier not available, using beeep (run /claude-notifications-go:notifications-init to enable click-to-focus)")
			}
		}

		// Standard path: beeep (Windows, Linux, macOS fallback)
		return n.sendWithBeeep(title, cleanMessage, appIcon)
	}
}

// sendWithTerminalNotifier sends notification via terminal-notifier on macOS
// with click-to-focus support (clicking notification activates the terminal)
func (n *Notifier) sendWithTerminalNotifier(title, message string) error {
	notifierPath, err := GetTerminalNotifierPath()
	if err != nil {
		return fmt.Errorf("terminal-notifier not found: %w", err)
	}

	bundleID := GetTerminalBundleID(n.cfg.Notifications.Desktop.TerminalBundleID)
	args := buildTerminalNotifierArgs(title, message, bundleID)

	cmd := exec.Command(notifierPath, args...)

	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("terminal-notifier error: %w, output: %s", err, string(output))
	}

	logging.Debug("terminal-notifier executed: bundleID=%s", bundleID)
	return nil
}

// buildTerminalNotifierArgs constructs command-line arguments for terminal-notifier.
// Exported for testing purposes.
func buildTerminalNotifierArgs(title, message, bundleID string) []string {
	args := []string{
		"-title", title,
		"-message", message,
		"-activate", bundleID,
		// Note: -sender option removed because it conflicts with -activate on macOS Sequoia (15.x)
		// Using -sender causes click-to-focus to stop working.
		// Trade-off: no custom Claude icon, but click-to-focus works reliably.
	}

	// Add group ID to prevent notification stacking issues
	args = append(args, "-group", fmt.Sprintf("claude-notif-%d", time.Now().UnixNano()))

	return args
}

// sendWithBeeep sends notification via beeep (cross-platform)
func (n *Notifier) sendWithBeeep(title, message, appIcon string) error {
	// Platform-specific AppName handling:
	// - Windows: Use fixed AppName to prevent registry pollution. Each unique AppName
	//   creates a persistent entry in HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\
	//   CurrentVersion\Notifications\Settings\ that is never cleaned up.
	//   See: https://github.com/777genius/claude-notifications-go/issues/4
	// - macOS/Linux: Use unique AppName to prevent notification grouping/replacement,
	//   allowing multiple notifications to be displayed simultaneously.
	originalAppName := beeep.AppName
	if platform.IsWindows() {
		beeep.AppName = "Claude Code Notifications"
	} else {
		beeep.AppName = fmt.Sprintf("claude-notif-%d", time.Now().UnixNano())
	}
	defer func() {
		beeep.AppName = originalAppName
	}()

	// Send notification using beeep with proper title and clean message
	if err := beeep.Notify(title, message, appIcon); err != nil {
		logging.Error("Failed to send desktop notification: %v", err)
		return err
	}

	logging.Debug("Desktop notification sent via beeep: title=%s", title)
	return nil
}

// sendWithOSC9 sends notification via OSC9 escape sequence
// OSC9 is supported by terminals like iTerm2, kitty, and others
// Format: ESC ] 9 ; message BEL or ESC ] 9 ; message ESC \
func (n *Notifier) sendWithOSC9(title, message string) error {
	// Combine title and message for OSC9
	notifyText := title
	if message != "" {
		notifyText = fmt.Sprintf("%s: %s", title, message)
	}

	// Truncate to prevent overly long notifications
	if len(notifyText) > 200 {
		notifyText = notifyText[:197] + "..."
	}

	// Write OSC9 escape sequence to /dev/tty
	// Format: ESC ] 9 ; message ESC \
	tty, err := os.OpenFile("/dev/tty", os.O_WRONLY, 0)
	if err != nil {
		logging.Error("Failed to open /dev/tty for OSC9: %v", err)
		return fmt.Errorf("failed to open /dev/tty: %w", err)
	}
	defer tty.Close()

	// OSC9 sequence: \033]9;message\033\\
	osc9 := fmt.Sprintf("\033]9;%s\033\\", notifyText)
	if _, err := tty.WriteString(osc9); err != nil {
		logging.Error("Failed to write OSC9 sequence: %v", err)
		return fmt.Errorf("failed to write OSC9: %w", err)
	}

	logging.Debug("Desktop notification sent via OSC9: title=%s", title)
	return nil
}

// Close is a no-op (kept for interface compatibility)
func (n *Notifier) Close() error {
	return nil
}

// extractSessionInfo extracts session name and git branch from message
// Format: "[session-name|branch] message" or "[session-name] message"
// Returns session name, git branch (may be empty), and clean message
func extractSessionInfo(message string) (sessionName, gitBranch, cleanMessage string) {
	message = strings.TrimSpace(message)

	// Check if message starts with [
	if !strings.HasPrefix(message, "[") {
		return "", "", message
	}

	// Find closing bracket
	closingIdx := strings.Index(message, "]")
	if closingIdx == -1 {
		return "", "", message
	}

	// Extract content inside brackets
	bracketContent := message[1:closingIdx]

	// Check if there's a pipe separator for git branch
	if pipeIdx := strings.Index(bracketContent, "|"); pipeIdx != -1 {
		sessionName = bracketContent[:pipeIdx]
		gitBranch = bracketContent[pipeIdx+1:]
	} else {
		sessionName = bracketContent
		gitBranch = ""
	}

	// Extract clean message (everything after "] ")
	cleanMessage = strings.TrimSpace(message[closingIdx+1:])

	return sessionName, gitBranch, cleanMessage
}
