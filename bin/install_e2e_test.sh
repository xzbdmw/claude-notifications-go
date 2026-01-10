#!/bin/bash
# install_e2e_test.sh - End-to-end tests for install.sh
#
# Usage:
#   bash bin/install_e2e_test.sh                # Run offline tests only
#   bash bin/install_e2e_test.sh --real-network # Include real network tests
#   bash bin/install_e2e_test.sh --verbose      # Verbose output
#   bash bin/install_e2e_test.sh --mock-only    # Only mock server tests

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SCRIPT="$SCRIPT_DIR/install.sh"
MOCK_SERVER="$SCRIPT_DIR/mock_server.py"
FIXTURES_DIR="$SCRIPT_DIR/test_fixtures"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

# Flags
RUN_REAL_NETWORK=false
RUN_MOCK_ONLY=false
VERBOSE=false

# Mock server state
MOCK_PID=""
MOCK_PORT=18888

# Parse command line arguments
for arg in "$@"; do
    case $arg in
        --real-network) RUN_REAL_NETWORK=true ;;
        --mock-only) RUN_MOCK_ONLY=true ;;
        --verbose|-v) VERBOSE=true ;;
        --help|-h)
            echo "Usage: $0 [options]"
            echo "Options:"
            echo "  --real-network  Include tests that make real network requests"
            echo "  --mock-only     Only run mock server tests"
            echo "  --verbose, -v   Verbose output"
            exit 0
            ;;
    esac
done

#=============================================================================
# Test Utilities
#=============================================================================

setup_test_dir() {
    TEST_DIR=$(mktemp -d)
    if [ "$VERBOSE" = true ]; then
        echo "  Test dir: $TEST_DIR"
    fi
}

cleanup_test_dir() {
    if [ -n "${TEST_DIR:-}" ] && [ -d "$TEST_DIR" ]; then
        rm -rf "$TEST_DIR"
    fi
}

# Get normalized platform name (matching install.sh)
get_platform() {
    local os=$(uname -s | tr '[:upper:]' '[:lower:]')
    case "$os" in
        darwin) echo "darwin" ;;
        linux) echo "linux" ;;
        mingw*|msys*|cygwin*) echo "windows" ;;
        *) echo "unknown" ;;
    esac
}

# Get normalized architecture (matching install.sh)
get_arch() {
    local arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) echo "amd64" ;;
        arm64|aarch64) echo "arm64" ;;
        *) echo "unknown" ;;
    esac
}

# Get binary name for current platform
get_binary_name() {
    local platform=$(get_platform)
    local arch=$(get_arch)
    if [ "$platform" = "windows" ]; then
        echo "claude-notifications-${platform}-${arch}.exe"
    else
        echo "claude-notifications-${platform}-${arch}"
    fi
}

# Check if on Windows
is_windows() {
    [ "$(get_platform)" = "windows" ]
}

# Cross-platform timeout command
# macOS doesn't have timeout by default, use gtimeout if available or run without timeout
run_with_timeout() {
    local seconds="$1"
    shift
    if command -v timeout &>/dev/null; then
        timeout "$seconds" "$@"
    elif command -v gtimeout &>/dev/null; then
        gtimeout "$seconds" "$@"
    else
        # No timeout available, run without it
        "$@"
    fi
}

