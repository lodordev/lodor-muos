#!/bin/sh
# HELP: Set up and sync your RomM library - wireless downloads + automatic save sync.
# ICON: romm
#
# mux_launch.sh - the "RomM Sync" app entry under muOS Applications. It hands the screen
# to our pure-Go framebuffer wizard (lodor-wizard): first run shows the onboarding flow
# (server, pairing, initial mirror); later runs show a Sync-now / re-setup menu. The
# wizard drives the headless engine for all RomM work. Wi-Fi entry stays muOS's job.
#  MARKER: LODOR_APP
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export LODOR_APPDIR="$SELF_DIR"
. "$SELF_DIR/lib/romm-sync-lib.sh"
lodor_export_env

# Tell muOS this is an APP activity so the frontend halts its own render/input loop and
# hands /dev/fb0 + /dev/input to us (the documented handoff; same pattern Grout uses - we
# add NO frontend-kill of our own). Reheal the act flag path.
echo "app" > /tmp/act_go 2>/dev/null

# Restore a sane CPU governor for a responsive UI (best-effort; muOS sets it back on exit).
command -v SET_DEFAULT_GOVERNOR >/dev/null 2>&1 && SET_DEFAULT_GOVERNOR 2>/dev/null

# Refresh the menu glyph so the entry has an icon.
for g in "$MUOS_STORE_DIR/theme/active/glyph/muxapp" /opt/muos/default/MUOS/theme/active/glyph/muxapp; do
	[ -d "$g" ] && [ -f "$SELF_DIR/glyph/romm.png" ] && cp -f "$SELF_DIR/glyph/romm.png" "$g/romm.png" 2>/dev/null
done

# Always (re)seed launch overrides + daemon autostart - idempotent, detect-and-reheal.
"$SELF_DIR/bin/lodor-seed.sh" >> "$LOG" 2>&1

# Hand off to the wizard. It locates the engine next to itself and writes config.json into
# LODOR_DATA_DIR. If the framebuffer/input can't be opened it exits non-zero and logs why
# (honest failure) - muOS restores the frontend on our exit either way.
cd "$SELF_DIR"
LODOR_BIN="$SELF_DIR/lodor-sync" "$SELF_DIR/lodor-wizard" >> "$LOG" 2>&1
rc=$?
log "wizard exit rc=$rc"
exit 0
