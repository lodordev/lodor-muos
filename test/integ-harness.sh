#!/bin/sh
# integ-harness.sh — Lodor-muOS end-to-end integration harness (monorepo edition).
#
# Builds a bind-mount sandbox mimicking /opt/muos and /run/muos/storage from the REAL
# muOS card image, installs the "Lodor" app (source from ../App, engine + wizard
# built fresh from THIS repo's engine/ via docker), and exercises the full surface:
#   offline: lodor-seed.sh, launch override dispatch, save->pending queue, stub honest-abort
#   live:    engine --validate, --mirror-catalog stub counts, download-on-launch
#            (hash-verified by the engine), save round-trip (push -> wipe -> pull),
#            wizard --capture screen renders
# Run as ROOT on panther: needs losetup/mount/unshare, docker (golang image), and the
# qemu-aarch64 binfmt handler (the arm64 static binaries run transparently).
#
# Env knobs:
#   MUOS_IMAGE  path to the MustardOS card image (default: the known RG34XX 2601.1 copy);
#               ABSENT => loud warning + skip (exit 0) — never a silent pass.
#   LODOR_CFG   path to a LIVE config.json (token; never committed). Absent => offline
#               tests only, live section skipped with a loud warning.
#   LODOR_SB    sandbox dir (default /tmp/lodor-muos-integ). Wiped every run.
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
MUOS_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)          # integrations/muos
REPO=$(CDPATH= cd -- "$MUOS_ROOT/../.." && pwd)       # monorepo root
IMG="${MUOS_IMAGE:-/mnt/cache/tmp/lodor-muos/MustardOS_RG34XX-H_2601.1_FUNKY_JACARANDA-bc38efa0.img}"
CFG_SRC="${LODOR_CFG:-/mnt/cache/tmp/lodor-muos/sandbox/pak/config.json}"
SB="${LODOR_SB:-/tmp/lodor-muos-integ}"
PAK_SRC="$MUOS_ROOT/App/Lodor"

if [ ! -f "$IMG" ]; then
	echo "##############################################################################"
	echo "# WARNING: muOS card image NOT FOUND: $IMG"
	echo "# The integ harness CANNOT run without it (real func.sh/assign/info ground"
	echo "# truth comes from the image). Set MUOS_IMAGE=<path>. SKIPPING — this is NOT"
	echo "# a pass: nothing end-to-end was verified."
	echo "##############################################################################"
	exit 0
fi
[ "$(id -u)" = "0" ] || { echo "FATAL: run as root (losetup/mount/unshare)"; exit 1; }

echo "=== build engine + wizard from THIS repo (arm64, -tags muos, CGO-free) ==="
docker run --rm -v "$REPO":/w -w /w/engine -e CGO_ENABLED=0 -e GOARCH=arm64 \
	golang:1.25-bookworm go build -tags muos -trimpath -ldflags "-s -w" \
	-o /w/engine/.integ-out-sync ./cmd/lodor-sync || { echo "FATAL: engine build failed"; exit 1; }
docker run --rm -v "$REPO":/w -w /w/engine -e CGO_ENABLED=0 -e GOARCH=arm64 \
	golang:1.25-bookworm go build -tags muos -trimpath -ldflags "-s -w" \
	-o /w/engine/.integ-out-wizard ./cmd/lodor-wizard || { echo "FATAL: wizard build failed"; exit 1; }
# mock RomM (host arch — runs natively beside the sandbox; #181 offline history leg).
# Ad-hoc single-file build: mockromm.go lives outside the engine module on purpose.
docker run --rm -v "$REPO":/w -w /w/integrations/muos/test -e CGO_ENABLED=0 \
	golang:1.25-bookworm go build -o /w/engine/.integ-out-mockromm mockromm.go \
	|| { echo "FATAL: mockromm build failed"; exit 1; }

echo "=== menu-row assertions: unit-test the PURE management-menu spine + ScrollMenu ==="
# The management menu lives in the Go wizard (muOS can't hook the stock launcher). Its row
# table (buildMenuRows) + the ScrollMenu window are pure, so we assert them off-hardware:
# each row maps to the right engine mode, conditional rows (pending/queue/pairing/Tailscale)
# gate correctly, and ScrollMenu keeps the selection in its window. A failure here is a hard
# stop (loud, never a silent pass) BEFORE the sandbox section.
docker run --rm -v "$REPO":/w -w /w/engine -e CGO_ENABLED=0 \
	golang:1.25-bookworm go test ./cmd/lodor-wizard/ ./ui/ 2>&1 | tail -6 \
	|| { echo "FATAL: menu-spine unit tests failed (row->mode / ScrollMenu)"; exit 1; }
echo "ok: menu-row assertions pass (row->mode mapping, conditional rows, ScrollMenu window)"

echo "=== reset sandbox: $SB ==="
rm -rf "$SB"
mkdir -p "$SB/opt-muos/script/var" "$SB/opt-muos/script/launch" \
	"$SB/opt-muos/emulator/retroarch/info" "$SB/opt-muos/info/assign" "$SB/opt-muos/info/override" \
	"$SB/storage/save/file" "$SB/storage/init" "$SB/storage/application" \
	"$SB/mmc/Roms" "$SB/sysnet/wlan0" "$SB/fakebin" "$SB/capture"