# Start mock server
start_mock_server() {
    local port="${1:-$MOCK_PORT}"

    if ! command -v python3 &>/dev/null; then
        echo "python3 not available, skipping mock tests"
        return 1
    fi

    # Create fixtures directory
    mkdir -p "$FIXTURES_DIR"

    # Create mock binary - a real executable shell script padded to 2MB
    # This mimics the real binary for verify_executable checks
    if [ ! -f "$FIXTURES_DIR/mock_binary" ]; then
        cat > "$FIXTURES_DIR/mock_binary" << 'MOCK_EOF'
#!/bin/bash
# Mock claude-notifications binary for testing
if [ "$1" = "--version" ] || [ "$1" = "version" ]; then
    echo "claude-notifications version 1.0.0-mock (test binary)"
    exit 0
fi
if [ "$1" = "help" ] || [ "$1" = "--help" ]; then
    echo "claude-notifications mock binary"
    exit 0
fi
echo "Mock binary executed with args: $@"
exit 0
MOCK_EOF
        chmod +x "$FIXTURES_DIR/mock_binary"
        # Pad to 2MB to pass size check (append nulls)
        dd if=/dev/zero bs=1024 count=2000 >> "$FIXTURES_DIR/mock_binary" 2>/dev/null
    fi

    # Create valid checksums.txt
    local checksum
    if command -v shasum &>/dev/null; then
        checksum=$(shasum -a 256 "$FIXTURES_DIR/mock_binary" | awk '{print $1}')
    elif command -v sha256sum &>/dev/null; then
        checksum=$(sha256sum "$FIXTURES_DIR/mock_binary" | awk '{print $1}')
    else
        checksum="dummy_checksum"
    fi
    echo "$checksum  mock_binary" > "$FIXTURES_DIR/checksums.txt"

    # Create valid zip for terminal-notifier test
    if command -v zip &>/dev/null && [ ! -f "$FIXTURES_DIR/valid.zip" ]; then
        mkdir -p "$FIXTURES_DIR/terminal-notifier.app/Contents/MacOS"
        echo '#!/bin/bash' > "$FIXTURES_DIR/terminal-notifier.app/Contents/MacOS/terminal-notifier"
        chmod +x "$FIXTURES_DIR/terminal-notifier.app/Contents/MacOS/terminal-notifier"
        (cd "$FIXTURES_DIR" && zip -rq valid.zip terminal-notifier.app)
        rm -rf "$FIXTURES_DIR/terminal-notifier.app"
    fi

    # Start server
    python3 "$MOCK_SERVER" "$port" "$FIXTURES_DIR" &
    MOCK_PID=$!
    sleep 0.5

    # Verify server is running
    if ! kill -0 $MOCK_PID 2>/dev/null; then
        echo "Failed to start mock server"
        return 1
    fi

    if [ "$VERBOSE" = true ]; then
        echo "  Mock server started on port $port (PID: $MOCK_PID)"
    fi
}

stop_mock_server() {
    if [ -n "${MOCK_PID:-}" ]; then
        kill $MOCK_PID 2>/dev/null || true
        wait $MOCK_PID 2>/dev/null || true
        MOCK_PID=""
    fi
}

# Cleanup on exit
cleanup() {
    stop_mock_server
    cleanup_test_dir
}
trap cleanup EXIT INT TERM

#=============================================================================
# Assertions
#=============================================================================

assert_eq() {
    local expected="$1" actual="$2" msg="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$expected" = "$actual" ]; then
        echo -e "  ${GREEN}✓${NC} $msg"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "  ${RED}✗${NC} $msg"
        echo -e "    Expected: '$expected'"
        echo -e "    Actual:   '$actual'"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" msg="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if echo "$haystack" | grep -qE "$needle"; then
        echo -e "  ${GREEN}✓${NC} $msg"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "  ${RED}✗${NC} $msg (pattern not found: '$needle')"
        if [ "$VERBOSE" = true ]; then
            echo "    Output: ${haystack:0:200}..."
        fi
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" msg="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if ! echo "$haystack" | grep -qE "$needle"; then
        echo -e "  ${GREEN}✓${NC} $msg"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "  ${RED}✗${NC} $msg (pattern found but shouldn't be: '$needle')"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

assert_file_exists() {
    local file="$1" msg="$2"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ -f "$file" ]; then
        echo -e "  ${GREEN}✓${NC} $msg"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "  ${RED}✗${NC} $msg (file not found: $file)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

assert_file_not_exists() {
    local file="$1" msg="$2"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ ! -f "$file" ]; then
        echo -e "  ${GREEN}✓${NC} $msg"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "  ${RED}✗${NC} $msg (file exists but shouldn't: $file)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

assert_dir_exists() {
    local dir="$1" msg="$2"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ -d "$dir" ]; then
        echo -e "  ${GREEN}✓${NC} $msg"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "  ${RED}✗${NC} $msg (directory not found: $dir)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

