#!/bin/sh
# HELP: Set up and sync your RomM library - wireless downloads + automatic save sync.
# ICON: romm
#
# mux_launch.sh - the "Lodor" app entry under muOS Applications. It hands the screen
# to our pure-Go framebuffer wizard (lodor-wizard): first run shows the onboarding flow
# (server, pairing, initial mirror); later runs show a Sync-now / re-setup menu. The
# wizard drives the headless engine for all RomM work. Wi-Fi entry stays muOS's job.
#  MARKER: LODOR_APP
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export LODOR_APPDIR="$SELF_DIR"
. "$SELF_DIR/lib/romm-sync-lib.sh"
lodor_export_env

# Tier-4 telemetry: PRE-LAUNCH marker + auto-bundle diagnostics to the card root on every
# open. The marker bounds the seed/wizard handoff in the log (a gap after it localizes a
# stall to seed or the wizard's own startup). The collector runs in the BACKGROUND so it
# never delays the menu, and it captures the PREVIOUS session's logs too - the ones a hang
# left behind (the wizard can't bundle its own hang). Best-effort; absence is non-fatal.
log "mux_launch: app open - pre-launch marker ($(date '+%F %T' 2>/dev/null))"
[ -x "$SELF_DIR/bin/lodor-collect.sh" ] && "$SELF_DIR/bin/lodor-collect.sh" >/dev/null 2>&1 &

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

# Perf (G3) + #180B: SEED-GATE. lodor-seed.sh is idempotent but re-derives every launch
# override on every open - a visible startup cost - so it is gated on a STABLE signal
# (rom SUBDIR set + Lodor override SYMLINK set, hashed) stamped post-seed. The signal,
# the gate and the stamping now live in lib/romm-sync-lib.sh (lodor_seed_signal /
# lodor_seed_gated; lodor-seed.sh stamps ITSELF post-seed) so the wizard's post-mirror
# re-seed (#180A) shares them and every seed path leaves a fresh stamp.
#
# HISTORY: the first gate hashed the whole `ls` of ROMS (churned every launch: box-art
# + mirror folders moved it). The edf76bd fix stabilized the signal but ALSO required
# at least one override symlink to exist before skipping (have_override) - and ZERO
# overrides is a legitimate settled state (fresh install pre-mirror, all-standalone
# library), so THAT gate re-seeded every launch with an IDENTICAL sig (RG40XXV field
# log 2026-07-05: "re-seeded + re-stamped (sig 878ad0c2...)" twice in a row). The
# signal already covers the reheal case (a deleted override flips it), so the gate is
# now: sig match = skip. Full root-cause note on lodor_seed_gated in the lib.
lodor_seed_gated "$SELF_DIR/bin/lodor-seed.sh"

# Perf (G3): LAZY Tailscale bring-up. NEVER block the menu render on the tunnel. When the
# device is already onboarded and Tailscale-capable with a persisted login, kick a reconnect
# in the BACKGROUND (detached) so the tunnel is likely up by the time the user picks a
# network action - the menu paints immediately either way. No QR / no-auth here (that stays
# onboarding). A device with no saved TS login gets a fast no-login and exits, harmlessly.
if creds_present && [ -x "$SELF_DIR/bin/lodor-ts.sh" ] && "$SELF_DIR/bin/lodor-ts.sh" available >/dev/null 2>&1; then
	if command -v setsid >/dev/null 2>&1; then
		setsid "$SELF_DIR/bin/lodor-ts.sh" reconnect >> "$LOG" 2>&1 &
	else
		"$SELF_DIR/bin/lodor-ts.sh" reconnect >> "$LOG" 2>&1 &
	fi
fi

# Hand off to the wizard. It locates the engine next to itself and writes config.json into
# LODOR_PAK_DIR. If the framebuffer/input can't be opened it exits non-zero and logs why
# (honest failure) - muOS restores the frontend on our exit either way.
# HANDOFF marker: the last line before control leaves the shell for the Go wizard. If the log
# stops HERE with no following wizard-phase line, the stall is in the wizard's own startup
# (fb/input open), not in seed/Tailscale - the single most useful bisect point in the field.
log "seed done, handing to wizard"
cd "$SELF_DIR" || exit 1
LODOR_BIN="$SELF_DIR/lodor-sync" "$SELF_DIR/lodor-wizard" >> "$LOG" 2>&1
rc=$?
log "wizard exit rc=$rc"
exit 0