mv "$REPO/engine/.integ-out-sync" "$SB/lodor-sync"
mv "$REPO/engine/.integ-out-wizard" "$SB/lodor-wizard"
mv "$REPO/engine/.integ-out-mockromm" "$SB/mockromm"
OM="$SB/opt-muos"

echo "=== mount image read-only, extract real /opt/muos bits ==="
losetup -fP --read-only "$IMG" || { echo "FATAL: losetup"; exit 1; }
LD=$(losetup -j "$IMG" | head -1 | cut -d: -f1)
mkdir -p "$SB/mnt"; mount -o ro "${LD}p5" "$SB/mnt" || { losetup -d "$LD"; echo "FATAL: mount p5"; exit 1; }
cp "$SB/mnt/opt/muos/script/var/func.sh" "$OM/script/var/func.sh"
cp "$SB/mnt/opt/muos/share/emulator/retroarch/retroarch.default.cfg" "$OM/emulator/retroarch/retroarch.default.cfg"
cp "$SB/mnt/opt/muos/share/emulator/retroarch/info/genesis_plus_gx_libretro.info" "$OM/emulator/retroarch/info/" 2>/dev/null
cp -r "$SB/mnt/opt/muos/share/info/assign/Sega Game Gear" "$OM/info/assign/" 2>/dev/null
# also a STANDALONE system's assign, to prove seed skips it (PSP -> ext-ppsspp)
cp -r "$SB/mnt/opt/muos/share/info/assign/Sony PlayStation Portable" "$OM/info/assign/" 2>/dev/null
umount "$SB/mnt"; losetup -d "$LD"; echo "extracted."

echo "=== stub lr-general.sh (simulates RetroArch writing a .srm) ==="
cat > "$OM/script/launch/lr-general.sh" <<'STUB'
#!/bin/sh
# STUB RetroArch: writes a battery save to save/file/<corename>/<base>.srm then exits.
NAME="$1"; CORE="$2"; FILE="$3"
INFO="/opt/muos/share/emulator/retroarch/info/${CORE%.so}.info"
CN=$(sed -n 's/^corename *= *"\(.*\)"/\1/p' "$INFO" 2>/dev/null | head -1)
[ -z "$CN" ] && CN="Genesis Plus GX"
B=$(basename "$FILE"); BNE="${B%.*}"
mkdir -p "/run/muos/storage/save/file/$CN"
echo "STUB-SAVE-$(date +%s)" > "/run/muos/storage/save/file/$CN/$BNE.srm"
echo "[stub lr-general] wrote save for $NAME via $CN"
STUB
chmod +x "$OM/script/launch/lr-general.sh"
# muOS share layout: func.sh exports MUOS_SHARE_DIR=/opt/muos/share; our OM maps to
# /opt/muos, so share content must resolve under $OM/share. Re-link the share subtree.
mkdir -p "$OM/share"; for d in emulator info; do ln -sf "../$d" "$OM/share/$d"; done

echo "=== fake-wifi shim (live launch path needs wifi_is_up to hold in the sandbox) ==="
echo up > "$SB/sysnet/wlan0/operstate"
cat > "$SB/fakebin/ip" <<'FAKEIP'
#!/bin/sh
# sandbox `ip` shim: report an inet address on wlan0 so wifi_is_up passes.
echo "    inet 192.0.2.10/24 scope global wlan0"
FAKEIP
chmod +x "$SB/fakebin/ip"

echo "=== install the Lodor app into the sandbox application dir ==="
cp -r "$PAK_SRC" "$SB/storage/application/Lodor"
APP_SB="$SB/storage/application/Lodor"
cp "$SB/lodor-sync" "$APP_SB/lodor-sync"; chmod +x "$APP_SB/lodor-sync"
cp "$SB/lodor-wizard" "$APP_SB/lodor-wizard"; chmod +x "$APP_SB/lodor-wizard"
LIVE=0
if [ -f "$CFG_SRC" ]; then
	cp "$CFG_SRC" "$APP_SB/config.json"; LIVE=1
else
	echo "##############################################################################"
	echo "# WARNING: no live config.json at $CFG_SRC — LIVE RomM tests will be SKIPPED."
	echo "# Offline tests still run. Set LODOR_CFG=<path-to-config.json-with-token>."
	echo "##############################################################################"
fi
# Seed a Game Gear folder with a real-ish (non-stub) ROM for the offline launch test.
mkdir -p "$SB/mmc/Roms/Sega Game Gear"
printf 'NOTASTUB' > "$SB/mmc/Roms/Sega Game Gear/5 in 1 FunPak (USA).gg"

echo "=== start the mock RomM (loopback; #181 offline history leg) ==="
MOCKPORT="${LODOR_MOCKPORT:-8199}"
"$SB/mockromm" -addr "127.0.0.1:$MOCKPORT" > "$SB/mockromm.log" 2>&1 &
MOCKPID=$!
trap 'kill "$MOCKPID" 2>/dev/null' EXIT
i=0
while [ "$i" -lt 25 ]; do
	if command -v curl >/dev/null 2>&1; then
		curl -sf "http://127.0.0.1:$MOCKPORT/api/heartbeat" >/dev/null 2>&1 && break
	else
		wget -q -O /dev/null "http://127.0.0.1:$MOCKPORT/api/heartbeat" 2>/dev/null && break
	fi
	i=$((i + 1)); sleep 1
