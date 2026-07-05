#!/bin/sh
# lodor-collect.sh - Tier-4 telemetry. Bundles everything a hardware post-mortem needs to the
# CARD ROOT, so pulling the SD (no SSH, no serial) yields the full picture in one folder. Run
# on EACH app open so it captures the PREVIOUS session too - including a hang the wizard could
# not survive to report itself. Honest + best-effort: a section that can't be read says so, it
# never fabricates. Never blocks startup (mux_launch backgrounds it).
#  MARKER: LODOR_MUOS_COLLECT
set -u
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export LODOR_APPDIR="${LODOR_APPDIR:-$SELF_DIR}"
. "$SELF_DIR/lib/romm-sync-lib.sh"
lodor_export_env

# Card root: the SD mount whose root appears when the card is pulled and read on a computer.
# SDCARD_PATH is the live rom-mount parent (default /mnt/mmc); fall back to /tmp if unusable.
CARD="${LODOR_DIAG_CARD:-$SDCARD_PATH}"
[ -d "$CARD" ] || CARD="/tmp"
OUT="$CARD/LODOR-DIAG"
mkdir -p "$OUT" 2>/dev/null || { OUT="/tmp/LODOR-DIAG"; mkdir -p "$OUT"; }

SUM="$OUT/summary.txt"
{
	echo "Lodor-muOS diagnostic bundle"
	echo "generated : $(date 2>/dev/null || echo '(no date)')"
	echo "app dir   : $APPDIR"
	echo "data dir  : $DATA_DIR"
	echo
	echo "== app version =="
	cat "$APPDIR/VERSION" 2>/dev/null || echo "(no VERSION file)"
	echo
	echo "== uname -a =="
	uname -a 2>/dev/null || echo "(uname unavailable)"
	echo
	echo "== framebuffer geometry (last wizard 'fb open' phase line) =="
	grep "fb open" "$DATA_DIR/wizard.log" 2>/dev/null | tail -1 || echo "(none - wizard never opened the framebuffer)"
	echo
	echo "== input source (last wizard 'input open'/'scripted' phase line) =="
	grep -E "input open|scripted source" "$DATA_DIR/wizard.log" 2>/dev/null | tail -1 || echo "(none)"
	echo
	echo "== /dev/input event nodes present now =="
	_evn=0
	for _ev in /dev/input/event*; do [ -e "$_ev" ] && { echo "$_ev"; _evn=$((_evn + 1)); }; done
	echo "count: $_evn"
	echo
	echo "== LAST wizard phase reached (a hang localizes to the line AFTER this) =="
	grep "wizard-phase" "$DATA_DIR/wizard.log" 2>/dev/null | tail -1 || echo "(no phase log - wizard never started)"
	echo
	echo "== last 'wizard exit' marker (absent => the wizard did NOT return: hang or kill) =="
	grep "wizard exit" "$LOG" 2>/dev/null | tail -1 || echo "(none - no clean wizard exit recorded)"
} > "$SUM" 2>/dev/null

# Live logs, bounded tails so the bundle stays small. seed output is part of romm.log (the
# seed script appends to $LOG), so romm.log carries the seed log too.
tail -n 400 "$DATA_DIR/wizard.log" > "$OUT/wizard.log" 2>/dev/null || : > "$OUT/wizard.log"
tail -n 400 "$LOG"                 > "$OUT/romm.log"   2>/dev/null || : > "$OUT/romm.log"
if [ -f "$DATA_DIR/tailscale/tailscaled.log" ]; then
	tail -n 200 "$DATA_DIR/tailscale/tailscaled.log" > "$OUT/tailscaled.log" 2>/dev/null
fi
dmesg 2>/dev/null | tail -n 200 > "$OUT/dmesg-tail.txt" 2>/dev/null \
	|| echo "(dmesg unavailable / not permitted on this build)" > "$OUT/dmesg-tail.txt"

sync 2>/dev/null
log "telemetry: diagnostic bundle written to $OUT"
exit 0
