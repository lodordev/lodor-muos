#!/bin/sh
# lodor-override.sh - muOS launch override for Lodor-managed ROM folders.  MARKER: LODOR_OVERRIDE
#
# Installed as a symlink at /opt/muos/share/info/override/<System>.sh for each RetroArch
# folder Lodor mirrors. muOS's launch.sh resolves an override by ROM-dir basename and runs
# it AS the launcher (LAUNCH_EXEC), passing: "$NAME" "$CORE" "$ROM". It replaces ONLY the
# launcher exec - muOS still handles overlay/governor/LED/cleanup around us - so our job is
# exactly: stub-fetch (if needed) -> save pull-before -> hand off to muOS's STOCK launcher
# -> save push/queue after. We do NOT reimplement RetroArch launching (Principle 1).
#
# HARD RULE: launching the game is NEVER gated on sync. Every sync step is best-effort and
# bounded; if anything sync-related is missing or fails, the real emulator still runs. The
# load-bearing line is the launcher hand-off - everything else is second-class.
#
# /tmp/rom_go is already deleted by launch.sh before we run, so we have ONLY name/core/rom
# (no ASSIGN/LAUNCH). We dispatch to lr-general.sh, which correctly loads any libretro core
# (-L <core> <rom>); this override is only installed on RetroArch folders, so that holds.

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$(readlink -f -- "$0" 2>/dev/null || echo "$0")")" && pwd 2>/dev/null)
# The symlink lives in muOS's override dir; the real script + lib live in the app dir.
LIB=""
for c in "$SELF_DIR/../lib/romm-sync-lib.sh" \
         "/run/muos/storage/application/Lodor/lib/romm-sync-lib.sh" \
         "/mnt/mmc/MUOS/application/Lodor/lib/romm-sync-lib.sh"; do
	[ -f "$c" ] && { LIB="$c"; break; }
done

NAME="$1"; CORE="$2"; ROM="${3%/}"

# Display-only: strip the leading cloud/on-device marker for on-screen splashes.
# muOS passes the raw on-disk name (e.g. "✘ Game"); the ✘/✓ glyphs are non-ASCII and
# the splash font is ASCII-only, so they render as "?????". Keep $NAME raw for the ROM path
# (the file on the card genuinely carries the marker); use $NAME_DISP only for user-facing text.
NAME_DISP="$NAME"
case "$NAME_DISP" in
	"✘ "*)   NAME_DISP="${NAME_DISP#✘ }" ;;
	"✓ "*)   NAME_DISP="${NAME_DISP#✓ }" ;;
	"[^] "*)  NAME_DISP="${NAME_DISP#\[^\] }" ;;
	"[v] "*)  NAME_DISP="${NAME_DISP#\[v\] }" ;;
esac

# If the lib is missing, we MUST still launch the game (never brick a launch). Fall back to
# muOS's stock launcher directly and exit.
if [ -z "$LIB" ]; then
	L=/opt/muos/script/launch/lr-general.sh
	[ -x "$L" ] && exec "$L" "$NAME" "$CORE" "$ROM"
	exit 0
fi
. "$LIB"
lodor_export_env

# Tailscale (tier-1) bring-up lib lives next to romm-sync-lib.sh. Sourced for the LAUNCH path
# only — the menu keeps its lazy/background bring-up (mux_launch.sh). A tier-2 (direct) host
# never touches this; if the lib is absent the tier-1 helpers below no-op to "not tier-1".
TS_LIB="$(dirname -- "$LIB")/tailscale-lib.sh"
[ -f "$TS_LIB" ] && . "$TS_LIB" 2>/dev/null