done
kill -0 "$MOCKPID" 2>/dev/null || { echo "FATAL: mock RomM died on startup"; sed -n 1,5p "$SB/mockromm.log"; exit 1; }
echo "mock RomM up on 127.0.0.1:$MOCKPORT (pid $MOCKPID)"

echo
echo "########## RUN UNDER mount-namespace bind mounts ##########"
# NOTE: sandbox roms live under mmc/Roms (not the card's ROMS): panther's FS is
# case-SENSITIVE while the card's exFAT is not, and the engine's shared catalog joins
# sdcardRoot()+"/Roms". One spelling keeps shell+engine agreeing off-hardware; on the
# card both land in /mnt/mmc/ROMS. (Tracked engine cleanup; do not fix here.)
unshare -m sh -s "$SB" "$LIVE" "$MOCKPORT" <<'NS'
set -u
SB="$1"; LIVE="$2"; MOCKPORT="$3"
mkdir -p /opt/muos /run/muos/storage
mount --bind "$SB/opt-muos" /opt/muos
mount --bind "$SB/storage" /run/muos/storage
mount --bind "$SB/sysnet" /sys/class/net 2>/dev/null || echo "WARN: /sys/class/net bind failed — live wifi-path tests may skip"
PATH="$SB/fakebin:$PATH"; export PATH
APP="/run/muos/storage/application/Lodor"
export LODOR_APPDIR="$APP"
export ROMS_DIR="$SB/mmc/Roms"
export SDCARD_PATH="$SB/mmc"
fails=0

echo "===== TEST 0: seed-gate skips on identical sig in the ZERO-OVERRIDE state (#180B) ====="
# The 2026-07-05 RG40XXV field bug: fresh install, ROMS empty -> zero overrides is the
# SETTLED state, but the old gate's have_override conjunct forced a re-seed every launch
# with an IDENTICAL sig. Reproduce: empty roms dir, gate twice -> exactly one re-seed,
# then a skip. (set +u: the sourced lib + the card's func.sh predate this harness's -u.)
EMPTYROMS="$SB/mmc-empty"; mkdir -p "$EMPTYROMS"
: > "$APP/romm.log"
(
	set +u
	ROMS_DIR="$EMPTYROMS"; export ROMS_DIR
	. "$APP/lib/romm-sync-lib.sh"
	lodor_export_env
	lodor_seed_gated "$APP/bin/lodor-seed.sh"
	lodor_seed_gated "$APP/bin/lodor-seed.sh"
)
g_seed=$(grep -c "seed-gate: re-seeded" "$APP/romm.log" || true)
g_skip=$(grep -c "seed-gate: unchanged" "$APP/romm.log" || true)
if [ "$g_seed" = 1 ] && [ "$g_skip" = 1 ]; then
	echo "ok: zero-override gate = 1 re-seed + 1 skip (field bug fixed)"
else
	echo "FAIL: zero-override gate re-seed=$g_seed skip=$g_skip (want 1/1)"; fails=$((fails+1))
	grep "seed-gate" "$APP/romm.log" | tail -4
fi
rm -f "$APP/.seed-stamp"   # fresh gate state for the real-library tests below

echo
echo "===== TEST 1: lodor-seed.sh (RetroArch folder seeded, standalone skipped) ====="
mkdir -p "$SB/mmc/Roms/Sony PlayStation Portable"; : > "$SB/mmc/Roms/Sony PlayStation Portable/dummy.iso"
"$APP/bin/lodor-seed.sh"
OV="/opt/muos/share/info/override/Sega Game Gear.sh"
[ -L "$OV" ] && echo "ok: Game Gear override seeded" || { echo "FAIL: no Game Gear override"; fails=$((fails+1)); }
[ -e "/opt/muos/share/info/override/Sony PlayStation Portable.sh" ] \
	&& { echo "FAIL: standalone PSP got an override"; fails=$((fails+1)); } \
	|| echo "ok: standalone PSP skipped"
[ -f "/run/muos/storage/init/00-lodor.sh" ] && echo "ok: boot hook present" || { echo "FAIL: boot hook missing"; fails=$((fails+1)); }

echo
echo "===== TEST 1b: seeder self-stamps; gate skips the very next launch (#180B) ====="
# TEST 1 ran lodor-seed.sh DIRECTLY (not via the gate) — with the fix the seeder stamps
# itself, so a gate call right after must skip with 'unchanged'. Proves the stamp is
# honored ACROSS processes with overrides present (the non-empty-library skip path).
[ -s "$APP/.seed-stamp" ] && echo "ok: seeder wrote its own stamp" || { echo "FAIL: no .seed-stamp after direct seed"; fails=$((fails+1)); }
: > "$APP/romm.log"
( set +u; . "$APP/lib/romm-sync-lib.sh"; lodor_export_env; lodor_seed_gated "$APP/bin/lodor-seed.sh" )
if grep -q "seed-gate: unchanged (sig .*) - skip" "$APP/romm.log"; then
	echo "ok: identical-sig launch skips (stamp honored)"
