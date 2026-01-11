#!/bin/sh
# hook-wrapper.sh - POSIX-compatible wrapper for lazy binary download
# Checks if binary exists AND version matches, downloads if needed, runs hook
#
# This wrapper enables auto-download of binaries after plugin auto-update.
# Claude Code plugins don't have post-install hooks, so we use lazy loading.
#
# RELIABILITY: All operations use || true to never block Claude.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_JSON="$SCRIPT_DIR/../.claude-plugin/plugin.json"
INSTALL_SCRIPT="$SCRIPT_DIR/install.sh"

# Platform detection
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) IS_WINDOWS=1; BINARY="$SCRIPT_DIR/claude-notifications.bat" ;;
    *)                    IS_WINDOWS=0; BINARY="$SCRIPT_DIR/claude-notifications" ;;
esac

# Check if binary is ready (exists and executable on Unix, exists on Windows)
binary_ok() {
    if [ "$IS_WINDOWS" = 1 ]; then
        [ -f "$BINARY" ]
    else
        [ -x "$BINARY" ]
    fi
}

# Get version from binary or plugin.json (returns empty on failure)
get_binary_version() {
    "$BINARY" version 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true
}

get_plugin_version() {
    [ -f "$PLUGIN_JSON" ] && grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' "$PLUGIN_JSON" | head -n 1 || true
}

# Run install.sh (silent, never fails the script)
run_install() {
    [ -f "$INSTALL_SCRIPT" ] || return 0
    INSTALL_TARGET_DIR="$SCRIPT_DIR" "$INSTALL_SCRIPT" "$@" >/dev/null 2>&1 || true
}

# === Main Logic ===

NEED_INSTALL=0
NEED_FORCE=0

if ! binary_ok; then
    # Binary missing - need install
    NEED_INSTALL=1
else
    # Binary exists - check version
    BIN_VER=$(get_binary_version)
    PLG_VER=$(get_plugin_version)

    # Update only if both versions are known and differ
    if [ -n "$BIN_VER" ] && [ -n "$PLG_VER" ] && [ "$BIN_VER" != "$PLG_VER" ]; then
        NEED_INSTALL=1
        NEED_FORCE=1
    fi
fi

# Install if needed
if [ "$NEED_INSTALL" = 1 ]; then
    if [ "$NEED_FORCE" = 1 ]; then
        run_install --force
    else
        run_install
    fi
fi

# Run hook or exit gracefully
if binary_ok; then
    exec "$BINARY" "$@"
fi

exit 0
