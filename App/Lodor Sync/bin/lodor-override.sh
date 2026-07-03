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
         "/run/muos/storage/application/Lodor Sync/lib/romm-sync-lib.sh" \
         "/mnt/mmc/MUOS/application/Lodor Sync/lib/romm-sync-lib.sh"; do
	[ -f "$c" ] && { LIB="$c"; break; }
done

NAME="$1"; CORE="$2"; ROM="${3%/}"

# If the lib is missing, we MUST still launch the game (never brick a launch). Fall back to
# muOS's stock launcher directly and exit.
if [ -z "$LIB" ]; then
	L=/opt/muos/script/launch/lr-general.sh
	[ -x "$L" ] && exec "$L" "$NAME" "$CORE" "$ROM"
	exit 0
fi
. "$LIB"
lodor_export_env

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
	if wifi_bring_up; then
		DL_OUT="/tmp/lodor-dl.$$"
		"$BIN" --download "$ROM" > "$DL_OUT" 2>&1; DL_RC=$?
		cat "$DL_OUT" >> "$LOG" 2>/dev/null
		# HONEST success (mirrors NextUI's gm_download): engine rc=0 AND its own
		# "downloaded=1" verdict (hash-verified - a mismatch deletes the bad file and
		# reports downloaded=0) AND the file really has bytes now. Gates the post-game
		# marker reconcile in step 5.
		if [ "$DL_RC" = 0 ] && grep -q 'downloaded=1' "$DL_OUT" 2>/dev/null && [ -s "$ROM" ]; then
			DL_OK=1
		fi
		rm -f "$DL_OUT" 2>/dev/null
	else
		log "fetch-on-launch: no network"
	fi
	if [ ! -s "$ROM" ]; then
		phase "Download failed - returning to menu"
		log "fetch-on-launch FAILED (rom still empty) - abort launch"
		rm -f "$INGAME_LOCK" 2>/dev/null
		exit 0
	fi
	phase "Downloaded $NAME"
fi

# --- 2. Save pull-before: OPPORTUNISTIC. Never bring Wi-Fi up just to pull (that adds a
# cold-bring-up delay to every launch). Pull only when the radio is ALREADY up - e.g. we
# just downloaded the stub (radio warm) or the user enabled Wi-Fi. Hard-bounded. ----------
if [ -n "$ROM" ] && wifi_is_up; then
	if command -v timeout >/dev/null 2>&1; then
		timeout 25 "$BIN" --sync-save "$ROM" >> "$LOG" 2>&1
	else
		"$BIN" --sync-save "$ROM" >> "$LOG" 2>&1
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
	# CLOCK-FIX (2026-06-30): dropped the fragile -newer "$INGAME_LOCK" mtime test. A stale
	# device clock made a just-written save look OLDER than launch, so the push was silently
	# skipped and the save never reached RomM. Name-filter only now; the engine MD5-dedups
	# (sync/push.go OutcomeAlreadyOnServer) so an UNCHANGED save is a verified no-op upload,
	# not a redundant transfer. Mirrors the canonical minarch-shim clock fix.
	if find "$SAVES" \( -iname "$_rbne.srm" -o -iname "$_rbne.sav" -o -iname "$_rbne.*" \) 2>/dev/null | grep -q .; then
		if wifi_is_up; then
			"$BIN" --sync-save "$ROM" >> "$LOG" 2>&1 || { grep -qxF "$ROM" "$PENDING" 2>/dev/null || echo "$ROM" >> "$PENDING"; }
		else
			grep -qxF "$ROM" "$PENDING" 2>/dev/null || echo "$ROM" >> "$PENDING"
			log "save changed, offline -> queued pending"
		fi
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
	"$BIN" --reconcile "$ROM" >> "$LOG" 2>&1 || log "reconcile failed - marker stays until next refresh"
fi

rm -f "$INGAME_LOCK" 2>/dev/null
exit "$rc"