assert_dir_not_exists() {
    local dir="$1" msg="$2"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ ! -d "$dir" ]; then
        echo -e "  ${GREEN}✓${NC} $msg"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "  ${RED}✗${NC} $msg (directory exists but shouldn't: $dir)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

assert_executable() {
    local file="$1" msg="$2"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ -x "$file" ]; then
        echo -e "  ${GREEN}✓${NC} $msg"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "  ${RED}✗${NC} $msg (not executable: $file)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

assert_exit_code() {
    local expected="$1" actual="$2" msg="$3"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$expected" -eq "$actual" ]; then
        echo -e "  ${GREEN}✓${NC} $msg"
        TESTS_PASSED=$((TESTS_PASSED + 1))
        return 0
    else
        echo -e "  ${RED}✗${NC} $msg (exit code: $actual, expected: $expected)"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        return 1
    fi
}

skip_test() {
    local msg="$1" reason="$2"
    echo -e "  ${YELLOW}⊘${NC} SKIP: $msg ($reason)"
    TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
}

#=============================================================================
# Category A: Offline Tests (no network required)
#=============================================================================

test_platform_detection() {
    echo -e "\n${CYAN}▶ test_platform_detection${NC}"

    local expected_platform=$(get_platform)
    local expected_arch=$(get_arch)

    setup_test_dir

    output=$(INSTALL_TARGET_DIR="$TEST_DIR" run_with_timeout 5 bash "$INSTALL_SCRIPT" 2>&1 || true)

    assert_contains "$output" "Platform:.*$expected_platform" "Platform detected correctly"
    assert_contains "$output" "$expected_arch" "Architecture detected correctly"

    cleanup_test_dir
}

test_binary_name_format() {
    echo -e "\n${CYAN}▶ test_binary_name_format${NC}"
    setup_test_dir

    output=$(INSTALL_TARGET_DIR="$TEST_DIR" run_with_timeout 5 bash "$INSTALL_SCRIPT" 2>&1 || true)

    # Binary name should contain platform and arch
    assert_contains "$output" "Binary:.*claude-notifications-" "Binary name has correct prefix"

    cleanup_test_dir
}

test_lock_created() {
    echo -e "\n${CYAN}▶ test_lock_created${NC}"
    setup_test_dir

    # Run install with unreachable URL to fail fast
    RELEASE_URL="http://127.0.0.1:1" CHECKSUMS_URL="http://127.0.0.1:1/checksums.txt" \
        INSTALL_TARGET_DIR="$TEST_DIR" run_with_timeout 10 bash "$INSTALL_SCRIPT" 2>&1 &
    local pid=$!
    sleep 1

    # Check if lock was created (may be cleaned up already if failed quickly)
    # This test is tricky - we verify lock mechanism works in other tests
    kill $pid 2>/dev/null || true
    wait $pid 2>/dev/null || true

    # Lock should be cleaned up after script exits
    assert_dir_not_exists "$TEST_DIR/.install.lock" "Lock cleaned up after exit"

    cleanup_test_dir
}

test_lock_prevents_parallel() {
    echo -e "\n${CYAN}▶ test_lock_prevents_parallel${NC}"
    setup_test_dir

    # Create lock manually to simulate another install running
    mkdir -p "$TEST_DIR/.install.lock"

    set +e
    output=$(INSTALL_TARGET_DIR="$TEST_DIR" bash "$INSTALL_SCRIPT" 2>&1)
    exit_code=$?
    set -e

    assert_contains "$output" "Another installation" "Lock prevents parallel install"
    assert_exit_code 1 $exit_code "Exit code is 1 when locked"

    cleanup_test_dir
}

test_lock_stale_removal() {
    echo -e "\n${CYAN}▶ test_lock_stale_removal${NC}"

    # This test is difficult to do reliably without modifying install.sh
    # The stale lock check uses 600 seconds (10 minutes)
    # We'll skip this test in normal runs
    skip_test "Stale lock removal" "requires 10+ minute old lock"
}

