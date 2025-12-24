package notifier

import (
	"os"
	"os/exec"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/gen2brain/beeep"

	"github.com/777genius/claude-notifications/internal/analyzer"
	"github.com/777genius/claude-notifications/internal/config"
)

func TestExtractSessionName(t *testing.T) {
	tests := []struct {
		name             string
		message          string
		expectedSession  string
		expectedCleanMsg string
	}{
		{
			name:             "Valid session name with message",
			message:          "[bold-cat] Created 3 files. Edited 2 files. Took 2m 15s",
			expectedSession:  "bold-cat",
			expectedCleanMsg: "Created 3 files. Edited 2 files. Took 2m 15s",
		},
		{
			name:             "Valid session name with short message",
			message:          "[swift-eagle] Task complete",
			expectedSession:  "swift-eagle",
			expectedCleanMsg: "Task complete",
		},
		{
			name:             "Message without session name",
			message:          "Task completed successfully",
			expectedSession:  "",
			expectedCleanMsg: "Task completed successfully",
		},
		{
			name:             "Message with only opening bracket",
			message:          "[no-closing-bracket Task complete",
			expectedSession:  "",
			expectedCleanMsg: "[no-closing-bracket Task complete",
		},
		{
			name:             "Empty message",
			message:          "",
			expectedSession:  "",
			expectedCleanMsg: "",
		},
		{
			name:             "Session name with extra spaces",
			message:          "[cool-fox]   Multiple   spaces   message",
			expectedSession:  "cool-fox",
			expectedCleanMsg: "Multiple   spaces   message",
		},
		{
			name:             "Session name only (no message)",
			message:          "[lonely-wolf]",
			expectedSession:  "lonely-wolf",
			expectedCleanMsg: "",
		},
		{
			name:             "Leading/trailing spaces",
			message:          "  [trim-test] Message with spaces  ",
			expectedSession:  "trim-test",
			expectedCleanMsg: "Message with spaces",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			session, cleanMsg := extractSessionName(tt.message)
			if session != tt.expectedSession {
				t.Errorf("extractSessionName(%q) session = %q, want %q", tt.message, session, tt.expectedSession)
			}
			if cleanMsg != tt.expectedCleanMsg {
				t.Errorf("extractSessionName(%q) cleanMsg = %q, want %q", tt.message, cleanMsg, tt.expectedCleanMsg)
			}
		})
	}
}

func TestSendDesktopRestoresAppName(t *testing.T) {
	// This test verifies that SendDesktop properly restores beeep.AppName
	// after sending a notification, even if the notification fails.

	// Save original AppName
	originalAppName := beeep.AppName
	defer func() {
		beeep.AppName = originalAppName
	}()

	// Set a test value
	testAppName := "test-app-name"
	beeep.AppName = testAppName

	// Create notifier with desktop notifications disabled to skip actual notification
	cfg := config.DefaultConfig()
	cfg.Notifications.Desktop.Enabled = false
	n := New(cfg)

	// Call SendDesktop - should not change AppName since notifications are disabled
	_ = n.SendDesktop(analyzer.StatusTaskComplete, "test message")

	// Verify AppName is unchanged (because we skipped notification)
	if beeep.AppName != testAppName {
		t.Errorf("AppName changed unexpectedly: got %q, want %q", beeep.AppName, testAppName)
	}

	// Now test with enabled notifications (will attempt real notification)
	cfg.Notifications.Desktop.Enabled = true
	beeep.AppName = testAppName

	// This will attempt to send a real notification and may fail in CI,
	// but the important thing is that AppName is restored afterward
	_ = n.SendDesktop(analyzer.StatusTaskComplete, "test message")

	// Verify AppName is restored to testAppName after the defer runs
	if beeep.AppName != testAppName {
		t.Errorf("AppName not restored after SendDesktop: got %q, want %q", beeep.AppName, testAppName)
	}
}

func TestVolumeToGain(t *testing.T) {
	tests := []struct {
		name     string
		volume   float64
		expected float64
	}{
		{"0% volume", 0.0, -1.0},
		{"30% volume", 0.3, -0.7},
		{"50% volume", 0.5, -0.5},
		{"100% volume", 1.0, 0.0},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := volumeToGain(tt.volume)
			if result != tt.expected {
				t.Errorf("volumeToGain(%.1f) = %.1f, want %.1f", tt.volume, result, tt.expected)
			}
		})
	}
}

