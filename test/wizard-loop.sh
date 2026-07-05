#!/bin/sh
# wizard-loop.sh — off-hardware REAL interactive-loop test for the Lodor-muOS wizard.
#
# THE POINT: --capture renders menu PNGs and --phase-selftest replays phase STRINGS, but
# NEITHER runs the real startup path — ui.OpenFramebuffer + input source + runMainMenu
# blocking on <-in.Buttons(). That is exactly why the 2026-07-04 wizard hang was invisible
# off-device. This harness runs THAT path off-hardware via two test seams that leave the
# production code byte-identical:
#   LODOR_FB_DEV    -> a file-backed framebuffer (synthesized fb_var/fb_fix_screeninfo, the
#                      real pack/Flush/mmap blit; geometry from LODOR_FB_GEOM, default the real
#                      RG34XX 720x480x32 panel; LODOR_FB_YVIRT/LODOR_FB_YOFF model the H700
#                      double-buffer page flip). /dev/fb0 unset => production unchanged.
#   LODOR_INPUT_SCRIPT -> a ScriptedSource feeding logical buttons into the REAL runMainMenu.
#   LODOR_FB_DUMP   -> dump the actually-blitted frame to PNG (read back through the device
#                      pixel format) so we can verify the render pipeline end to end.
# EVERY run is wrapped in `timeout` (NextUI wizard-sim discipline): a loop that stops
# consuming input fails LOUD as a TIMEOUT (rc=124), never a silent CI hang.
#
# Scenarios:
#   A  normal      — no Tailscale shim: menu builds instantly, scripted Down/Down/Back exits.
#   B  hanging shim — LODOR_TS_SHIM points at a shim whose `available` sleeps forever. This
#                     reproduces the FIELD SYMPTOM (wedge at "menu: build state") and PROVES
#                     the tsProbeTimeout (6s) is a REAL hard bound: the menu must recover,
#                     degrade Tailscale to unavailable, paint, and exit — all well under TMO.
#
# Env knobs: WIZARD_LOOP_SB (sandbox, wiped), WIZARD_LOOP_TIMEOUT (per-run, default 30s),
#            LODOR_FB_GEOM (default 720x480x32).
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
MUOS_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
REPO=$(CDPATH= cd -- "$MUOS_ROOT/../.." && pwd)
SB="${WIZARD_LOOP_SB:-/tmp/lodor-wizard-loop}"
TMO="${WIZARD_LOOP_TIMEOUT:-30}"
GEOM="${LODOR_FB_GEOM:-720x480x32}"
fails=0

command -v timeout >/dev/null 2>&1 || { echo "FATAL: coreutils 'timeout' required"; exit 1; }
command -v docker  >/dev/null 2>&1 || { echo "FATAL: docker required to build the wizard"; exit 1; }

rm -rf "$SB"; mkdir -p "$SB"
echo "=== build wizard (native x86-64, CGO-free — same fb/input Go logic the arm64 build runs) ==="
docker run --rm -v "$REPO":/w -w /w/engine -e CGO_ENABLED=0 \
	golang:1.25-bookworm go build -trimpath -o /w/engine/.wizard-loop-bin ./cmd/lodor-wizard \
	|| { echo "FATAL: wizard build failed"; exit 1; }
mv "$REPO/engine/.wizard-loop-bin" "$SB/lodor-wizard"
WIZ="$SB/lodor-wizard"
echo "built: $("$WIZ" --phase-selftest >/dev/null 2>&1; echo ok)"