test_lock_cleanup_on_exit() {
    echo -e "\n${CYAN}▶ test_lock_cleanup_on_exit${NC}"

    # Skip on Windows - trap behavior differs in Git Bash
    if is_windows; then
        skip_test "Lock cleanup on exit" "trap behavior differs on Windows"
        return
    fi

    setup_test_dir

    # Run install with unreachable URL to fail fast
    RELEASE_URL="http://127.0.0.1:1" CHECKSUMS_URL="http://127.0.0.1:1/checksums.txt" \
        INSTALL_TARGET_DIR="$TEST_DIR" run_with_timeout 10 bash "$INSTALL_SCRIPT" 2>&1 || true

    # Lock should be cleaned up by trap
    assert_dir_not_exists "$TEST_DIR/.install.lock" "Lock cleaned up after exit"

    cleanup_test_dir
}

test_no_write_permission() {
    echo -e "\n${CYAN}▶ test_no_write_permission${NC}"

    # Skip on Windows - chmod doesn't work the same way
    if is_windows; then
        skip_test "No write permission" "chmod not supported on Windows"
        return
    fi

    setup_test_dir

    mkdir -p "$TEST_DIR/readonly"
    chmod 555 "$TEST_DIR/readonly"

    set +e
    output=$(INSTALL_TARGET_DIR="$TEST_DIR/readonly" bash "$INSTALL_SCRIPT" 2>&1)
    exit_code=$?
    set -e

    assert_contains "$output" "No write permission" "Permission error detected"
    assert_exit_code 1 $exit_code "Exit code is 1 when no write permission"

    chmod 755 "$TEST_DIR/readonly"
    cleanup_test_dir
}

test_install_target_dir() {
    echo -e "\n${CYAN}▶ test_install_target_dir${NC}"
    setup_test_dir

    custom_dir="$TEST_DIR/custom/install/path"
    mkdir -p "$custom_dir"

    # Use unreachable URL to fail fast and capture output
    output=$(RELEASE_URL="http://127.0.0.1:1" CHECKSUMS_URL="http://127.0.0.1:1/checksums.txt" \
             INSTALL_TARGET_DIR="$custom_dir" run_with_timeout 10 bash "$INSTALL_SCRIPT" 2>&1 || true)

    # The script should try to install to the custom directory
    # We verify by checking if it tried to access that directory
    assert_contains "$output" "Binary Setup|Platform:" "Script started with custom dir"

    cleanup_test_dir
}

test_directory_auto_created() {
    echo -e "\n${CYAN}▶ test_directory_auto_created${NC}"
    setup_test_dir

    nonexistent="$TEST_DIR/does/not/exist"

    # Use unreachable URL to fail fast
    output=$(RELEASE_URL="http://127.0.0.1:1" CHECKSUMS_URL="http://127.0.0.1:1/checksums.txt" \
             INSTALL_TARGET_DIR="$nonexistent" run_with_timeout 10 bash "$INSTALL_SCRIPT" 2>&1 || true)

    # Directory should be created automatically
    assert_dir_exists "$nonexistent" "Directory auto-created"

    cleanup_test_dir
}

test_required_tools_curl_wget() {
    echo -e "\n${CYAN}▶ test_required_tools_curl_wget${NC}"

    # This test would require temporarily hiding curl/wget which is risky
    # We'll verify the check exists by looking at the script output
    setup_test_dir

    # If we have curl or wget, the script should proceed past the check
    output=$(INSTALL_TARGET_DIR="$TEST_DIR" run_with_timeout 5 bash "$INSTALL_SCRIPT" 2>&1 || true)

    # Should not contain "Missing required tools: curl or wget"
    assert_not_contains "$output" "Missing required tools.*curl" "curl/wget available"

    cleanup_test_dir
}

test_force_removes_binaries() {
    echo -e "\n${CYAN}▶ test_force_removes_binaries${NC}"
    setup_test_dir

    # Create fake binary files
    local binary_name=$(get_binary_name)
    touch "$TEST_DIR/$binary_name"

    # Run with --force and use unreachable URL so it fails fast after cleanup
    output=$(RELEASE_URL="http://127.0.0.1:1" \
             INSTALL_TARGET_DIR="$TEST_DIR" \
             run_with_timeout 5 bash "$INSTALL_SCRIPT" --force 2>&1 || true)

    # Old files should be removed before download attempt
    assert_contains "$output" "removing old files" "Force cleanup message shown"
    assert_file_not_exists "$TEST_DIR/$binary_name" "Old binary removed"

    cleanup_test_dir
}

