package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

// TestMainHelp tests that the binary shows help when called without arguments
func TestMainHelp(t *testing.T) {
	// Build the binary first
	tmpDir := t.TempDir()
	binPath := filepath.Join(tmpDir, "sound-preview")

	cmd := exec.Command("go", "build", "-o", binPath, ".")
	cmd.Dir = "."
	if err := cmd.Run(); err != nil {
		t.Fatalf("Failed to build binary: %v", err)
	}

	// Run without arguments - should show usage and exit with code 1
	cmd = exec.Command(binPath)
	output, err := cmd.CombinedOutput()

	// Should exit with error (no file provided)
	if err == nil {
		t.Error("Expected error when running without arguments")
	}

	// Should show usage information
	if !contains(string(output), "Usage:") {
		t.Errorf("Expected usage information in output, got: %s", output)
	}
}

// TestMainWithNonExistentFile tests error handling for missing files
func TestMainWithNonExistentFile(t *testing.T) {
	tmpDir := t.TempDir()
	binPath := filepath.Join(tmpDir, "sound-preview")

	cmd := exec.Command("go", "build", "-o", binPath, ".")
	if err := cmd.Run(); err != nil {
		t.Fatalf("Failed to build binary: %v", err)
	}

	// Run with non-existent file
	cmd = exec.Command(binPath, "/nonexistent/file.mp3")
	output, err := cmd.CombinedOutput()

	if err == nil {
		t.Error("Expected error for non-existent file")
	}

	if !contains(string(output), "not found") {
		t.Errorf("Expected 'not found' error, got: %s", output)
	}
}

// TestMainWithInvalidVolume tests volume validation
func TestMainWithInvalidVolume(t *testing.T) {
	tmpDir := t.TempDir()
	binPath := filepath.Join(tmpDir, "sound-preview")

	cmd := exec.Command("go", "build", "-o", binPath, ".")
	if err := cmd.Run(); err != nil {
		t.Fatalf("Failed to build binary: %v", err)
	}

	// Create a dummy file
	dummyFile := filepath.Join(tmpDir, "test.mp3")
	if err := os.WriteFile(dummyFile, []byte{}, 0644); err != nil {
		t.Fatalf("Failed to create dummy file: %v", err)
	}

	// Run with invalid volume
	cmd = exec.Command(binPath, "--volume", "2.0", dummyFile)
	output, err := cmd.CombinedOutput()

	if err == nil {
		t.Error("Expected error for invalid volume")
	}

	if !contains(string(output), "Volume must be between") {
		t.Errorf("Expected volume validation error, got: %s", output)
	}
}

// TestExtensionDetection tests that file extensions are correctly detected
func TestExtensionDetection(t *testing.T) {
	tests := []struct {
		filename string
		ext      string
	}{
		{"sound.mp3", ".mp3"},
		{"sound.wav", ".wav"},
		{"sound.flac", ".flac"},
		{"sound.ogg", ".ogg"},
		{"sound.aiff", ".aiff"},
		{"sound.aif", ".aif"},
		{"/path/to/sound.mp3", ".mp3"},
	}

	for _, tt := range tests {
		t.Run(tt.filename, func(t *testing.T) {
			ext := filepath.Ext(tt.filename)
			if ext != tt.ext {
				t.Errorf("filepath.Ext(%q) = %q, want %q", tt.filename, ext, tt.ext)
			}
		})
	}
}

// Helper function
func contains(s, substr string) bool {
	for i := 0; i <= len(s)-len(substr); i++ {
		if s[i:i+len(substr)] == substr {
			return true
		}
	}
	return false
}