// === Tests for Click-to-Focus functionality ===

func TestSendDesktop_ClickToFocusDisabled(t *testing.T) {
	// When ClickToFocus is disabled, should use beeep even on macOS
	cfg := config.DefaultConfig()
	cfg.Notifications.Desktop.Enabled = true
	cfg.Notifications.Desktop.ClickToFocus = false
	cfg.Notifications.Desktop.Sound = false // Disable sound for faster test

	n := New(cfg)

	// Should not panic and should use beeep path
	// We can't easily verify which path was taken without mocking,
	// but we can verify it doesn't crash
	err := n.SendDesktop(analyzer.StatusTaskComplete, "[test-session] Task done")
	// Error is acceptable in CI environment where notifications may not work
	_ = err
}

func TestSendDesktop_WithTerminalBundleIDOverride(t *testing.T) {
	cfg := config.DefaultConfig()
	cfg.Notifications.Desktop.Enabled = true
	cfg.Notifications.Desktop.ClickToFocus = true
	cfg.Notifications.Desktop.TerminalBundleID = "com.custom.terminal"
	cfg.Notifications.Desktop.Sound = false

	n := New(cfg)

	// Verify the config is properly set
	if n.cfg.Notifications.Desktop.TerminalBundleID != "com.custom.terminal" {
		t.Errorf("TerminalBundleID not set correctly: got %s", n.cfg.Notifications.Desktop.TerminalBundleID)
	}

	// SendDesktop should work without panic
	err := n.SendDesktop(analyzer.StatusTaskComplete, "Test message")
	_ = err // Error acceptable in CI
}

func TestPlaySoundAsync_Disabled(t *testing.T) {
	cfg := config.DefaultConfig()
	cfg.Notifications.Desktop.Sound = false

	n := New(cfg)

	// Should not start any goroutine when sound is disabled
	n.playSoundAsync("")
	n.playSoundAsync("nonexistent.mp3")

	// Close should complete quickly since no sound was playing
	err := n.Close()
	if err != nil {
		t.Errorf("Close() returned error: %v", err)
	}
}

func TestPlaySoundAsync_EmptyPath(t *testing.T) {
	cfg := config.DefaultConfig()
	cfg.Notifications.Desktop.Sound = true

	n := New(cfg)

	// Empty sound path should not start playback
	n.playSoundAsync("")

	// Close should complete quickly
	err := n.Close()
	if err != nil {
		t.Errorf("Close() returned error: %v", err)
	}
}

func TestSendWithBeeep_RestoresAppName(t *testing.T) {
	cfg := config.DefaultConfig()
	cfg.Notifications.Desktop.Sound = false

	n := New(cfg)

	// Save original AppName
	originalAppName := beeep.AppName
	testAppName := "test-restore-check"
	beeep.AppName = testAppName

	// Call sendWithBeeep
	_ = n.sendWithBeeep("Test Title", "Test Message", "", "")

	// AppName should be restored
	if beeep.AppName != testAppName {
		t.Errorf("AppName not restored: got %q, want %q", beeep.AppName, testAppName)
	}

	// Restore original
	beeep.AppName = originalAppName
}

func TestNotifier_NewWithClickToFocusConfig(t *testing.T) {
	tests := []struct {
		name         string
		clickToFocus bool
		bundleID     string
	}{
		{"ClickToFocus enabled, auto-detect", true, ""},
		{"ClickToFocus enabled, custom bundle", true, "com.custom.app"},
		{"ClickToFocus disabled", false, ""},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cfg := config.DefaultConfig()
			cfg.Notifications.Desktop.ClickToFocus = tt.clickToFocus
			cfg.Notifications.Desktop.TerminalBundleID = tt.bundleID

			n := New(cfg)

			if n.cfg.Notifications.Desktop.ClickToFocus != tt.clickToFocus {
				t.Errorf("ClickToFocus = %v, want %v", n.cfg.Notifications.Desktop.ClickToFocus, tt.clickToFocus)
			}
			if n.cfg.Notifications.Desktop.TerminalBundleID != tt.bundleID {
				t.Errorf("TerminalBundleID = %q, want %q", n.cfg.Notifications.Desktop.TerminalBundleID, tt.bundleID)
			}
		})
	}
}