# ensure_tunnel_up — the LAUNCH path's SYNCHRONOUS tier-1 gate. For a Tailscale/SOCKS5 host the
# engine dials RomM THROUGH the userspace tunnel, so the tunnel MUST be Running before any
# --download / --sync-save, or MagicDNS never resolves and the dial fails (the field DLFAIL).
# The menu bring-up is lazy and may not have reached Running yet — the launch path cannot rely
# on it, so it drives TS up here and waits (tailscale_up returns 0 only at BackendState=Running,
# bounded to ~25s internally). Prints an honest "Connecting…" splash while it waits.
#   0 = Running, OR not a tier-1 host (nothing to do)
#   1 = tier-1 host that could NOT reach Running within the bound (honest failure)
ensure_tunnel_up() {
	command -v tailscale_is_tier1 >/dev/null 2>&1 || return 0   # lib absent -> treat as tier-2
	tailscale_is_tier1 || return 0                              # tier-2 (direct) host -> no tunnel
	[ "$(tailscale_status 2>/dev/null)" = "connected" ] && return 0   # already Running
	phase "Connecting to your server..."
	splash "Connecting" "Reaching your server over Tailscale..." good
	tailscale_up >> "$LOG" 2>&1
	[ "$(tailscale_status 2>/dev/null)" = "connected" ]
}

# server_reachable — cheap gate for the OPPORTUNISTIC save pull/push calls (never brings
# anything up). A tier-2 host is reachable whenever Wi-Fi is up; a tier-1 host ALSO needs the
# tunnel Running, else the engine's SOCKS5 dial just burns its whole 25s timeout on every
# launch. Keeps the save bracket honest without adding a cold bring-up to the launch.
server_reachable() {
	wifi_is_up || return 1
	command -v tailscale_is_tier1 >/dev/null 2>&1 || return 0
	tailscale_is_tier1 || return 0
	[ "$(tailscale_status 2>/dev/null)" = "connected" ]
}

# --- engine invocation wrapper (CRITICAL CWD FIX, RG34XX field bug 2026-07-04) -----------
# The engine loads config.json CWD-RELATIVE (engine config.Load -> os.ReadFile("config.json"),
# NOT from LODOR_PAK_DIR). romm-run already cd's to $DATA_DIR before every engine call (its
# line 27); this override never did, so every $BIN call here ran in muOS's launch CWD and the
# engine aborted with `reading config.json: open config.json: no such file or directory` ->
# fetch-on-launch failed -> the ROM stayed empty -> the launch was aborted. Root cause of
# "games don't load". EVERY engine call in this override MUST go through engine() (or a
# matching subshell cd) so config.json resolves. cd runs in a SUBSHELL so the load-bearing
# launcher hand-off below keeps muOS's original CWD.
engine() { ( cd "$DATA_DIR" 2>/dev/null || log "WARN cd $DATA_DIR failed (engine $1)"; "$BIN" "$@" ); }

# splash <title> <body> [good|bad] - best-effort on-screen launch feedback drawn to /dev/fb0
# by the wizard's pure-Go presenter (same renderer onboarding uses; no SDL, CGO-free). It
# draws ONE frame and returns; the frame persists until RetroArch takes the screen. NEVER
# gates the launch and NEVER fakes progress (feedback_no_fake_ui_state): if the wizard binary
# or fb0 is unavailable it just logs and the text phase line still carries the honest status.
splash() {
	_wz="$APPDIR/lodor-wizard"
	[ -x "$_wz" ] || { log "splash unavailable (no wizard bin) - phase-only: $1"; return 0; }
	LODOR_BIN="$BIN" "$_wz" --splash "$1" "$2" "${3:-}" >> "$LOG" 2>&1 \
		|| log "splash render failed (fb busy?) - phase-only: $1"
}

# Mark the in-game session so the daemon won't fight us for the radio mid-play.
echo "$$" > "$INGAME_LOCK" 2>/dev/null
trap 'rm -f "$INGAME_LOCK" 2>/dev/null' EXIT INT TERM HUP QUIT

log "launch NAME=$NAME CORE=$CORE ROM=$ROM"

# Pin the save folder to the core that will actually run (read from the card's own .info).
# When resolvable, the engine reads/writes the exact RetroArch save dir; when not, it falls
# back to its default-core map. (Honest: no guessing - unresolved => no env, documented.)
SUBDIR="$(lodor_corename_for "$CORE")" && [ -n "$SUBDIR" ] && export LODOR_SAVE_SUBDIR="$SUBDIR"
log "save subdir=${LODOR_SAVE_SUBDIR:-<engine default>}"