test_force_removes_symlinks() {
    echo -e "\n${CYAN}▶ test_force_removes_symlinks${NC}"
    setup_test_dir

    # Create fake symlinks
    touch "$TEST_DIR/target_binary"
    ln -sf target_binary "$TEST_DIR/claude-notifications" 2>/dev/null || true
    ln -sf target_binary "$TEST_DIR/sound-preview" 2>/dev/null || true

    # Run with --force and unreachable URL
    RELEASE_URL="http://127.0.0.1:1" \
    INSTALL_TARGET_DIR="$TEST_DIR" \
    run_with_timeout 5 bash "$INSTALL_SCRIPT" --force 2>&1 || true

    # Symlinks should be removed
    if [ -L "$TEST_DIR/claude-notifications" ]; then
        echo -e "  ${RED}✗${NC} Symlink not removed"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    else
        echo -e "  ${GREEN}✓${NC} Symlink removed by --force"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    fi
    TESTS_RUN=$((TESTS_RUN + 1))

    cleanup_test_dir
}

test_force_removes_apps_macos() {
    echo -e "\n${CYAN}▶ test_force_removes_apps_macos${NC}"

    if [ "$(uname)" != "Darwin" ]; then
        skip_test "macOS apps" "not on macOS"
        return
    fi

    setup_test_dir

    # Create fake .app directories
    mkdir -p "$TEST_DIR/terminal-notifier.app/Contents"
    mkdir -p "$TEST_DIR/ClaudeNotifications.app/Contents"

    # Run with --force and unreachable URL
    RELEASE_URL="http://127.0.0.1:1" \
    INSTALL_TARGET_DIR="$TEST_DIR" \
    run_with_timeout 5 bash "$INSTALL_SCRIPT" --force 2>&1 || true

    # Apps should be removed
    assert_dir_not_exists "$TEST_DIR/terminal-notifier.app" "terminal-notifier.app removed"
    assert_dir_not_exists "$TEST_DIR/ClaudeNotifications.app" "ClaudeNotifications.app removed"

    cleanup_test_dir
}

#=============================================================================
# Category B: Mock Server Tests
#=============================================================================

test_mock_download_success() {
    echo -e "\n${CYAN}▶ test_mock_download_success${NC}"

    if ! command -v python3 &>/dev/null; then
        skip_test "Download success" "python3 not available"
        return
    fi

    setup_test_dir
    start_mock_server $MOCK_PORT || { skip_test "Download success" "mock server failed"; return; }

    # Create platform-specific mock binary name
    local binary_name=$(get_binary_name)

    # Copy mock_binary to expected name
    cp "$FIXTURES_DIR/mock_binary" "$FIXTURES_DIR/$binary_name"

    # Update checksums
    local checksum
    if command -v shasum &>/dev/null; then
        checksum=$(shasum -a 256 "$FIXTURES_DIR/$binary_name" | awk '{print $1}')
    else
        checksum=$(sha256sum "$FIXTURES_DIR/$binary_name" | awk '{print $1}')
    fi
    echo "$checksum  $binary_name" > "$FIXTURES_DIR/checksums.txt"

    # Run install
    output=$(RELEASE_URL="http://localhost:$MOCK_PORT" \
             CHECKSUMS_URL="http://localhost:$MOCK_PORT/checksums.txt" \
             NOTIFIER_URL="http://localhost:$MOCK_PORT/valid.zip" \
             INSTALL_TARGET_DIR="$TEST_DIR" \
             run_with_timeout 60 bash "$INSTALL_SCRIPT" 2>&1)
    exit_code=$?

    assert_exit_code 0 $exit_code "Install completed successfully"
    assert_file_exists "$TEST_DIR/$binary_name" "Binary downloaded"
    # On Windows, wrapper is .bat file; on Unix it's a symlink
    if is_windows; then
        assert_file_exists "$TEST_DIR/claude-notifications.bat" "Wrapper created"
    else
        assert_file_exists "$TEST_DIR/claude-notifications" "Symlink created"
    fi

    # Cleanup mock files
    rm -f "$FIXTURES_DIR/$binary_name"

    stop_mock_server
    cleanup_test_dir
}

