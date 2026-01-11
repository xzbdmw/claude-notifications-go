#!/bin/sh
# hook-wrapper.sh - POSIX-compatible wrapper for lazy binary download
# Checks if binary exists, downloads if missing, runs hook
#
# This wrapper enables auto-download of binaries after plugin auto-update.
# Claude Code plugins don't have post-install hooks, so we use lazy loading.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Determine binary path based on platform
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        BINARY="$SCRIPT_DIR/claude-notifications.bat"
        ;;
    *)
        BINARY="$SCRIPT_DIR/claude-notifications"
        ;;
esac

# Check if binary exists and is executable
if [ ! -x "$BINARY" ]; then
    # Download binary (silent, non-blocking on failure)
    INSTALL_TARGET_DIR="$SCRIPT_DIR" "$SCRIPT_DIR/install.sh" >/dev/null 2>&1 || true
fi

# Run the hook (or fail gracefully if still missing)
if [ -x "$BINARY" ]; then
    exec "$BINARY" "$@"
else
    # Binary still missing - exit silently to not block Claude
    exit 0
fi
