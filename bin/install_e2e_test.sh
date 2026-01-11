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

pass_test() {
    local msg="$1"
    TESTS_RUN=$((TESTS_RUN + 1))
    echo -e "  ${GREEN}✓${NC} $msg"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

fail_test() {
    local msg="$1" detail="$2"
    TESTS_RUN=$((TESTS_RUN + 1))
    echo -e "  ${RED}✗${NC} $msg ($detail)"
    TESTS_FAILED=$((TESTS_FAILED + 1))
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

    # Skip on Windows - trap/lock behavior differs in Git Bash
    if is_windows; then
        skip_test "Lock created" "trap behavior differs on Windows"
        return
    fi

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
    # On Windows, wrapper is .bat file; on Unix it's a symlink
    if is_windows; then
        assert_file_exists "$TEST_DIR/claude-notifications.bat" "Wrapper created"
    else
        assert_file_exists "$TEST_DIR/claude-notifications" "Symlink created"
    fi

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

    # Determine correct binary/wrapper path
    local binary_path
    if is_windows; then
        binary_path="$TEST_DIR/claude-notifications.bat"
    else
        binary_path="$TEST_DIR/claude-notifications"
    fi

    if [ -f "$binary_path" ]; then
        version_output=$("$binary_path" --version 2>&1 || true)
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

    # On Windows, utilities use .bat wrappers
    if is_windows; then
        assert_file_exists "$TEST_DIR/sound-preview.bat" "sound-preview installed"
        assert_file_exists "$TEST_DIR/list-devices.bat" "list-devices installed"
    else
        assert_file_exists "$TEST_DIR/sound-preview" "sound-preview installed"
        assert_file_exists "$TEST_DIR/list-devices" "list-devices installed"
    fi

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
# Category D: Hook Wrapper Tests (Offline)
#=============================================================================

test_hook_wrapper_exists() {
    echo -e "\n${CYAN}▶ test_hook_wrapper_exists${NC}"

    assert_file_exists "$SCRIPT_DIR/hook-wrapper.sh" "hook-wrapper.sh exists"
}

test_hook_wrapper_is_executable() {
    echo -e "\n${CYAN}▶ test_hook_wrapper_is_executable${NC}"

    assert_executable "$SCRIPT_DIR/hook-wrapper.sh" "hook-wrapper.sh is executable"
}

test_hook_wrapper_posix_syntax() {
    echo -e "\n${CYAN}▶ test_hook_wrapper_posix_syntax${NC}"

    # Check that wrapper uses #!/bin/sh (POSIX), not #!/bin/bash
    first_line=$(head -n1 "$SCRIPT_DIR/hook-wrapper.sh")
    if echo "$first_line" | grep -q "#!/bin/sh"; then
        pass_test "Wrapper uses POSIX #!/bin/sh shebang"
    else
        fail_test "Wrapper uses POSIX #!/bin/sh shebang" "Found: $first_line"
    fi
}

test_hook_wrapper_no_bashisms() {
    echo -e "\n${CYAN}▶ test_hook_wrapper_no_bashisms${NC}"

    # Check for common bash-only features that break POSIX sh
    if grep -E '\[\[|\$\{[^}]+:|\bfunction\b|\bsource\b' "$SCRIPT_DIR/hook-wrapper.sh" >/dev/null 2>&1; then
        fail_test "No bashisms in wrapper" "Found bash-specific syntax"
    else
        pass_test "No bashisms in wrapper"
    fi
}

test_hook_wrapper_graceful_no_install_script() {
    echo -e "\n${CYAN}▶ test_hook_wrapper_graceful_no_install_script${NC}"

    setup_test_dir

    # Copy wrapper only (no install.sh, no binary)
    cp "$SCRIPT_DIR/hook-wrapper.sh" "$TEST_DIR/"

    # Run wrapper - should exit gracefully (exit 0)
    output=$(echo '{"session_id":"test","transcript_path":"","cwd":"/tmp"}' | \
        sh "$TEST_DIR/hook-wrapper.sh" handle-hook Stop 2>&1)
    exit_code=$?

    assert_exit_code 0 $exit_code "Wrapper exits gracefully when install.sh missing"

    cleanup_test_dir
}

test_hook_wrapper_graceful_download_fail() {
    echo -e "\n${CYAN}▶ test_hook_wrapper_graceful_download_fail${NC}"

    setup_test_dir

    # Copy wrapper and install script
    cp "$SCRIPT_DIR/hook-wrapper.sh" "$TEST_DIR/"
    cp "$SCRIPT_DIR/install.sh" "$TEST_DIR/"

    # Run with invalid URL - should exit gracefully
    output=$(echo '{"session_id":"test","transcript_path":"","cwd":"/tmp"}' | \
        RELEASE_URL="http://127.0.0.1:1" sh "$TEST_DIR/hook-wrapper.sh" handle-hook Stop 2>&1)
    exit_code=$?

    assert_exit_code 0 $exit_code "Wrapper exits gracefully when download fails"

    cleanup_test_dir
}

test_hook_wrapper_detects_platform() {
    echo -e "\n${CYAN}▶ test_hook_wrapper_detects_platform${NC}"

    # Verify wrapper contains platform detection logic
    if grep -q 'MINGW\|MSYS\|CYGWIN' "$SCRIPT_DIR/hook-wrapper.sh"; then
        pass_test "Wrapper has Windows platform detection"
    else
        fail_test "Wrapper has Windows platform detection" "Missing MINGW/MSYS/CYGWIN check"
    fi
}

test_hook_wrapper_path_with_spaces() {
    echo -e "\n${CYAN}▶ test_hook_wrapper_path_with_spaces${NC}"

    # Create test dir with spaces
    TEST_DIR_SPACES=$(mktemp -d)/path\ with\ spaces
    mkdir -p "$TEST_DIR_SPACES"

    # Copy wrapper
    cp "$SCRIPT_DIR/hook-wrapper.sh" "$TEST_DIR_SPACES/"

    # Run wrapper - should handle spaces correctly
    output=$(echo '{"session_id":"test","transcript_path":"","cwd":"/tmp"}' | \
        sh "$TEST_DIR_SPACES/hook-wrapper.sh" handle-hook Stop 2>&1)
    exit_code=$?

    assert_exit_code 0 $exit_code "Wrapper handles paths with spaces"

    rm -rf "$(dirname "$TEST_DIR_SPACES")"
}

test_hook_wrapper_passes_all_arguments() {
    echo -e "\n${CYAN}▶ test_hook_wrapper_passes_all_arguments${NC}"

    setup_test_dir

    # Create a mock binary that echoes arguments
    # On Windows, create .bat file; on Unix, shell script
    if is_windows; then
        cat > "$TEST_DIR/claude-notifications.bat" << 'MOCK_EOF'
@echo off
echo ARGS:%*
MOCK_EOF
    else
        cat > "$TEST_DIR/claude-notifications" << 'MOCK_EOF'
#!/bin/sh
echo "ARGS:$*"
MOCK_EOF
        chmod +x "$TEST_DIR/claude-notifications"
    fi

    # Copy wrapper
    cp "$SCRIPT_DIR/hook-wrapper.sh" "$TEST_DIR/"

    # Run wrapper with multiple arguments
    output=$(echo '{}' | sh "$TEST_DIR/hook-wrapper.sh" handle-hook Stop --extra-arg 2>&1)

    if echo "$output" | grep -q "ARGS:handle-hook Stop --extra-arg"; then
        pass_test "Wrapper passes all arguments to binary"
    else
        fail_test "Wrapper passes all arguments to binary" "Got: $output"
    fi

    cleanup_test_dir
}

test_hook_wrapper_exec_replaces_process() {
    echo -e "\n${CYAN}▶ test_hook_wrapper_exec_replaces_process${NC}"

    # Verify wrapper uses 'exec' for process replacement
    if grep -q 'exec "\$BINARY"' "$SCRIPT_DIR/hook-wrapper.sh"; then
        pass_test "Wrapper uses exec for process replacement"
    else
        fail_test "Wrapper uses exec for process replacement" "Missing 'exec' call"
    fi
}

test_hook_wrapper_silent_install() {
    echo -e "\n${CYAN}▶ test_hook_wrapper_silent_install${NC}"

    # Verify install.sh output is redirected to /dev/null
    if grep -q '>/dev/null 2>&1' "$SCRIPT_DIR/hook-wrapper.sh"; then
        pass_test "Wrapper runs install.sh silently"
    else
        fail_test "Wrapper runs install.sh silently" "Missing output redirection"
    fi
}

test_hook_wrapper_install_non_blocking() {
    echo -e "\n${CYAN}▶ test_hook_wrapper_install_non_blocking${NC}"

    # Verify install.sh failure doesn't block (|| true)
    if grep -q '|| true' "$SCRIPT_DIR/hook-wrapper.sh"; then
        pass_test "Wrapper handles install.sh failure gracefully"
    else
        fail_test "Wrapper handles install.sh failure gracefully" "Missing '|| true'"
    fi
}

test_hook_wrapper_version_check_exists() {
    echo -e "\n${CYAN}▶ test_hook_wrapper_version_check_exists${NC}"

    # Verify wrapper has version checking logic (BIN_VER and PLG_VER variables)
    if grep -q 'BIN_VER' "$SCRIPT_DIR/hook-wrapper.sh" && \
       grep -q 'PLG_VER' "$SCRIPT_DIR/hook-wrapper.sh"; then
        pass_test "Wrapper has version checking logic"
    else
        fail_test "Wrapper has version checking logic" "Missing version variables"
    fi
}

test_hook_wrapper_version_mismatch_triggers_update() {
    echo -e "\n${CYAN}▶ test_hook_wrapper_version_mismatch_triggers_update${NC}"

    # Create proper directory structure: bin/ and .claude-plugin/ at same level
    local ROOT_DIR="${TMPDIR:-${TEMP:-/tmp}}/wrapper-version-test-$$"
    rm -rf "$ROOT_DIR"
    mkdir -p "$ROOT_DIR/bin" "$ROOT_DIR/.claude-plugin"

    # Create mock binary that reports old version
    if is_windows; then
        cat > "$ROOT_DIR/bin/claude-notifications.bat" << 'MOCK_EOF'
@echo off
if "%1"=="version" echo claude-notifications version 1.0.0
MOCK_EOF
    else
        cat > "$ROOT_DIR/bin/claude-notifications" << 'MOCK_EOF'
#!/bin/sh
if [ "$1" = "version" ]; then echo "claude-notifications version 1.0.0"; fi
MOCK_EOF
        chmod +x "$ROOT_DIR/bin/claude-notifications"
    fi

    # Create plugin.json with newer version (at root level, not in bin/)
    echo '{"version": "2.0.0"}' > "$ROOT_DIR/.claude-plugin/plugin.json"

    # Copy wrapper to bin/
    cp "$SCRIPT_DIR/hook-wrapper.sh" "$ROOT_DIR/bin/"
    chmod +x "$ROOT_DIR/bin/hook-wrapper.sh"

    # Create dummy install.sh that creates a marker file
    cat > "$ROOT_DIR/bin/install.sh" << 'INSTALL_EOF'
#!/bin/sh
touch "$INSTALL_TARGET_DIR/.update-triggered"
INSTALL_EOF
    chmod +x "$ROOT_DIR/bin/install.sh"

    # Run wrapper
    echo '{}' | sh "$ROOT_DIR/bin/hook-wrapper.sh" handle-hook Stop >/dev/null 2>&1 || true

    # Check if update was triggered
    if [ -f "$ROOT_DIR/bin/.update-triggered" ]; then
        pass_test "Version mismatch triggers update"
    else
        fail_test "Version mismatch triggers update" "Update not triggered"
    fi

    rm -rf "$ROOT_DIR"
}

test_hook_wrapper_version_match_no_update() {
    echo -e "\n${CYAN}▶ test_hook_wrapper_version_match_no_update${NC}"

    # Create proper directory structure: bin/ and .claude-plugin/ at same level
    local ROOT_DIR="${TMPDIR:-${TEMP:-/tmp}}/wrapper-match-test-$$"
    rm -rf "$ROOT_DIR"
    mkdir -p "$ROOT_DIR/bin" "$ROOT_DIR/.claude-plugin"

    # Create mock binary that reports matching version
    if is_windows; then
        cat > "$ROOT_DIR/bin/claude-notifications.bat" << 'MOCK_EOF'
@echo off
if "%1"=="version" echo claude-notifications version 1.0.0
echo EXECUTED
MOCK_EOF
    else
        cat > "$ROOT_DIR/bin/claude-notifications" << 'MOCK_EOF'
#!/bin/sh
if [ "$1" = "version" ]; then echo "claude-notifications version 1.0.0"; fi
echo "EXECUTED"
MOCK_EOF
        chmod +x "$ROOT_DIR/bin/claude-notifications"
    fi

    # Create plugin.json with SAME version
    echo '{"version": "1.0.0"}' > "$ROOT_DIR/.claude-plugin/plugin.json"

    # Copy wrapper to bin/
    cp "$SCRIPT_DIR/hook-wrapper.sh" "$ROOT_DIR/bin/"
    chmod +x "$ROOT_DIR/bin/hook-wrapper.sh"

    # Create install.sh that creates a marker file
    cat > "$ROOT_DIR/bin/install.sh" << 'INSTALL_EOF'
#!/bin/sh
touch "$INSTALL_TARGET_DIR/.update-triggered"
INSTALL_EOF
    chmod +x "$ROOT_DIR/bin/install.sh"

    # Run wrapper
    output=$(echo '{}' | sh "$ROOT_DIR/bin/hook-wrapper.sh" handle-hook Stop 2>&1) || true

    # Check that update was NOT triggered (versions match)
    if [ ! -f "$ROOT_DIR/bin/.update-triggered" ]; then
        pass_test "Version match skips update"
    else
        fail_test "Version match skips update" "Update was triggered unnecessarily"
    fi

    rm -rf "$ROOT_DIR"
}

test_hook_wrapper_uses_force_on_update() {
    echo -e "\n${CYAN}▶ test_hook_wrapper_uses_force_on_update${NC}"

    # Verify wrapper uses --force when updating existing binary
    if grep -q '\-\-force' "$SCRIPT_DIR/hook-wrapper.sh"; then
        pass_test "Wrapper uses --force flag for updates"
    else
        fail_test "Wrapper uses --force flag for updates" "Missing --force"
    fi
}

#=============================================================================
# Category E: Hook Wrapper Tests (Mock Server)
#=============================================================================

test_hook_wrapper_mock_download() {
    echo -e "\n${CYAN}▶ test_hook_wrapper_mock_download${NC}"

    if ! command -v python3 &>/dev/null; then
        skip_test "Hook wrapper mock download" "python3 not available"
        return
    fi

    setup_test_dir
    start_mock_server $MOCK_PORT

    if [ -z "$MOCK_PID" ]; then
        skip_test "Hook wrapper mock download" "Mock server failed to start"
        return
    fi

    # Create platform-specific mock binary (same as test_mock_download_success)
    local binary_name=$(get_binary_name)
    cp "$FIXTURES_DIR/mock_binary" "$FIXTURES_DIR/$binary_name"

    # Update checksums
    local checksum
    if command -v shasum &>/dev/null; then
        checksum=$(shasum -a 256 "$FIXTURES_DIR/$binary_name" | awk '{print $1}')
    else
        checksum=$(sha256sum "$FIXTURES_DIR/$binary_name" | awk '{print $1}')
    fi
    echo "$checksum  $binary_name" > "$FIXTURES_DIR/checksums.txt"

    # Copy wrapper and install script
    cp "$SCRIPT_DIR/hook-wrapper.sh" "$TEST_DIR/"
    cp "$SCRIPT_DIR/install.sh" "$TEST_DIR/"
    chmod +x "$TEST_DIR/hook-wrapper.sh" "$TEST_DIR/install.sh"

    # Run wrapper with mock server URL
    output=$(echo '{"session_id":"test","transcript_path":"","cwd":"/tmp"}' | \
        RELEASE_URL="http://localhost:$MOCK_PORT" \
        CHECKSUMS_URL="http://localhost:$MOCK_PORT/checksums.txt" \
        sh "$TEST_DIR/hook-wrapper.sh" handle-hook Stop 2>&1) || true

    # Cleanup mock files
    rm -f "$FIXTURES_DIR/$binary_name"

    stop_mock_server

    # Check binary was downloaded
    if is_windows; then
        assert_file_exists "$TEST_DIR/claude-notifications.bat" "Binary downloaded via wrapper (mock)"
    else
        assert_file_exists "$TEST_DIR/claude-notifications" "Binary downloaded via wrapper (mock)"
    fi

    cleanup_test_dir
}

#=============================================================================
# Category F: Hook Wrapper Tests (Real Network)
#=============================================================================

test_hook_wrapper_real_download() {
    echo -e "\n${CYAN}▶ test_hook_wrapper_real_download${NC}"

    if [ "$RUN_REAL_NETWORK" != true ]; then
        skip_test "Hook wrapper real download" "--real-network not specified"
        return
    fi

    setup_test_dir

    # Copy wrapper and install script (but NOT binary)
    cp "$SCRIPT_DIR/hook-wrapper.sh" "$TEST_DIR/"
    cp "$SCRIPT_DIR/install.sh" "$TEST_DIR/"

    # Run wrapper - should auto-download binary
    output=$(echo '{"session_id":"test","transcript_path":"","cwd":"/tmp"}' | \
        sh "$TEST_DIR/hook-wrapper.sh" handle-hook Stop 2>&1) || true

    # Check binary was downloaded
    if is_windows; then
        assert_file_exists "$TEST_DIR/claude-notifications.bat" "Binary downloaded via wrapper"
    else
        assert_file_exists "$TEST_DIR/claude-notifications" "Binary downloaded via wrapper"
    fi

    cleanup_test_dir
}

test_hook_wrapper_real_no_redownload() {
    echo -e "\n${CYAN}▶ test_hook_wrapper_real_no_redownload${NC}"

    if [ "$RUN_REAL_NETWORK" != true ]; then
        skip_test "Hook wrapper no re-download" "--real-network not specified"
        return
    fi

    setup_test_dir

    # First install binary normally
    INSTALL_TARGET_DIR="$TEST_DIR" bash "$INSTALL_SCRIPT" 2>&1 || true

    # Copy wrapper
    cp "$SCRIPT_DIR/hook-wrapper.sh" "$TEST_DIR/"

    # Get binary modification time
    if is_windows; then
        BINARY="$TEST_DIR/claude-notifications.bat"
    else
        BINARY="$TEST_DIR/claude-notifications"
    fi
    mtime_before=$(stat -c %Y "$BINARY" 2>/dev/null || stat -f %m "$BINARY" 2>/dev/null)

    # Small sleep to ensure mtime would change if re-downloaded
    sleep 1

    # Run wrapper
    output=$(echo '{"session_id":"test","transcript_path":"","cwd":"/tmp"}' | \
        sh "$TEST_DIR/hook-wrapper.sh" handle-hook Stop 2>&1) || true

    # Binary should NOT be re-downloaded (same mtime)
    mtime_after=$(stat -c %Y "$BINARY" 2>/dev/null || stat -f %m "$BINARY" 2>/dev/null)

    if [ "$mtime_before" = "$mtime_after" ]; then
        pass_test "Existing binary not re-downloaded"
    else
        fail_test "Existing binary not re-downloaded" "mtime changed: $mtime_before -> $mtime_after"
    fi

    cleanup_test_dir
}

test_hook_wrapper_real_binary_runs() {
    echo -e "\n${CYAN}▶ test_hook_wrapper_real_binary_runs${NC}"

    if [ "$RUN_REAL_NETWORK" != true ]; then
        skip_test "Hook wrapper binary runs" "--real-network not specified"
        return
    fi

    setup_test_dir

    # Copy wrapper and install script
    cp "$SCRIPT_DIR/hook-wrapper.sh" "$TEST_DIR/"
    cp "$SCRIPT_DIR/install.sh" "$TEST_DIR/"

    # Run wrapper with --version to verify binary actually executes
    output=$(sh "$TEST_DIR/hook-wrapper.sh" --version 2>&1) || true

    if echo "$output" | grep -qE "claude-notifications|[0-9]+\.[0-9]+\.[0-9]+"; then
        pass_test "Binary executes via wrapper"
    else
        fail_test "Binary executes via wrapper" "Output: $output"
    fi

    cleanup_test_dir
}

test_hook_wrapper_real_concurrent_calls() {
    echo -e "\n${CYAN}▶ test_hook_wrapper_real_concurrent_calls${NC}"

    if [ "$RUN_REAL_NETWORK" != true ]; then
        skip_test "Hook wrapper concurrent calls" "--real-network not specified"
        return
    fi

    setup_test_dir

    # Copy wrapper and install script
    cp "$SCRIPT_DIR/hook-wrapper.sh" "$TEST_DIR/"
    cp "$SCRIPT_DIR/install.sh" "$TEST_DIR/"

    # Run 3 concurrent wrapper calls
    (echo '{}' | sh "$TEST_DIR/hook-wrapper.sh" handle-hook Stop >/dev/null 2>&1) &
    pid1=$!
    (echo '{}' | sh "$TEST_DIR/hook-wrapper.sh" handle-hook Stop >/dev/null 2>&1) &
    pid2=$!
    (echo '{}' | sh "$TEST_DIR/hook-wrapper.sh" handle-hook Stop >/dev/null 2>&1) &
    pid3=$!

    # Wait for all to complete
    wait $pid1 $pid2 $pid3

    # Verify binary exists and is not corrupted
    # Windows: check -f (file exists) since .bat files aren't executable
    # Unix: check -x (executable)
    if is_windows; then
        BINARY="$TEST_DIR/claude-notifications.bat"
        if [ -f "$BINARY" ]; then
            pass_test "Concurrent calls don't corrupt installation"
        else
            fail_test "Concurrent calls don't corrupt installation" "Binary missing"
        fi
    else
        BINARY="$TEST_DIR/claude-notifications"
        if [ -x "$BINARY" ]; then
            pass_test "Concurrent calls don't corrupt installation"
        else
            fail_test "Concurrent calls don't corrupt installation" "Binary missing or not executable"
        fi
    fi

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

    if [ "$RUN_MOCK_ONLY" != true ]; then
        # Category D: Hook Wrapper Tests (Offline)
        echo ""
        echo -e "${BOLD}Category D: Hook Wrapper Tests (Offline)${NC}"
        test_hook_wrapper_exists
        test_hook_wrapper_is_executable
        test_hook_wrapper_posix_syntax
        test_hook_wrapper_no_bashisms
        test_hook_wrapper_graceful_no_install_script
        test_hook_wrapper_graceful_download_fail
        test_hook_wrapper_detects_platform
        test_hook_wrapper_path_with_spaces
        test_hook_wrapper_passes_all_arguments
        test_hook_wrapper_exec_replaces_process
        test_hook_wrapper_silent_install
        test_hook_wrapper_install_non_blocking
        test_hook_wrapper_version_check_exists
        test_hook_wrapper_version_mismatch_triggers_update
        test_hook_wrapper_version_match_no_update
        test_hook_wrapper_uses_force_on_update
    fi

    # Category E: Hook Wrapper Tests (Mock Server)
    echo ""
    echo -e "${BOLD}Category E: Hook Wrapper Tests (Mock Server)${NC}"
    test_hook_wrapper_mock_download

    if [ "$RUN_MOCK_ONLY" != true ]; then
        # Category F: Hook Wrapper Tests (Real Network)
        echo ""
        echo -e "${BOLD}Category F: Hook Wrapper Tests (Real Network)${NC}"
        test_hook_wrapper_real_download
        test_hook_wrapper_real_no_redownload
        test_hook_wrapper_real_binary_runs
        test_hook_wrapper_real_concurrent_calls
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