# --- 1. Fetch-on-launch: a 0-byte stub means the real ROM isn't on the card yet. --------
# This REQUIRES the network, so we bring Wi-Fi up (the one launch path that does). If the
# download fails, do NOT launch an empty file - return to the menu honestly.
DL_OK=0
if [ -f "$ROM" ] && [ ! -s "$ROM" ]; then
	phase "Downloading $NAME..."
	splash "Downloading" "$NAME_DISP" good   # visible on-screen feedback (user feedback #6)
	NET_OK=0; TS_FAIL=0
	if wifi_bring_up; then
		# tier-1 (Tailscale) host: the tunnel MUST be Running before --download (the engine
		# dials RomM through the SOCKS5 proxy; MagicDNS resolves only once Running). SYNCHRONOUS
		# + bounded here — the menu's lazy bring-up can NOT be relied on for the launch path.
		# A tier-2 (direct) host makes this a no-op (returns 0), so nothing changes there.
		if ensure_tunnel_up; then
			NET_OK=1
		else
			TS_FAIL=1
			log "fetch-on-launch: Tailscale tunnel not Running - cannot reach tier-1 server"
		fi
	else
		log "fetch-on-launch: no network"
	fi
	if [ "$NET_OK" = 1 ]; then
		DL_OUT="/tmp/lodor-dl.$$"
		engine --download "$ROM" > "$DL_OUT" 2>&1; DL_RC=$?
		cat "$DL_OUT" >> "$LOG" 2>/dev/null
		# HONEST success (mirrors NextUI's gm_download): engine rc=0 AND its own
		# "downloaded=1" verdict (hash-verified - a mismatch deletes the bad file and
		# reports downloaded=0) AND the file really has bytes now. Gates the post-game
		# marker reconcile in step 5.
		if [ "$DL_RC" = 0 ] && grep -q 'downloaded=1' "$DL_OUT" 2>/dev/null && [ -s "$ROM" ]; then
			DL_OK=1
		elif [ ! -s "$ROM" ]; then
			# RETRY ONCE: a first --download can race a tunnel that only just reached Running
			# (the DERP handshake completing a beat after BackendState flips). Re-confirm the
			# tunnel and try again before giving up — cheap insurance against a cold-start race.
			log "fetch-on-launch: first --download did not land - retry once"
			ensure_tunnel_up >> "$LOG" 2>&1
			engine --download "$ROM" > "$DL_OUT" 2>&1; DL_RC=$?
			cat "$DL_OUT" >> "$LOG" 2>/dev/null
			if [ "$DL_RC" = 0 ] && grep -q 'downloaded=1' "$DL_OUT" 2>/dev/null && [ -s "$ROM" ]; then
				DL_OK=1
			fi
		fi
		rm -f "$DL_OUT" 2>/dev/null
	fi
	if [ ! -s "$ROM" ]; then
		phase "Download failed - returning to menu"
		# HONEST, LOUD failure (feedback_no_fake_ui_state): show a real error on-screen and
		# hold it long enough to read before muOS redraws the menu - no silent abort. The
		# message names the REAL cause + the REAL fix.
		if [ "$TS_FAIL" = 1 ]; then
			splash "Can't reach your server" "Tailscale isn't connected. Check Wi-Fi, or open Lodor -> Tailscale -> Reconnect, then launch again." bad
		elif wifi_is_up; then
			splash "Download failed" "Couldn't download $NAME_DISP. The server or transfer failed - check your RomM server, then launch again." bad
		else
			splash "No Wi-Fi" "Can't download $NAME_DISP while offline. Connect Wi-Fi in muOS Settings, then launch again." bad
		fi
		log "fetch-on-launch FAILED (rom still empty) - abort launch"
		sleep 4
		rm -f "$INGAME_LOCK" 2>/dev/null
		exit 0
	fi
	phase "Downloaded $NAME"
fi