func TestSendDesktop_AllStatuses(t *testing.T) {
	// Test that all status types work with click-to-focus config
	statuses := []analyzer.Status{
		analyzer.StatusTaskComplete,
		analyzer.StatusReviewComplete,
		analyzer.StatusQuestion,
		analyzer.StatusPlanReady,
		analyzer.StatusSessionLimitReached,
		analyzer.StatusAPIError,
	}

	cfg := config.DefaultConfig()
	cfg.Notifications.Desktop.Enabled = true
	cfg.Notifications.Desktop.ClickToFocus = true
	cfg.Notifications.Desktop.Sound = false // Disable sound for faster tests

	n := New(cfg)

	for _, status := range statuses {
		t.Run(string(status), func(t *testing.T) {
			// Should not panic for any status
			err := n.SendDesktop(status, "[test] Message for "+string(status))
			// Error is acceptable (notifications may not work in CI)
			_ = err
		})
	}
}

func TestSendDesktop_Disabled(t *testing.T) {
	cfg := config.DefaultConfig()
	cfg.Notifications.Desktop.Enabled = false

	n := New(cfg)

	// Should return nil without doing anything
	err := n.SendDesktop(analyzer.StatusTaskComplete, "test message")
	if err != nil {
		t.Errorf("Expected nil error when disabled, got: %v", err)
	}
}

func TestSendDesktop_UnknownStatus(t *testing.T) {
	cfg := config.DefaultConfig()
	cfg.Notifications.Desktop.Enabled = true

	n := New(cfg)

	// Should return error for unknown status
	err := n.SendDesktop(analyzer.Status("unknown_status"), "test message")
	if err == nil {
		t.Error("Expected error for unknown status, got nil")
	}
}

func TestSendDesktop_WithSessionName(t *testing.T) {
	cfg := config.DefaultConfig()
	cfg.Notifications.Desktop.Enabled = true
	cfg.Notifications.Desktop.Sound = false
	cfg.Notifications.Desktop.ClickToFocus = false

	n := New(cfg)

	// Test with session name
	err := n.SendDesktop(analyzer.StatusTaskComplete, "[my-session] Task completed")
	// Error acceptable in CI
	_ = err
}

func TestSendDesktop_WithoutSessionName(t *testing.T) {
	cfg := config.DefaultConfig()
	cfg.Notifications.Desktop.Enabled = true
	cfg.Notifications.Desktop.Sound = false
	cfg.Notifications.Desktop.ClickToFocus = false

	n := New(cfg)

	// Test without session name
	err := n.SendDesktop(analyzer.StatusTaskComplete, "Task completed without session")
	// Error acceptable in CI
	_ = err
}

func TestNotifier_Close_MultipleCallsSafe(t *testing.T) {
	cfg := config.DefaultConfig()
	cfg.Notifications.Desktop.Sound = false

	n := New(cfg)

	// Close should be safe to call multiple times
	err1 := n.Close()
	err2 := n.Close()

	if err1 != nil {
		t.Errorf("First Close() returned error: %v", err1)
	}
	if err2 != nil {
		t.Errorf("Second Close() returned error: %v", err2)
	}
}

func TestNotifier_CloseWithoutPlayback(t *testing.T) {
	cfg := config.DefaultConfig()
	cfg.Notifications.Desktop.Sound = false

	n := New(cfg)

	// Close without any sound playback should complete immediately
	done := make(chan struct{})
	go func() {
		n.Close()
		close(done)
	}()

	select {
	case <-done:
		// Expected
	case <-time.After(time.Second):
		t.Error("Close() took too long")
	}
}

func TestExtractSessionName_MoreCases(t *testing.T) {
	tests := []struct {
		name             string
		message          string
		expectedSession  string
		expectedCleanMsg string
	}{
		{
			name:             "Nested brackets",
			message:          "[outer] message with [inner] brackets",
			expectedSession:  "outer",
			expectedCleanMsg: "message with [inner] brackets",
		},
		{
			name:             "Multiple brackets at start",
			message:          "[first][second] message",
			expectedSession:  "first",
			expectedCleanMsg: "[second] message",
		},
		{
			name:             "Bracket in middle",
			message:          "message [not-session] here",
			expectedSession:  "",
			expectedCleanMsg: "message [not-session] here",
		},
		{
			name:             "Only brackets with text",
			message:          "[]",
			expectedSession:  "",
			expectedCleanMsg: "",
		},
		{
			name:             "Hyphenated session name",
			message:          "[bold-red-fox] Long message here",
			expectedSession:  "bold-red-fox",
			expectedCleanMsg: "Long message here",
		},
		{
			name:             "Underscored session name",
			message:          "[session_with_underscores] Message",
			expectedSession:  "session_with_underscores",
			expectedCleanMsg: "Message",
		},
		{
			name:             "Numeric session name",
			message:          "[session123] Message",
			expectedSession:  "session123",
			expectedCleanMsg: "Message",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			session, cleanMsg := extractSessionName(tt.message)
			if session != tt.expectedSession {
				t.Errorf("extractSessionName(%q) session = %q, want %q", tt.message, session, tt.expectedSession)
			}
			if cleanMsg != tt.expectedCleanMsg {
				t.Errorf("extractSessionName(%q) cleanMsg = %q, want %q", tt.message, cleanMsg, tt.expectedCleanMsg)
			}
		})
	}
}