is_png() { [ "$(head -c4 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "89504e47" ]; }

# assert_common <dir> <rc> <label> — the invariant every scenario must satisfy: clean exit,
# the two money phase lines, and a valid non-trivial rendered frame.
assert_common() {
	_d="$1"; _rc="$2"; _lbl="$3"
	if [ "$_rc" = 124 ]; then
		echo "FAIL[$_lbl]: TIMEOUT (rc=124) — the real loop WEDGED. Last phase:"; tail -1 "$_d/wizard.log" 2>/dev/null; fails=$((fails+1)); return
	fi
	[ "$_rc" = 0 ] && echo "ok[$_lbl]: scripted exit returned cleanly (rc=0)" \
		|| { echo "FAIL[$_lbl]: non-zero exit rc=$_rc"; fails=$((fails+1)); }
	grep -qF "menu: first draw" "$_d/wizard.log" 2>/dev/null \
		&& echo "ok[$_lbl]: reached 'menu: first draw' (menu painted)" \
		|| { echo "FAIL[$_lbl]: never reached 'menu: first draw'"; fails=$((fails+1)); }
	grep -qF "menu: awaiting input" "$_d/wizard.log" 2>/dev/null \
		&& echo "ok[$_lbl]: reached 'menu: awaiting input' (real loop blocked on input, then consumed the script)" \
		|| { echo "FAIL[$_lbl]: never reached 'menu: awaiting input'"; fails=$((fails+1)); }
	if is_png "$_d/frame.png" && [ "$(wc -c < "$_d/frame.png" 2>/dev/null)" -gt 1000 ]; then
		echo "ok[$_lbl]: rendered a valid $(wc -c < "$_d/frame.png")-byte PNG frame (real pack/Flush/mmap blit, read back)"
	else
		echo "FAIL[$_lbl]: no valid rendered frame dumped"; fails=$((fails+1))
	fi
}

echo
echo "########## SCENARIO A: normal startup (no Tailscale shim) ##########"
DA="$SB/A"; mkdir -p "$DA"; printf '{"token":"x"}' > "$DA/config.json"
sA=$(date +%s)
LODOR_FB_DEV="$DA/fb.raw" LODOR_FB_GEOM="$GEOM" LODOR_FB_DUMP="$DA/frame.png" \
	LODOR_INPUT_SCRIPT="down,down,back" LODOR_PAK_DIR="$DA" \
	timeout "$TMO" "$WIZ" >/dev/null 2>&1
rcA=$?; eA=$(( $(date +%s) - sA ))
echo "elapsed=${eA}s"
assert_common "$DA" "$rcA" "A"

echo
echo "########## SCENARIO B: hanging Tailscale shim (proves the 6s tsProbeTimeout is a REAL bound) ##########"
DB="$SB/B"; mkdir -p "$DB"; printf '{"token":"x"}' > "$DB/config.json"
printf '#!/bin/sh\nsleep 3600\n' > "$DB/shim.sh"; chmod +x "$DB/shim.sh"
sB=$(date +%s)
LODOR_TS_SHIM="$DB/shim.sh" LODOR_FB_DEV="$DB/fb.raw" LODOR_FB_GEOM="$GEOM" LODOR_FB_DUMP="$DB/frame.png" \
	LODOR_INPUT_SCRIPT="down,back" LODOR_PAK_DIR="$DB" \
	timeout "$TMO" "$WIZ" >/dev/null 2>&1
rcB=$?; eB=$(( $(date +%s) - sB ))
echo "elapsed=${eB}s (a WEDGE would run the full ${TMO}s and hit rc=124)"
assert_common "$DB" "$rcB" "B"
# The degrade line must be present (proves the probe was actually bounded, not skipped), and
# the whole run must finish comfortably under the outer timeout.
grep -qF "shim probe failed/timeout" "$DB/wizard.log" 2>/dev/null \
	&& echo "ok[B]: tsAvailable probe hit its 6s bound and degraded (timeout is enforced, not skipped)" \
	|| { echo "FAIL[B]: no bounded-timeout degrade line — the probe did not run or did not time out"; fails=$((fails+1)); }
if [ "$eB" -lt "$TMO" ] && [ "$eB" -le 12 ]; then
	echo "ok[B]: recovered in ${eB}s (bounded ~6s), NOT the pre-fix full-timeout wedge"
else
	echo "FAIL[B]: recovery took ${eB}s — the timeout is not bounding the shell-out"; fails=$((fails+1))
fi

echo
echo "======================================================================"
if [ "$fails" = 0 ]; then
	echo "wizard-loop.sh: ALL REAL-LOOP ASSERTIONS PASSED (menu paints, awaits input, clean scripted exit, timeout is a hard bound)"
	exit 0
fi
echo "wizard-loop.sh: $fails assertion(s) FAILED"
exit 1