# --- 2. Launch gate (Handoff, task #24 - 2026-07-07): OPPORTUNISTIC, never a
# cold Wi-Fi bring-up. When the server is ALREADY reachable, the wizard probes for
# anything NEWER (save lineage; unseen compatible state) and shows the interactive
# launch card ONLY then - silent instant pass-through otherwise. Bounded by timeout;
# any failure falls through to launch. Wizard absent -> the old silent save pull.
# server_reachable (not bare wifi_is_up): a tier-1 host also needs the tunnel Running.
if [ -n "$ROM" ] && server_reachable; then
	lodor_ensure_device
	_WIZ="$APPDIR/lodor-wizard"
	# CWD FIX: cd in the subshell so config.json resolves; timeout wraps the tool inside it.
	if [ -x "$_WIZ" ]; then
		if command -v timeout >/dev/null 2>&1; then
			( cd "$DATA_DIR" 2>/dev/null || log "WARN cd $DATA_DIR (card)"; LODOR_BIN="$BIN" exec timeout 90 "$_WIZ" --launch-card "$ROM" ) >> "$LOG" 2>&1 || log "launch-card skipped (non-blocking)"
		else
			( cd "$DATA_DIR" 2>/dev/null || log "WARN cd $DATA_DIR (card)"; LODOR_BIN="$BIN" "$_WIZ" --launch-card "$ROM" ) >> "$LOG" 2>&1 || log "launch-card skipped (non-blocking)"
		fi
	elif command -v timeout >/dev/null 2>&1; then
		( cd "$DATA_DIR" 2>/dev/null || log "WARN cd $DATA_DIR (pull)"; exec timeout 25 "$BIN" --sync-save "$ROM" ) >> "$LOG" 2>&1
	else
		engine --sync-save "$ROM" >> "$LOG" 2>&1
	fi
fi

# --- 3. Hand off to muOS's STOCK launcher (load-bearing). Reheal the path. ----------------
LR="$(lodor_launch_dir)/lr-general.sh"
if [ -x "$LR" ]; then
	"$LR" "$NAME" "$CORE" "$ROM"
	rc=$?
else
	log "FATAL stock lr-general.sh not found at $LR"
	rc=127
fi