func TestVolumeToGain_EdgeCases(t *testing.T) {
	tests := []struct {
		name     string
		volume   float64
		expected float64
	}{
		{"Negative volume", -0.5, -1.5},
		{"Volume above 1", 1.5, 0.5},
		{"Very small volume", 0.01, -0.99},
		{"Volume 0.1", 0.1, -0.9},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := volumeToGain(tt.volume)
			if result != tt.expected {
				t.Errorf("volumeToGain(%.2f) = %.2f, want %.2f", tt.volume, result, tt.expected)
			}
		})
	}
}

func TestPlaySoundAsync_WithSoundFile(t *testing.T) {
	cfg := config.DefaultConfig()
	cfg.Notifications.Desktop.Sound = true

	n := New(cfg)

	// Playing nonexistent sound should not panic
	n.playSoundAsync("/nonexistent/path/to/sound.mp3")

	// Wait for goroutine to complete
	n.Close()
}

func TestSendDesktop_ClickToFocusWithBeeepFallback(t *testing.T) {
	cfg := config.DefaultConfig()
	cfg.Notifications.Desktop.Enabled = true
	cfg.Notifications.Desktop.ClickToFocus = true
	cfg.Notifications.Desktop.Sound = false
	cfg.Notifications.Desktop.TerminalBundleID = "" // auto-detect

	n := New(cfg)

	// Should work regardless of terminal-notifier availability
	// Will use terminal-notifier if available, otherwise beeep
	err := n.SendDesktop(analyzer.StatusTaskComplete, "[fallback-test] Testing fallback")
	// Error acceptable in CI where neither may work
	_ = err
}

func TestNotifier_ConfigAccess(t *testing.T) {
	cfg := config.DefaultConfig()
	cfg.Notifications.Desktop.Enabled = true
	cfg.Notifications.Desktop.ClickToFocus = true
	cfg.Notifications.Desktop.TerminalBundleID = "custom.bundle"
	cfg.Notifications.Desktop.Volume = 0.5

	n := New(cfg)

	// Verify config is accessible
	if !n.cfg.Notifications.Desktop.Enabled {
		t.Error("Expected Desktop.Enabled to be true")
	}
	if !n.cfg.Notifications.Desktop.ClickToFocus {
		t.Error("Expected Desktop.ClickToFocus to be true")
	}
	if n.cfg.Notifications.Desktop.TerminalBundleID != "custom.bundle" {
		t.Errorf("Expected TerminalBundleID 'custom.bundle', got '%s'", n.cfg.Notifications.Desktop.TerminalBundleID)
	}
	if n.cfg.Notifications.Desktop.Volume != 0.5 {
		t.Errorf("Expected Volume 0.5, got %f", n.cfg.Notifications.Desktop.Volume)
	}
}

// === Tests for buildTerminalNotifierArgs ===

func TestBuildTerminalNotifierArgs_Basic(t *testing.T) {
	args := buildTerminalNotifierArgs("Test Title", "Test Message", "com.test.app")

	// Check required arguments
	if !containsArg(args, "-title", "Test Title") {
		t.Error("Missing or incorrect -title argument")
	}
	if !containsArg(args, "-message", "Test Message") {
		t.Error("Missing or incorrect -message argument")
	}
	if !containsArg(args, "-activate", "com.test.app") {
		t.Error("Missing or incorrect -activate argument")
	}

	// Note: -sender was removed because it conflicts with -activate on macOS Sequoia

	// Check that -group is present (for deduplication)
	hasGroup := false
	for _, arg := range args {
		if arg == "-group" {
			hasGroup = true
			break
		}
	}
	if !hasGroup {
		t.Error("Missing -group argument")
	}
}