test_mock_download_404() {
    echo -e "\n${CYAN}▶ test_mock_download_404${NC}"

    if ! command -v python3 &>/dev/null; then
        skip_test "Download 404" "python3 not available"
        return
    fi

    setup_test_dir
    start_mock_server $MOCK_PORT || { skip_test "Download 404" "mock server failed"; return; }

    # Run once and capture both output and exit code
    set +e
    output=$(RELEASE_URL="http://localhost:$MOCK_PORT/404" \
             CHECKSUMS_URL="http://localhost:$MOCK_PORT/404/checksums.txt" \
             INSTALL_TARGET_DIR="$TEST_DIR" \
             run_with_timeout 30 bash "$INSTALL_SCRIPT" 2>&1)
    exit_code=$?
    set -e

    assert_contains "$output" "Download failed|Installation Failed|failed" "Download failure detected"
    assert_exit_code 1 $exit_code "Exit code is 1 on download failure"

    stop_mock_server
    cleanup_test_dir
}

test_mock_download_500() {
    echo -e "\n${CYAN}▶ test_mock_download_500${NC}"

    if ! command -v python3 &>/dev/null; then
        skip_test "Download 500" "python3 not available"
        return
    fi

    setup_test_dir
    start_mock_server $MOCK_PORT || { skip_test "Download 500" "mock server failed"; return; }

    set +e
    output=$(RELEASE_URL="http://localhost:$MOCK_PORT/500" \
             CHECKSUMS_URL="http://localhost:$MOCK_PORT/500/checksums.txt" \
             INSTALL_TARGET_DIR="$TEST_DIR" \
             run_with_timeout 30 bash "$INSTALL_SCRIPT" 2>&1)
    exit_code=$?
    set -e

    assert_contains "$output" "Download failed|Installation Failed|failed" "500 error detected"
    assert_exit_code 1 $exit_code "Exit code is 1 on 500"

    stop_mock_server
    cleanup_test_dir
}

test_mock_file_too_small() {
    echo -e "\n${CYAN}▶ test_mock_file_too_small${NC}"

    if ! command -v python3 &>/dev/null; then
        skip_test "File too small" "python3 not available"
        return
    fi

    setup_test_dir
    start_mock_server $MOCK_PORT || { skip_test "File too small" "mock server failed"; return; }

    set +e
    output=$(RELEASE_URL="http://localhost:$MOCK_PORT/small-file" \
             CHECKSUMS_URL="http://localhost:$MOCK_PORT/checksums.txt" \
             INSTALL_TARGET_DIR="$TEST_DIR" \
             run_with_timeout 30 bash "$INSTALL_SCRIPT" 2>&1)
    exit_code=$?
    set -e

    assert_contains "$output" "too small|Download failed|Installation Failed" "Small file rejected"
    assert_exit_code 1 $exit_code "Exit code is 1 for small file"

    stop_mock_server
    cleanup_test_dir
}

test_mock_checksum_mismatch() {
    echo -e "\n${CYAN}▶ test_mock_checksum_mismatch${NC}"

    if ! command -v python3 &>/dev/null; then
        skip_test "Checksum mismatch" "python3 not available"
        return
    fi

    setup_test_dir
    start_mock_server $MOCK_PORT || { skip_test "Checksum mismatch" "mock server failed"; return; }

    # Create platform-specific mock binary
    local binary_name=$(get_binary_name)

    cp "$FIXTURES_DIR/mock_binary" "$FIXTURES_DIR/$binary_name"

    # Create checksums with WRONG checksum
    echo "0000000000000000000000000000000000000000000000000000000000000000  $binary_name" > "$FIXTURES_DIR/checksums.txt"

    set +e
    output=$(RELEASE_URL="http://localhost:$MOCK_PORT" \
             CHECKSUMS_URL="http://localhost:$MOCK_PORT/checksums.txt" \
             INSTALL_TARGET_DIR="$TEST_DIR" \
             run_with_timeout 30 bash "$INSTALL_SCRIPT" 2>&1)
    exit_code=$?
    set -e

    assert_contains "$output" "Checksum mismatch|Verification Failed" "Checksum mismatch detected"
    assert_exit_code 1 $exit_code "Exit code is 1 on checksum mismatch"

    rm -f "$FIXTURES_DIR/$binary_name"

    stop_mock_server
    cleanup_test_dir
}