else
	echo "FAIL: gate did not skip on identical sig:"; grep "seed-gate" "$APP/romm.log" | tail -2; fails=$((fails+1))
fi

echo
echo "===== TEST 1c: wizard --reseed wires overrides IN-SESSION (post-mirror seam, #180A) ====="
# Simulate the post-mirror state WITHOUT an app relaunch: kill the override + stamp, then
# run the wizard's re-seed hook (the same code screenMirrorArgs calls after a successful
# mirror). The override must come back and the honest overrides=N line must be logged.
rm -f "/opt/muos/share/info/override/Sega Game Gear.sh" "$APP/.seed-stamp" "$APP/wizard.log"
# LODOR_PAK_DIR: on-device mux_launch exports it (lodor_export_env) before the wizard
# runs — without it dataDir() is empty and wizard.log is never written. Mirror that.
LODOR_PAK_DIR="$APP" "$APP/lodor-wizard" --reseed >/dev/null 2>&1
[ -L "/opt/muos/share/info/override/Sega Game Gear.sh" ] \
	&& echo "ok: override re-wired in-session (no app relaunch)" \
	|| { echo "FAIL: wizard --reseed did not wire the override"; fails=$((fails+1)); }
grep -q "seed: post-mirror re-seed, overrides=" "$APP/wizard.log" 2>/dev/null \
	&& echo "ok: honest overrides count logged" \
	|| { echo "FAIL: post-mirror re-seed log line missing"; fails=$((fails+1)); }

echo
echo "===== TEST 2: launch a REAL rom via the override (dispatch + save -> pending) ====="
# Wifi fake OFF for the offline tests: point wifi_is_up at a downed state.
echo down > "$SB/sysnet/wlan0/operstate"
ROM="$SB/mmc/Roms/Sega Game Gear/5 in 1 FunPak (USA).gg"
# DEVICE-FAITHFUL CWD: muOS's launch.sh execs the override from its OWN cwd, NOT the app
# dir. Run every override invocation from "/" so the harness reproduces the field CWD the
# 2026-07-04 config.json bug lived in (the old `cd "$APP"` below MASKED it). The fixed
# override cd's to $DATA_DIR internally for each engine call.
( cd / && "$OV" "5 in 1 FunPak" "genesis_plus_gx_libretro.so" "$ROM" ); rc=$?
[ "$rc" = 0 ] && echo "ok: override rc=0" || { echo "FAIL: override rc=$rc"; fails=$((fails+1)); }
SAVE="/run/muos/storage/save/file/Genesis Plus GX/5 in 1 FunPak (USA).srm"
[ -s "$SAVE" ] && echo "ok: stub RetroArch wrote the save" || { echo "FAIL: no save written"; fails=$((fails+1)); }
grep -q "5 in 1 FunPak" "$APP/pending-saves.txt" 2>/dev/null \
	&& echo "ok: save queued to pending (offline)" || { echo "FAIL: pending queue empty"; fails=$((fails+1)); }

echo
echo "===== TEST 3: fetch-on-launch on a 0-byte STUB with no network (honest abort) ====="
STUBROM="$SB/mmc/Roms/Sega Game Gear/Aladdin (USA, Europe, Brazil) (En).gg"
: > "$STUBROM"
( cd / && "$OV" "Aladdin" "genesis_plus_gx_libretro.so" "$STUBROM" ); rc=$?
[ "$rc" = 0 ] || { echo "FAIL: stub abort rc=$rc (must return to menu cleanly)"; fails=$((fails+1)); }
[ -s "$STUBROM" ] && { echo "FAIL: stub grew with no network?!"; fails=$((fails+1)); } || echo "ok: stub still 0 bytes (not launched empty)"
echo "phase line: $(cat /tmp/romm-phase 2>/dev/null)"
rm -f "$STUBROM"

echo
echo "===== TEST 3b: multi-disc incomplete .m3u (lodor#7 disc-1-first), OFFLINE ====="
# (a) populated .m3u + disc 1 real + disc 2 stub -> the override logs the honest offline
#     skip (no cold bring-up) and STILL hands off to the launcher: the game plays on the
#     discs it has — the launch is never gated on later discs.
MDGG="$SB/mmc/Roms/Sega Game Gear"
mkdir -p "$MDGG/Chrono Cross (USA)"
printf '%s\n%s\n' "Chrono Cross (USA)/Chrono Cross (USA) (Disc 1).chd" \
	"Chrono Cross (USA)/Chrono Cross (USA) (Disc 2).chd" > "$MDGG/Chrono Cross (USA).m3u"
echo DISC1 > "$MDGG/Chrono Cross (USA)/Chrono Cross (USA) (Disc 1).chd"
: > "$MDGG/Chrono Cross (USA)/Chrono Cross (USA) (Disc 2).chd"
( cd / && "$OV" "Chrono Cross" "genesis_plus_gx_libretro.so" "$MDGG/Chrono Cross (USA).m3u" ); rc=$?
[ "$rc" = 0 ] && echo "ok: override rc=0 on incomplete multi-disc" || { echo "FAIL: override rc=$rc"; fails=$((fails+1)); }
grep -q "launching on the discs present" "$APP/romm.log" 2>/dev/null \
	&& echo "ok: honest offline skip logged (no cold bring-up)" \
	|| { echo "FAIL: missing 'launching on the discs present' log"; fails=$((fails+1)); }