func TestBuildTerminalNotifierArgs_NoSender(t *testing.T) {
	// -sender was removed because it conflicts with -activate on macOS Sequoia (15.x)
	// This test verifies that -sender is NOT present
	args := buildTerminalNotifierArgs("Title", "Message", "com.test.app")

	for _, arg := range args {
		if arg == "-sender" {
			t.Error("-sender should not be present (conflicts with -activate on macOS Sequoia)")
		}
	}
}

func TestBuildTerminalNotifierArgs_SpecialCharacters(t *testing.T) {
	// Test with special characters in title/message
	args := buildTerminalNotifierArgs(
		"Task Complete [session-1]",
		"Created 3 files. Edited 2 files. Took 2m 15s",
		"com.googlecode.iterm2",
	)

	if !containsArg(args, "-title", "Task Complete [session-1]") {
		t.Error("Title with special characters not preserved")
	}
	if !containsArg(args, "-message", "Created 3 files. Edited 2 files. Took 2m 15s") {
		t.Error("Message with special characters not preserved")
	}
}

func TestBuildTerminalNotifierArgs_EmptyValues(t *testing.T) {
	// Test with empty title/message (edge case)
	args := buildTerminalNotifierArgs("", "", "com.test.app")

	if !containsArg(args, "-title", "") {
		t.Error("Empty title should still be present")
	}
	if !containsArg(args, "-message", "") {
		t.Error("Empty message should still be present")
	}
}

func TestBuildTerminalNotifierArgs_UniqueGroupID(t *testing.T) {
	// Two calls should produce different group IDs
	args1 := buildTerminalNotifierArgs("Title", "Msg", "com.test")
	time.Sleep(time.Nanosecond) // Ensure different timestamp
	args2 := buildTerminalNotifierArgs("Title", "Msg", "com.test")

	group1 := getArgValue(args1, "-group")
	group2 := getArgValue(args2, "-group")

	if group1 == "" || group2 == "" {
		t.Error("Group ID should not be empty")
	}
	if group1 == group2 {
		t.Error("Group IDs should be unique between calls")
	}
}

// === Integration test with real terminal-notifier ===

func TestSendWithTerminalNotifier_Integration(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("Skipping macOS-only test")
	}

	// Skip in CI - no NotificationCenter available
	if os.Getenv("CI") != "" || os.Getenv("GITHUB_ACTIONS") != "" {
		t.Skip("Skipping in CI - no NotificationCenter available")
	}

	// Check if terminal-notifier is available
	if !IsTerminalNotifierAvailable() {
		t.Skip("terminal-notifier not installed, skipping integration test")
	}

	cfg := config.DefaultConfig()
	cfg.Notifications.Desktop.Enabled = true
	cfg.Notifications.Desktop.ClickToFocus = true
	cfg.Notifications.Desktop.Sound = false

	n := New(cfg)

	// This will send a real notification - we just verify it doesn't error
	err := n.sendWithTerminalNotifier("Integration Test", "This is a test notification")
	if err != nil {
		t.Errorf("sendWithTerminalNotifier failed: %v", err)
	}
}

func TestTerminalNotifier_CommandExecution(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("Skipping macOS-only test")
	}

	path, err := GetTerminalNotifierPath()
	if err != nil {
		t.Skip("terminal-notifier not installed")
	}

	// Test that terminal-notifier accepts our arguments format
	// Use -help to verify the binary works without sending notification
	cmd := exec.Command(path, "-help")
	output, err := cmd.CombinedOutput()

	// terminal-notifier returns exit code 0 for -help
	// and output should contain usage information
	if err != nil {
		// Some versions may return non-zero for -help, that's ok
		t.Logf("terminal-notifier -help returned: %v (output: %s)", err, string(output))
	}

	// Verify binary is executable
	if len(output) == 0 {
		t.Error("terminal-notifier produced no output")
	}
}

// === Fallback logic tests ===

func TestSendDesktop_FallbackWhenTerminalNotifierFails(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("Skipping macOS-only test")
	}

	cfg := config.DefaultConfig()
	cfg.Notifications.Desktop.Enabled = true
	cfg.Notifications.Desktop.ClickToFocus = true
	cfg.Notifications.Desktop.Sound = false
	// Use invalid bundle ID to test error handling
	cfg.Notifications.Desktop.TerminalBundleID = "com.nonexistent.app.12345"

	n := New(cfg)

	// Should not return error - should fall back to beeep
	err := n.SendDesktop(analyzer.StatusTaskComplete, "[test] Fallback test")
	// Error is acceptable in CI, but should not panic
	_ = err
}

