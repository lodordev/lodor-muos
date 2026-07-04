#!/bin/sh
# HELP: Set up and sync your RomM library - wireless downloads + automatic save sync.
# ICON: romm
#
# mux_launch.sh - the "Lodor Sync" app entry under muOS Applications. It hands the screen
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

# Perf (G3): SEED-GATE. lodor-seed.sh is idempotent but re-derives every launch override on
# every open (the RG34XX field log showed overrides=17 EVERY launch despite a stamp present) -
# a visible startup cost. ROOT CAUSE of that churn: the old signal was
#   ls -1 "$ROMS_DIR" | sort | md5sum
# over the WHOLE rom-dir listing - which includes transient NON-directory entries (box-art the
# cover daemon drops in, catalog index/lock files) AND every system FOLDER the catalog mirror
# adds after a seed. So the hash differed from the stamp on essentially every launch and the
# gate never fired.
#
# FIX: gate on a STABLE signal that changes ONLY when a re-seed is actually needed -
#   (a) the set of ROM SUBDIRECTORIES (folders only; transient files are ignored), plus
#   (b) the set of Lodor override SYMLINKS already installed (reheal: a deleted override
#       re-seeds).
# and STAMP IT POST-SEED (recompute after the seed settles) so the very next launch, if nothing
# changed, matches and skips. A genuinely-new rom folder still flips (a) and re-seeds once, then
# re-stamps and skips - bounded, never per-launch. (Same intent as NextUI's .library-seeded
# sentinel, hardened against the mirror's folder/file churn.)
ROMS_DIR_NOW="${ROMS_DIR:-$(lodor_roms_dir)}"
OVERRIDE_ROOT="$MUOS_SHARE_DIR/info/override"
SEED_STAMP="$DATA_DIR/.seed-stamp"
# seed_signal: sorted rom SUBDIR names + a marker + sorted Lodor override SYMLINK names,
# hashed. Directories only (glob trailing-slash), so files churning in ROMS never move it;
# override set restricted to OUR symlinks so muOS's own override files (if any) don't either.
seed_signal() {
	{
		for _d in "$ROMS_DIR_NOW"/*/; do
			[ -d "$_d" ] || continue
			_d=${_d%/}; printf '%s\n' "${_d##*/}"
		done
		printf '@overrides@\n'
		for _o in "$OVERRIDE_ROOT"/*.sh; do
			[ -L "$_o" ] || continue
			_o=${_o%.sh}; printf '%s\n' "${_o##*/}"
		done
	} | sort | (md5sum 2>/dev/null || cksum) | awk '{print $1}'
}
have_override() { for _o in "$OVERRIDE_ROOT"/*.sh; do [ -L "$_o" ] && return 0; done; return 1; }
_cur_sig="$(seed_signal)"
_old_sig="$(cat "$SEED_STAMP" 2>/dev/null)"
if [ -n "$_cur_sig" ] && [ "$_cur_sig" = "$_old_sig" ] && have_override; then
	log "seed-gate: rom-dir + override set unchanged -> skip lodor-seed.sh (sig $_cur_sig)"
else
	if "$SELF_DIR/bin/lodor-seed.sh" >> "$LOG" 2>&1; then
		# Recompute AFTER the seed so the stamp records the SETTLED state (overrides just
		# created). Next launch matches this and skips. (Stamping the PRE-seed signal would
		# re-churn: the override set differs before vs after the first seed.)
		seed_signal > "$SEED_STAMP" 2>/dev/null
		log "seed-gate: re-seeded + re-stamped (sig $(cat "$SEED_STAMP" 2>/dev/null))"
	fi
fi

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