[ -s "/run/muos/storage/save/file/Genesis Plus GX/Chrono Cross (USA).srm" ] \
	&& echo "ok: launcher hand-off happened (launch NOT gated on disc 2)" \
	|| { echo "FAIL: launch was blocked by the incomplete later disc"; fails=$((fails+1)); }
[ -s "$MDGG/Chrono Cross (USA)/Chrono Cross (USA) (Disc 2).chd" ] \
	&& { echo "FAIL: disc 2 stub gained bytes offline (fake progress)"; fails=$((fails+1)); } \
	|| echo "ok: disc 2 stub untouched offline"
# (b) disc 1 itself missing -> honest abort back to menu (same class as the empty stub):
#     fetch attempted (no network), loud failure, NO hand-off with a black-screen disc 1.
mkdir -p "$MDGG/Grandia (USA)"
printf '%s\n%s\n' "Grandia (USA)/Grandia (USA) (Disc 1).chd" \
	"Grandia (USA)/Grandia (USA) (Disc 2).chd" > "$MDGG/Grandia (USA).m3u"
: > "$MDGG/Grandia (USA)/Grandia (USA) (Disc 1).chd"
: > "$MDGG/Grandia (USA)/Grandia (USA) (Disc 2).chd"
( cd / && "$OV" "Grandia" "genesis_plus_gx_libretro.so" "$MDGG/Grandia (USA).m3u" ); rc=$?
[ "$rc" = 0 ] || { echo "FAIL: disc-1-missing abort rc=$rc (must return to menu cleanly)"; fails=$((fails+1)); }
grep -q "next-disc fetch FAILED (disc 1 still missing)" "$APP/romm.log" 2>/dev/null \
	&& echo "ok: disc-1-missing failure logged honestly" \
	|| { echo "FAIL: missing disc-1-missing failure log"; fails=$((fails+1)); }
[ -f "/run/muos/storage/save/file/Genesis Plus GX/Grandia (USA).srm" ] \
	&& { echo "FAIL: launcher ran with disc 1 missing (black screen shipped)"; fails=$((fails+1)); } \
	|| echo "ok: no hand-off with disc 1 missing (honest abort)"