func TestSendDesktop_ClickToFocusDisabledUsesBeeep(t *testing.T) {
	cfg := config.DefaultConfig()
	cfg.Notifications.Desktop.Enabled = true
	cfg.Notifications.Desktop.ClickToFocus = false // Disabled
	cfg.Notifications.Desktop.Sound = false

	n := New(cfg)

	// Should use beeep path even on macOS
	err := n.SendDesktop(analyzer.StatusTaskComplete, "[test] Beeep path test")
	// Error acceptable in CI
	_ = err
}

// === Helper functions ===

func containsArg(args []string, flag, value string) bool {
	for i := 0; i < len(args)-1; i++ {
		if args[i] == flag && args[i+1] == value {
			return true
		}
	}
	return false
}

func getArgValue(args []string, flag string) string {
	for i := 0; i < len(args)-1; i++ {
		if args[i] == flag {
			return args[i+1]
		}
	}
	return ""
}

// === Tests for terminal-notifier argument validation ===

func TestBuildTerminalNotifierArgs_ArgumentOrder(t *testing.T) {
	args := buildTerminalNotifierArgs("Title", "Message", "com.test.app")

	// Verify argument structure: each flag should be followed by its value
	// Note: -sender was removed because it conflicts with -activate on macOS Sequoia
	expectedPairs := map[string]string{
		"-title":    "Title",
		"-message":  "Message",
		"-activate": "com.test.app",
	}

	for flag, expectedValue := range expectedPairs {
		actualValue := getArgValue(args, flag)
		if actualValue != expectedValue {
			t.Errorf("For flag %s: expected %q, got %q", flag, expectedValue, actualValue)
		}
	}
}

func TestBuildTerminalNotifierArgs_NoNilValues(t *testing.T) {
	args := buildTerminalNotifierArgs("Title", "Message", "com.test")

	for i, arg := range args {
		if arg == "" && i > 0 && args[i-1] != "-title" && args[i-1] != "-message" {
			// Empty values are only acceptable for -title and -message
			t.Errorf("Unexpected empty value at index %d after %s", i, args[i-1])
		}
	}
}

func TestBuildTerminalNotifierArgs_GroupIDFormat(t *testing.T) {
	args := buildTerminalNotifierArgs("Title", "Message", "com.test")

	groupID := getArgValue(args, "-group")
	if groupID == "" {
		t.Fatal("Group ID is empty")
	}

	// Group ID should start with "claude-notif-"
	if !strings.HasPrefix(groupID, "claude-notif-") {
		t.Errorf("Group ID should start with 'claude-notif-', got: %s", groupID)
	}
}

// === Additional coverage tests ===

func TestSendWithTerminalNotifier_PathNotFound(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("Skipping macOS-only test")
	}

	// Save and restore CLAUDE_PLUGIN_ROOT
	originalPluginRoot := os.Getenv("CLAUDE_PLUGIN_ROOT")
	defer os.Setenv("CLAUDE_PLUGIN_ROOT", originalPluginRoot)

	// Set invalid plugin root to force path lookup to fail (if system doesn't have it)
	os.Setenv("CLAUDE_PLUGIN_ROOT", "/nonexistent/path/12345")

	cfg := config.DefaultConfig()
	cfg.Notifications.Desktop.Enabled = true
	cfg.Notifications.Desktop.ClickToFocus = true
	cfg.Notifications.Desktop.Sound = false

	n := New(cfg)

	// This may succeed if terminal-notifier is installed system-wide
	// or fail if not - both are valid outcomes
	err := n.sendWithTerminalNotifier("Test", "Message")
	_ = err // We just want to exercise the code path
}

func TestSendDesktop_AppIconNotFound(t *testing.T) {
	cfg := config.DefaultConfig()
	cfg.Notifications.Desktop.Enabled = true
	cfg.Notifications.Desktop.Sound = false
	cfg.Notifications.Desktop.ClickToFocus = false
	cfg.Notifications.Desktop.AppIcon = "/nonexistent/icon/path.png"

	n := New(cfg)

	// Should handle missing icon gracefully
	err := n.SendDesktop(analyzer.StatusTaskComplete, "[test] Icon test")
	// Error acceptable in CI
	_ = err
}