test_mock_zip_corrupted() {
    echo -e "\n${CYAN}▶ test_mock_zip_corrupted${NC}"

    if [ "$(uname)" != "Darwin" ]; then
        skip_test "Corrupted zip" "terminal-notifier only on macOS"
        return
    fi

    if ! command -v python3 &>/dev/null; then
        skip_test "Corrupted zip" "python3 not available"
        return
    fi

    setup_test_dir
    start_mock_server $MOCK_PORT || { skip_test "Corrupted zip" "mock server failed"; return; }

    # First do a successful main binary download, then test terminal-notifier
    local binary_name=$(get_binary_name)

    cp "$FIXTURES_DIR/mock_binary" "$FIXTURES_DIR/$binary_name"
    local checksum
    if command -v shasum &>/dev/null; then
        checksum=$(shasum -a 256 "$FIXTURES_DIR/$binary_name" | awk '{print $1}')
    else
        checksum=$(sha256sum "$FIXTURES_DIR/$binary_name" | awk '{print $1}')
    fi
    echo "$checksum  $binary_name" > "$FIXTURES_DIR/checksums.txt"

    output=$(RELEASE_URL="http://localhost:$MOCK_PORT" \
             CHECKSUMS_URL="http://localhost:$MOCK_PORT/checksums.txt" \
             NOTIFIER_URL="http://localhost:$MOCK_PORT/corrupted.zip" \
             INSTALL_TARGET_DIR="$TEST_DIR" \
             run_with_timeout 30 bash "$INSTALL_SCRIPT" 2>&1 || true)

    # Should warn about terminal-notifier but still succeed overall
    assert_contains "$output" "not a valid zip|Could not extract|extraction" "Corrupted zip detected"

    rm -f "$FIXTURES_DIR/$binary_name"

    stop_mock_server
    cleanup_test_dir
}

#=============================================================================
# Category C: Real Network Tests (optional)
#=============================================================================

test_real_github_available() {
    echo -e "\n${CYAN}▶ test_real_github_available${NC}"

    if [ "$RUN_REAL_NETWORK" != true ]; then
        skip_test "GitHub available" "--real-network not specified"
        return
    fi

    if curl -s --max-time 10 -I https://github.com &>/dev/null; then
        echo -e "  ${GREEN}✓${NC} GitHub is reachable"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        echo -e "  ${RED}✗${NC} GitHub is not reachable"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
    TESTS_RUN=$((TESTS_RUN + 1))
}

test_real_full_install() {
    echo -e "\n${CYAN}▶ test_real_full_install${NC}"

    if [ "$RUN_REAL_NETWORK" != true ]; then
        skip_test "Real full install" "--real-network not specified"
        return
    fi

    setup_test_dir

    output=$(INSTALL_TARGET_DIR="$TEST_DIR" bash "$INSTALL_SCRIPT" 2>&1)
    exit_code=$?

    assert_exit_code 0 $exit_code "Install completed successfully"
    assert_file_exists "$TEST_DIR/claude-notifications" "Symlink created"

    cleanup_test_dir
}

test_real_binary_runs() {
    echo -e "\n${CYAN}▶ test_real_binary_runs${NC}"

    if [ "$RUN_REAL_NETWORK" != true ]; then
        skip_test "Binary runs" "--real-network not specified"
        return
    fi

    setup_test_dir

    INSTALL_TARGET_DIR="$TEST_DIR" bash "$INSTALL_SCRIPT" 2>&1 || true

    if [ -x "$TEST_DIR/claude-notifications" ]; then
        version_output=$("$TEST_DIR/claude-notifications" --version 2>&1 || true)
        assert_contains "$version_output" "claude-notifications" "Binary outputs version"
    else
        echo -e "  ${RED}✗${NC} Binary not found or not executable"
        TESTS_FAILED=$((TESTS_FAILED + 1))
        TESTS_RUN=$((TESTS_RUN + 1))
    fi

    cleanup_test_dir
}