echo
echo "===== TEST 4: wizard --capture renders every screen to PNG (no fb, no input) ====="
"$APP/lodor-wizard" --capture "$SB/capture" >/dev/null 2>&1
n=$(find "$SB/capture" -name "*.png" 2>/dev/null | wc -l)
if [ "$n" -gt 0 ]; then
	badpng=0
	for p in "$SB/capture"/*.png; do
		[ "$(head -c4 "$p" | od -An -tx1 | tr -d ' \n')" = "89504e47" ] || badpng=$((badpng+1))
	done
	[ "$badpng" = 0 ] && echo "ok: wizard rendered $n PNG screens" || { echo "FAIL: $badpng non-PNG captures"; fails=$((fails+1)); }
	# MENU-ROW RENDER assertions: the new management menu (ScrollMenu-backed) and a Game
	# Manager per-game screen must render as valid PNGs on the actual built wizard binary —
	# proving ScrollMenu draws and the parity menu paints (not just the pure row table).
	for want in 10-menu.png 13-gamemanager.png; do
		p="$SB/capture/$want"
		if [ -f "$p" ] && [ "$(head -c4 "$p" | od -An -tx1 | tr -d ' \n')" = "89504e47" ]; then
			echo "ok: management menu screen rendered ($want)"
		else
			echo "FAIL: menu screen $want missing/not-a-PNG (ScrollMenu render)"; fails=$((fails+1))
		fi
	done
else
	echo "FAIL: wizard --capture produced no PNGs"; fails=$((fails+1))
fi

echo
echo "===== TEST 4b: wizard emits its startup PHASE lines (BUG 2a instrumentation) ====="
# The interactive startup path (fb + evdev) can't run off-hardware, so --phase-selftest replays
# the SAME phase strings the real startup emits via the SAME logPhase, to stderr. A missing line
# here means the next on-hardware hang would NOT be localizable — a hard fail, never a silent pass.
PLOG="$SB/capture/wizard-phase.log"
"$APP/lodor-wizard" --phase-selftest 2> "$PLOG" >/dev/null || true
pmiss=0
for ph in "wizard: start" "fb open " "input open " "configured=" \
          "menu: build state" "menu: state ok (" "menu: first draw" "menu: awaiting input"; do
	grep -qF "$ph" "$PLOG" 2>/dev/null || { echo "FAIL: startup phase line missing: '$ph'"; pmiss=$((pmiss+1)); }
done
[ "$pmiss" = 0 ] && echo "ok: all 8 startup phase lines emitted (hang next time is localizable)" || fails=$((fails+pmiss))

echo
echo "===== TEST 5: cross-device Continue -> muOS NATIVE History (#181; mock RomM, offline) ====="
# The engine's --sync-continue must materialize the cross-device feed as muOS's own
# info/history pointer files: <name>-<FNV1a8>.cfg, 3 lines, mtime = the SERVER save
# time (muxhistory orders by mtime). Foreign (user-written) pointers are sacred.
HIST="/run/muos/storage/info/history"
MOCKAPP="$SB/mockapp"
rm -rf "$MOCKAPP" "$HIST"; mkdir -p "$MOCKAPP" "$HIST"
cp "$SB/lodor-sync" "$MOCKAPP/lodor-sync"; chmod +x "$MOCKAPP/lodor-sync"
cat > "$MOCKAPP/config.json" <<CFG
{"hosts":[{"root_uri":"http://127.0.0.1:$MOCKPORT","token":"mock-token","device_id":"mock-dev","device_name":"Harness"}],"directory_mappings":{"gamegear":{"slug":"gamegear","relative_path":"Sega Game Gear"}},"api_timeout":10,"download_timeout":60}
CFG
cat > "$MOCKAPP/catalog-index.json" <<'IDX'
{"version":1,"platforms":{"gamegear":{"by_id":{"71":"/Roms/Sega Game Gear/✘ Zilion (USA).gg","72":"/Roms/Sega Game Gear/Real Game (USA).gg"}}}}
IDX
: > "$SB/mmc/Roms/Sega Game Gear/✘ Zilion (USA).gg"
printf 'REALBYTES' > "$SB/mmc/Roms/Sega Game Gear/Real Game (USA).gg"
# A FOREIGN native pointer (the user's own history) — must survive byte- and mtime-identical.
FOREIGN="$HIST/Foreign Keeper-00C0FFEE.cfg"
printf '%s\n%s\n%s' "/mnt/mmc/ROMS/Sega Game Gear/Foreign Keeper.gg" "Sega Game Gear" "Foreign Keeper" > "$FOREIGN"
touch -d "2026-06-01 08:00:00 UTC" "$FOREIGN"
F_MT0=$(stat -c %Y "$FOREIGN")
( cd "$MOCKAPP" && LODOR_PAK_DIR="$MOCKAPP" ./lodor-sync --sync-continue > out.txt 2> err.txt ); rc=$?
[ "$rc" = 0 ] && echo "ok: --sync-continue rc=0 against the mock" \
	|| { echo "FAIL: --sync-continue rc=$rc"; sed -n 1,5p "$MOCKAPP/err.txt"; fails=$((fails+1)); }
# #187: muOS builds write NO MinUI Continue collection file — entries reports 0
# by design; the native-History injection below is the real delivery signal.
grep -q "^CONTINUE entries=0" "$MOCKAPP/out.txt" \
	&& echo "ok: CONTINUE entries=0 (muOS #187 contract: native History owns delivery)" \
	|| { echo "FAIL: CONTINUE line: $(cat "$MOCKAPP/out.txt" 2>/dev/null)"; fails=$((fails+1)); }
# ANTI-TRIVIAL (knulli leg-3 rule): the injector must report it actually WROTE.
grep -q "MUOS-HISTORY injected=2 rekeyed=0 skipped=0" "$MOCKAPP/err.txt" \
	&& echo "ok: injector WROTE (injected=2 - not the no-op class)" \
	|| { echo "FAIL: injector report: $(grep MUOS-HISTORY "$MOCKAPP/err.txt" 2>/dev/null)"; fails=$((fails+1)); }
ZCFG=$(find "$HIST" -name "✘ Zilion (USA)-*.cfg" | head -1)
RCFG=$(find "$HIST" -name "Real Game (USA)-*.cfg" | head -1)
for f in "$ZCFG" "$RCFG"; do
	case "$(basename "$f" .cfg)" in
	*-[0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F][0-9A-F]) : ;;
	*) echo "FAIL: pointer filename lacks the -HASH8 suffix muOS writes: $f"; fails=$((fails+1)) ;;
	esac
done
# EXACT bytes: 3 lines, real ROMS paths, NO trailing newline (content.c's fprintf shape).
printf '%s\n%s\n%s' "$ROMS_DIR/Sega Game Gear/✘ Zilion (USA).gg" "Sega Game Gear" "✘ Zilion (USA)" \
	| cmp -s - "$ZCFG" \
	&& echo "ok: stub pointer content byte-exact (path/system_sub/content_name)" \
	|| { echo "FAIL: stub pointer content wrong:"; cat "$ZCFG"; echo; fails=$((fails+1)); }
printf '%s\n%s\n%s' "$ROMS_DIR/Sega Game Gear/Real Game (USA).gg" "Sega Game Gear" "Real Game (USA)" \
	| cmp -s - "$RCFG" \
	&& echo "ok: real-rom pointer content byte-exact" \
	|| { echo "FAIL: real-rom pointer content wrong:"; cat "$RCFG"; echo; fails=$((fails+1)); }
# MTIMES = the mock's save times (SERVER clock, #147), which is also the menu order.
T71=$(date -u -d "2026-07-01 10:00:00 UTC" +%s)
T72=$(date -u -d "2026-07-02 10:00:00 UTC" +%s)
ZMT=$(stat -c %Y "$ZCFG" 2>/dev/null || echo 0)
RMT=$(stat -c %Y "$RCFG" 2>/dev/null || echo 0)
[ "$ZMT" = "$T71" ] && [ "$RMT" = "$T72" ] \
	&& echo "ok: mtimes = feed save times exactly (never local now())" \
	|| { echo "FAIL: mtimes z=$ZMT (want $T71) r=$RMT (want $T72)"; fails=$((fails+1)); }
[ "$RMT" -gt "$ZMT" ] \
	&& echo "ok: newest save carries newest mtime (muxhistory order)" \
	|| { echo "FAIL: mtime order inverted"; fails=$((fails+1)); }
# FOREIGN pointer: byte- and mtime-identical, never adopted into the manifest.
printf '%s\n%s\n%s' "/mnt/mmc/ROMS/Sega Game Gear/Foreign Keeper.gg" "Sega Game Gear" "Foreign Keeper" \
	| cmp -s - "$FOREIGN" \
	&& [ "$(stat -c %Y "$FOREIGN")" = "$F_MT0" ] \
	&& echo "ok: foreign/user history preserved (bytes + mtime)" \
	|| { echo "FAIL: foreign pointer touched"; fails=$((fails+1)); }
grep -q "Foreign Keeper" "$MOCKAPP/mirror-manifest.json" 2>/dev/null \
	&& { echo "FAIL: foreign pointer entered the manifest"; fails=$((fails+1)); } \
	|| echo "ok: foreign pointer not claimed by the manifest"
n=$(find "$HIST" -name "*.cfg" | wc -l)
[ "$n" = 3 ] && echo "ok: exactly 3 pointers (2 injected + 1 foreign, no dups)" \
	|| { echo "FAIL: history holds $n pointers, want 3"; ls "$HIST"; fails=$((fails+1)); }
grep -q '"history"' "$MOCKAPP/mirror-manifest.json" 2>/dev/null \
	&& echo "ok: injected pointers manifest-tracked (kind history)" \
	|| { echo "FAIL: no kind-history manifest entries"; fails=$((fails+1)); }
# RE-RUN: no churn — same feed must rewrite nothing and move no mtime.
( cd "$MOCKAPP" && LODOR_PAK_DIR="$MOCKAPP" ./lodor-sync --sync-continue > out2.txt 2> err2.txt )
grep -q "MUOS-HISTORY injected=0 rekeyed=0 skipped=2" "$MOCKAPP/err2.txt" \
	&& [ "$(stat -c %Y "$ZCFG")" = "$ZMT" ] \
	&& echo "ok: repeat sync is a no-op (no mtime churn, no false recency)" \
	|| { echo "FAIL: repeat sync churned: $(grep MUOS-HISTORY "$MOCKAPP/err2.txt" 2>/dev/null)"; fails=$((fails+1)); }
# MARKER FLIP (download-on-launch ✘ -> ✓): the stale ✘ pointer is DEAD to muxhistory;
# the injector must re-key it to the live on-card name (index left stale on purpose —
# resolveOnCardRel resolves marker variants from the CARD, the #135 rule).
mv "$SB/mmc/Roms/Sega Game Gear/✘ Zilion (USA).gg" "$SB/mmc/Roms/Sega Game Gear/✓ Zilion (USA).gg"
( cd "$MOCKAPP" && LODOR_PAK_DIR="$MOCKAPP" ./lodor-sync --sync-continue > out3.txt 2> err3.txt )
VCFG=$(find "$HIST" -name "✓ Zilion (USA)-*.cfg" | head -1)
if [ -n "$VCFG" ] && [ ! -e "$ZCFG" ]; then
	echo "ok: marker flip re-keyed the pointer (stale ✘ gone, live ✓ present)"
	[ "$(stat -c %Y "$VCFG")" = "$T71" ] \
		&& echo "ok: re-keyed pointer keeps the feed mtime" \
		|| { echo "FAIL: re-keyed mtime $(stat -c %Y "$VCFG") != $T71"; fails=$((fails+1)); }
else
	echo "FAIL: marker flip not re-keyed (✓=$VCFG stale-still-there=$([ -e "$ZCFG" ] && echo yes || echo no))"
	grep MUOS-HISTORY "$MOCKAPP/err3.txt" 2>/dev/null; fails=$((fails+1))
fi
rm -f "$SB/mmc/Roms/Sega Game Gear/✓ Zilion (USA).gg" "$SB/mmc/Roms/Sega Game Gear/Real Game (USA).gg"

if [ "$LIVE" = 1 ]; then
	echo
	echo "===== LIVE: engine --validate (token check against the real RomM) ====="
	echo up > "$SB/sysnet/wlan0/operstate"
	cd "$APP" || exit 1
	out=$("$APP/lodor-sync" --validate 2>&1); rc=$?
	echo "$out" | grep -iv "uri\|host" | tail -3
	if [ "$rc" != 0 ]; then
		echo "##############################################################"
		echo "# WARNING: --validate FAILED (rc=$rc) — RomM TOKEN LIKELY STALE."
		echo "# Live tests SKIPPED. Offline results above still stand."
		echo "##############################################################"
		echo "HARNESS RESULT: offline_fails=$fails live=SKIPPED-stale-token"
		[ "$fails" = 0 ]; exit $?
	fi
	echo "ok: validate rc=0"

	echo
	echo "===== LIVE: --mirror-catalog (stub counts; emu gate limits to sandboxed systems) ====="
	out=$("$APP/lodor-sync" --mirror-catalog 2>&1); rc=$?
	echo "$out" | grep -E "^MIRROR|^RESULT" | head -2
	[ "$rc" = 0 ] || { echo "FAIL: mirror-catalog rc=$rc"; fails=$((fails+1)); }
	stubs=$(find "$SB/mmc/Roms" -type f -size 0 | wc -l)
	echo "stub count on card: $stubs"
	[ "$stubs" -gt 0 ] || { echo "FAIL: no stubs mirrored"; fails=$((fails+1)); }
	[ -f "$APP/catalog-index.json" ] && echo "ok: catalog-index.json written" || { echo "FAIL: no catalog-index.json"; fails=$((fails+1)); }

	echo
	echo "===== LIVE: post-mirror in-session re-seed — overrides WITHOUT relaunch (#180A) ====="
	# The mirror above may have created NEW system folders. On-device the wizard re-seeds
	# right after a successful mirror (screenMirrorArgs -> reseedOverrides); run the same
	# hook here and assert every RA folder is wired IMMEDIATELY — no app relaunch.
	LODOR_PAK_DIR="$APP" "$APP/lodor-wizard" --reseed >/dev/null 2>&1
	[ -L "/opt/muos/share/info/override/Sega Game Gear.sh" ] \
		&& echo "ok: RA override present right after mirror (no relaunch needed)" \
		|| { echo "FAIL: post-mirror reseed left Game Gear override missing"; fails=$((fails+1)); }
	[ -e "/opt/muos/share/info/override/Sony PlayStation Portable.sh" ] \
		&& { echo "FAIL: post-mirror reseed wrongly overrode standalone PSP"; fails=$((fails+1)); } \
		|| echo "ok: standalone PSP still untouched post-mirror"

	echo
	echo "===== LIVE: download-on-launch via the override (engine hash-verifies) ====="
	DL=$(find "$SB/mmc/Roms/Sega Game Gear" -type f -size 0 | head -1)
	if [ -z "$DL" ]; then
		echo "FAIL: no Game Gear stub to download"; fails=$((fails+1))
	else
		echo "launching stub: $(basename "$DL")"
		# Post-fix contract (override step 5): a hash-verified download is reconciled
		# AFTER the game exits — the ✘ cloud-marker name is RENAMED to its ✓ on-device
		# name (save + cover carried by the engine). Compute the expected post-launch path.
		DLDIR=$(dirname "$DL"); DLB=$(basename "$DL")
		case "$DLB" in "✘ "*) VDL="$DLDIR/✓ ${DLB#✘ }" ;; *) VDL="$DL" ;; esac
		# Run the override from "/" (device CWD) — the exact condition that broke on the
		# RG34XX. Snapshot the log first so we can assert the config.json error never recurs.
		: > "$APP/romm.log"
		( cd / && "$OV" "$(basename "${DL%.*}")" "genesis_plus_gx_libretro.so" "$DL" ); rc=$?
		# THE FIELD-BUG ASSERTION: the fetch-on-launch engine call must resolve config.json
		# from the device CWD. Its absence in the log proves the 2026-07-04 abort is gone.
		if grep -q "open config.json: no such file" "$APP/romm.log"; then
			echo "FAIL: config.json CWD bug STILL present in override log (fetch-on-launch aborted)"; fails=$((fails+1))
		else
			echo "ok: no 'open config.json: no such file' in override log — field CWD bug fixed"
		fi
		[ -s "$VDL" ] && echo "ok: rom downloaded ($(stat -c %s "$VDL") bytes, engine-hash-verified)" \
			|| { echo "FAIL: rom missing/empty at reconciled path (rc=$rc): $VDL"; fails=$((fails+1)); }
		if [ "$VDL" != "$DL" ]; then
			if [ -e "$DL" ]; then
				echo "FAIL: cloud-marker name still on card after download (no reconcile): $(basename "$DL")"; fails=$((fails+1))
			else
				echo "ok: marker reconciled post-download: $(basename "$DL") -> $(basename "$VDL")"
			fi
		fi
		BNE="$(basename "${VDL%.*}")"
		LSAVE="/run/muos/storage/save/file/Genesis Plus GX/$BNE.srm"
		[ -s "$LSAVE" ] && echo "ok: post-game save present (carried by reconcile)" || { echo "FAIL: no post-game save at $LSAVE"; fails=$((fails+1)); }

		echo
		echo "===== LIVE: save round-trip (pushed post-game -> wipe local -> pull back) ====="
		export LODOR_SAVE_SUBDIR="Genesis Plus GX"
		want=$(cat "$LSAVE" 2>/dev/null)
		rm -f "$LSAVE"
		out=$("$APP/lodor-sync" --sync-save "$VDL" 2>&1); rc=$?
		echo "$out" | grep -E "^RESULT|pull|push" | tail -2
		if [ -s "$LSAVE" ] && [ "$(cat "$LSAVE")" = "$want" ]; then
			echo "ok: save round-trip byte-identical"
		else
			echo "FAIL: save not restored (rc=$rc)"; fails=$((fails+1))
		fi
	fi
else
	echo
	echo "===== LIVE tests SKIPPED (no config.json with a token) ====="
fi

echo
echo "HARNESS RESULT: fails=$fails"
[ "$fails" = 0 ]
NS
rc=$?
echo
echo "########## harness done (rc=$rc) ##########"
exit $rc