func TestSendDesktop_EmptyMessage(t *testing.T) {
	cfg := config.DefaultConfig()
	cfg.Notifications.Desktop.Enabled = true
	cfg.Notifications.Desktop.Sound = false
	cfg.Notifications.Desktop.ClickToFocus = false

	n := New(cfg)

	// Empty message should still work
	err := n.SendDesktop(analyzer.StatusTaskComplete, "")
	// Error acceptable in CI
	_ = err
}

func TestSendDesktop_VeryLongMessage(t *testing.T) {
	cfg := config.DefaultConfig()
	cfg.Notifications.Desktop.Enabled = true
	cfg.Notifications.Desktop.Sound = false
	cfg.Notifications.Desktop.ClickToFocus = false

	n := New(cfg)

	// Very long message
	longMessage := "[test-session] " + strings.Repeat("This is a very long message. ", 100)
	err := n.SendDesktop(analyzer.StatusTaskComplete, longMessage)
	// Error acceptable in CI
	_ = err
}

func TestSendDesktop_SpecialCharactersInMessage(t *testing.T) {
	cfg := config.DefaultConfig()
	cfg.Notifications.Desktop.Enabled = true
	cfg.Notifications.Desktop.Sound = false
	cfg.Notifications.Desktop.ClickToFocus = false

	n := New(cfg)

	// Message with special characters
	specialMessage := "[test] Message with \"quotes\", 'apostrophes', <brackets>, & ampersand, \n newline"
	err := n.SendDesktop(analyzer.StatusTaskComplete, specialMessage)
	// Error acceptable in CI
	_ = err
}

func TestSendDesktop_UnicodeMessage(t *testing.T) {
	cfg := config.DefaultConfig()
	cfg.Notifications.Desktop.Enabled = true
	cfg.Notifications.Desktop.Sound = false
	cfg.Notifications.Desktop.ClickToFocus = false

	n := New(cfg)

	// Unicode message
	unicodeMessage := "[тест] Сообщение на русском 你好 🎉 émojis"
	err := n.SendDesktop(analyzer.StatusTaskComplete, unicodeMessage)
	// Error acceptable in CI
	_ = err
}

func TestExtractSessionName_Unicode(t *testing.T) {
	tests := []struct {
		message          string
		expectedSession  string
		expectedCleanMsg string
	}{
		{"[тест-сессия] Сообщение", "тест-сессия", "Сообщение"},
		{"[日本語] Japanese text", "日本語", "Japanese text"},
		{"[émoji-🎉] Fun message", "émoji-🎉", "Fun message"},
	}

	for _, tt := range tests {
		session, cleanMsg := extractSessionName(tt.message)
		if session != tt.expectedSession {
			t.Errorf("extractSessionName(%q) session = %q, want %q", tt.message, session, tt.expectedSession)
		}
		if cleanMsg != tt.expectedCleanMsg {
			t.Errorf("extractSessionName(%q) cleanMsg = %q, want %q", tt.message, cleanMsg, tt.expectedCleanMsg)
		}
	}
}

// Note: Concurrent SendDesktop is not tested because beeep.AppName is a global
// variable and the beeep library is not thread-safe. In practice, notifications
// are sent sequentially from hooks, so this is not a real use case.

func TestNotifier_RapidClose(t *testing.T) {
	cfg := config.DefaultConfig()
	cfg.Notifications.Desktop.Sound = false

	// Create and close rapidly multiple times
	for i := 0; i < 10; i++ {
		n := New(cfg)
		_ = n.Close()
	}
}

func TestBuildTerminalNotifierArgs_AllKnownBundleIDs(t *testing.T) {
	// Test with all known bundle IDs from the mapping
	bundleIDs := []string{
		"com.apple.Terminal",
		"com.googlecode.iterm2",
		"dev.warp.Warp-Stable",
		"net.kovidgoyal.kitty",
		"com.mitchellh.ghostty",
		"com.github.wez.wezterm",
		"org.alacritty",
		"co.zeit.hyper",
		"com.microsoft.VSCode",
	}

	for _, bundleID := range bundleIDs {
		args := buildTerminalNotifierArgs("Title", "Message", bundleID)
		actualBundleID := getArgValue(args, "-activate")
		if actualBundleID != bundleID {
			t.Errorf("Bundle ID mismatch: expected %s, got %s", bundleID, actualBundleID)
		}
	}
}