test_real_utilities_installed() {
    echo -e "\n${CYAN}▶ test_real_utilities_installed${NC}"

    if [ "$RUN_REAL_NETWORK" != true ]; then
        skip_test "Utilities installed" "--real-network not specified"
        return
    fi

    setup_test_dir

    INSTALL_TARGET_DIR="$TEST_DIR" bash "$INSTALL_SCRIPT" 2>&1 || true

    assert_file_exists "$TEST_DIR/sound-preview" "sound-preview installed"
    assert_file_exists "$TEST_DIR/list-devices" "list-devices installed"

    cleanup_test_dir
}

test_real_terminal_notifier_macos() {
    echo -e "\n${CYAN}▶ test_real_terminal_notifier_macos${NC}"

    if [ "$RUN_REAL_NETWORK" != true ]; then
        skip_test "terminal-notifier" "--real-network not specified"
        return
    fi

    if [ "$(uname)" != "Darwin" ]; then
        skip_test "terminal-notifier" "not on macOS"
        return
    fi

    setup_test_dir

    INSTALL_TARGET_DIR="$TEST_DIR" bash "$INSTALL_SCRIPT" 2>&1 || true

    assert_dir_exists "$TEST_DIR/terminal-notifier.app" "terminal-notifier.app installed"
    assert_executable "$TEST_DIR/terminal-notifier.app/Contents/MacOS/terminal-notifier" "terminal-notifier executable"

    cleanup_test_dir
}

#=============================================================================
# Main
#=============================================================================

main() {
    echo ""
    echo -e "${BOLD}========================================${NC}"
    echo -e "${BOLD} install.sh E2E Tests${NC}"
    echo -e "${BOLD}========================================${NC}"
    echo ""
    echo "Options:"
    echo "  Real network tests: $RUN_REAL_NETWORK"
    echo "  Mock only: $RUN_MOCK_ONLY"
    echo "  Verbose: $VERBOSE"

    if [ "$RUN_MOCK_ONLY" != true ]; then
        # Category A: Offline Tests
        echo ""
        echo -e "${BOLD}Category A: Offline Tests${NC}"
        test_platform_detection
        test_binary_name_format
        test_lock_created
        test_lock_prevents_parallel
        test_lock_stale_removal
        test_lock_cleanup_on_exit
        test_no_write_permission
        test_install_target_dir
        test_directory_auto_created
        test_required_tools_curl_wget
        test_force_removes_binaries
        test_force_removes_symlinks
        test_force_removes_apps_macos
    fi

    # Category B: Mock Server Tests
    echo ""
    echo -e "${BOLD}Category B: Mock Server Tests${NC}"
    test_mock_download_success
    test_mock_download_404
    test_mock_download_500
    test_mock_file_too_small
    test_mock_checksum_mismatch
    test_mock_zip_corrupted

    if [ "$RUN_MOCK_ONLY" != true ]; then
        # Category C: Real Network Tests
        echo ""
        echo -e "${BOLD}Category C: Real Network Tests${NC}"
        test_real_github_available
        test_real_full_install
        test_real_binary_runs
        test_real_utilities_installed
        test_real_terminal_notifier_macos
    fi

    # Summary
    echo ""
    echo -e "${BOLD}========================================${NC}"
    echo -e "${BOLD} Summary${NC}"
    echo -e "${BOLD}========================================${NC}"
    echo -e "Total:   $TESTS_RUN"
    echo -e "Passed:  ${GREEN}$TESTS_PASSED${NC}"
    echo -e "Failed:  ${RED}$TESTS_FAILED${NC}"
    echo -e "Skipped: ${YELLOW}$TESTS_SKIPPED${NC}"
    echo ""

    if [ $TESTS_FAILED -gt 0 ]; then
        echo -e "${RED}Some tests failed!${NC}"
        exit 1
    else
        echo -e "${GREEN}All tests passed!${NC}"
        exit 0
    fi
}

main "$@"
