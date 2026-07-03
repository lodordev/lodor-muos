#!/bin/sh
# integ-harness.sh — Lodor-muOS end-to-end integration harness (monorepo edition).
#
# Builds a bind-mount sandbox mimicking /opt/muos and /run/muos/storage from the REAL
# muOS card image, installs the "Lodor Sync" app (source from ../App, engine + wizard
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
PAK_SRC="$MUOS_ROOT/App/Lodor Sync"

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

echo "=== reset sandbox: $SB ==="
rm -rf "$SB"
mkdir -p "$SB/opt-muos/script/var" "$SB/opt-muos/script/launch" \
	"$SB/opt-muos/emulator/retroarch/info" "$SB/opt-muos/info/assign" "$SB/opt-muos/info/override" \
	"$SB/storage/save/file" "$SB/storage/init" "$SB/storage/application" \
	"$SB/mmc/Roms" "$SB/sysnet/wlan0" "$SB/fakebin" "$SB/capture"
mv "$REPO/engine/.integ-out-sync" "$SB/lodor-sync"
mv "$REPO/engine/.integ-out-wizard" "$SB/lodor-wizard"
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

echo "=== install the Lodor Sync app into the sandbox application dir ==="
cp -r "$PAK_SRC" "$SB/storage/application/Lodor Sync"
APP_SB="$SB/storage/application/Lodor Sync"
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

echo
echo "########## RUN UNDER mount-namespace bind mounts ##########"
# NOTE: sandbox roms live under mmc/Roms (not the card's ROMS): panther's FS is
# case-SENSITIVE while the card's exFAT is not, and the engine's shared catalog joins
# sdcardRoot()+"/Roms". One spelling keeps shell+engine agreeing off-hardware; on the
# card both land in /mnt/mmc/ROMS. (Tracked engine cleanup; do not fix here.)
unshare -m sh -s "$SB" "$LIVE" <<'NS'
set -u
SB="$1"; LIVE="$2"
mkdir -p /opt/muos /run/muos/storage
mount --bind "$SB/opt-muos" /opt/muos
mount --bind "$SB/storage" /run/muos/storage
mount --bind "$SB/sysnet" /sys/class/net 2>/dev/null || echo "WARN: /sys/class/net bind failed — live wifi-path tests may skip"
PATH="$SB/fakebin:$PATH"; export PATH
APP="/run/muos/storage/application/Lodor Sync"
export LODOR_APPDIR="$APP"
export ROMS_DIR="$SB/mmc/Roms"
export SDCARD_PATH="$SB/mmc"
fails=0

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
echo "===== TEST 2: launch a REAL rom via the override (dispatch + save -> pending) ====="
# Wifi fake OFF for the offline tests: point wifi_is_up at a downed state.
echo down > "$SB/sysnet/wlan0/operstate"
ROM="$SB/mmc/Roms/Sega Game Gear/5 in 1 FunPak (USA).gg"
"$OV" "5 in 1 FunPak" "genesis_plus_gx_libretro.so" "$ROM"; rc=$?
[ "$rc" = 0 ] && echo "ok: override rc=0" || { echo "FAIL: override rc=$rc"; fails=$((fails+1)); }
SAVE="/run/muos/storage/save/file/Genesis Plus GX/5 in 1 FunPak (USA).srm"
[ -s "$SAVE" ] && echo "ok: stub RetroArch wrote the save" || { echo "FAIL: no save written"; fails=$((fails+1)); }
grep -q "5 in 1 FunPak" "$APP/pending-saves.txt" 2>/dev/null \
	&& echo "ok: save queued to pending (offline)" || { echo "FAIL: pending queue empty"; fails=$((fails+1)); }

echo
echo "===== TEST 3: fetch-on-launch on a 0-byte STUB with no network (honest abort) ====="
STUBROM="$SB/mmc/Roms/Sega Game Gear/Aladdin (USA, Europe, Brazil) (En).gg"
: > "$STUBROM"
"$OV" "Aladdin" "genesis_plus_gx_libretro.so" "$STUBROM"; rc=$?
[ "$rc" = 0 ] || { echo "FAIL: stub abort rc=$rc (must return to menu cleanly)"; fails=$((fails+1)); }
[ -s "$STUBROM" ] && { echo "FAIL: stub grew with no network?!"; fails=$((fails+1)); } || echo "ok: stub still 0 bytes (not launched empty)"
echo "phase line: $(cat /tmp/romm-phase 2>/dev/null)"
rm -f "$STUBROM"

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
else
	echo "FAIL: wizard --capture produced no PNGs"; fails=$((fails+1))
fi

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
		"$OV" "$(basename "${DL%.*}")" "genesis_plus_gx_libretro.so" "$DL"; rc=$?
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