# --- 4. Post-game save handling. The save is already written to the card by RetroArch. If
# it CHANGED this session: push now when Wi-Fi is up, else queue for the daemon. A quit must
# never block on the radio (offline-first), so the queue is the default when dark. ---------
if [ -n "$ROM" ] && [ -e "$INGAME_LOCK" ]; then
	_rb=$(basename "$ROM"); _rbne="${_rb%.*}"
	SAVES="${SAVES_DIR:-/run/muos/storage/save/file}"
	# STATE-DIR FIX (2026-07-06): muOS keeps savestates in the SIBLING save/state tree
	# (retroarch.default.cfg: savestate_directory=/run/muos/storage/save/state, verified
	# from MustardOS source) — save/file is battery saves only, so the .state* patterns
	# below never matched there and a savestate-only session never triggered the
	# post-game sync. Scan both roots; a missing dir is swallowed by find 2>/dev/null.
	STATES="${STATES_DIR:-/run/muos/storage/save/state}"
	# CLOCK-FIX (2026-06-30): dropped the fragile -newer "$INGAME_LOCK" mtime test. A stale
	# device clock made a just-written save look OLDER than launch, so the push was silently
	# skipped and the save never reached RomM. Name-filter only now; the engine MD5-dedups
	# (sync/push.go OutcomeAlreadyOnServer) so an UNCHANGED save is a verified no-op upload,
	# not a redundant transfer. Mirrors the canonical minarch-shim clock fix.
	# BRACKET-FIX (2026-07-03, #162): the old `-iname "$_rbne.*"` catch-all fed No-Intro
	# glob metacharacters ([S] [!] [b] [h] [T-En]) to find's fnmatch, so a bracketed ROM's
	# just-written save was never matched -> push/queue silently skipped -> save never
	# reached RomM. Now enumerate the KNOWN save extensions and escape the two glob metachars
	# `[`/`]` in the stem/basename so find matches the literal name. Both save-naming styles
	# are covered (RetroArch "<stem>.srm", minarch "<full>.sav", states "<name>.state*").
	# Escape the two glob metachars for find's fnmatch. Order-safe: `]`->placeholder first so
	# the `[`->`[[]` pass can't re-mangle a just-emitted bracket, then placeholder->`[]]`.
	_rb_g=$(printf %s "$_rb" | sed -e 's/\]/@LODORRB@/g' -e 's/\[/[[]/g' -e 's/@LODORRB@/[]]/g')
	_rbne_g=$(printf %s "$_rbne" | sed -e 's/\]/@LODORRB@/g' -e 's/\[/[[]/g' -e 's/@LODORRB@/[]]/g')
	if find "$SAVES" "$STATES" \( \
		-iname "$_rbne_g.srm" -o -iname "$_rbne_g.sav" -o -iname "$_rbne_g.dsv" \
		-o -iname "$_rbne_g.mcr" -o -iname "$_rbne_g.mcd" -o -iname "$_rbne_g.brm" \
		-o -iname "$_rbne_g.eep" -o -iname "$_rbne_g.sra" -o -iname "$_rbne_g.fla" \
		-o -iname "$_rbne_g.mpk" -o -iname "$_rbne_g.nv" -o -iname "$_rbne_g.rtc" \
		-o -iname "$_rbne_g.state*" \
		-o -iname "$_rb_g.srm" -o -iname "$_rb_g.sav" -o -iname "$_rb_g.dsv" \
		-o -iname "$_rb_g.mcr" -o -iname "$_rb_g.mcd" -o -iname "$_rb_g.brm" \
		-o -iname "$_rb_g.eep" -o -iname "$_rb_g.sra" -o -iname "$_rb_g.fla" \
		-o -iname "$_rb_g.mpk" -o -iname "$_rb_g.nv" -o -iname "$_rb_g.rtc" \
		-o -iname "$_rb_g.state*" \
	\) 2>/dev/null | grep -q .; then
		# server_reachable, not bare wifi_is_up: a tier-1 host with the tunnel down would
		# otherwise fail the push after a full timeout — queue it for the daemon instead.
		if server_reachable; then
			lodor_ensure_device
			engine --sync-save "$ROM" >> "$LOG" 2>&1 || { grep -qxF "$ROM" "$PENDING" 2>/dev/null || echo "$ROM" >> "$PENDING"; }
		else
			grep -qxF "$ROM" "$PENDING" 2>/dev/null || echo "$ROM" >> "$PENDING"
			log "save changed, offline -> queued pending"
		fi
	fi
	# Handoff v1: push new save STATES too (additive; engine dedups vs its
	# ledger; dark without statecores.json). Never blocks the exit bracket.
	# Offline queues into pending-states.txt (instant); online drains the queue
	# after the current rom's push.
	if server_reachable; then
		engine --push-states "$ROM" >> "$LOG" 2>&1 || log "push-states failed (non-blocking)"
		engine --push-pending-states >> "$LOG" 2>&1 || log "push-pending-states failed (non-blocking)"
	else
		engine --queue-state "$ROM" >> "$LOG" 2>&1 || log "queue-state failed (non-blocking)"
	fi
fi

# --- 5. Marker reconcile (M1 gap fix): a game we JUST downloaded (DL_OK=1) still wears its
# X cloud-marker filename; without this it kept it until the next library refresh. Now that
# the game has exited the rename is SAFE (renaming in the download->launch window would pull
# the file out from under the launcher - NextUI decision #69), and the save push in step 4
# already ran against the old on-disk name (same ordering as NextUI's post-launch hook,
# 90-lodor-pushsave.sh). --reconcile is filesystem-only and OFFLINE - never gated on Wi-Fi -
# and carries the save + cover with the rename. Best-effort: on failure the marker just
# stays until the next refresh; the game already ran and the save is already handled.
if [ "$DL_OK" = 1 ] && [ -s "$ROM" ]; then
	engine --reconcile "$ROM" >> "$LOG" 2>&1 || log "reconcile failed - marker stays until next refresh"
fi

rm -f "$INGAME_LOCK" 2>/dev/null
exit "$rc"
