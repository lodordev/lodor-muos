#!/bin/sh
# romm-sync-lib.sh - shared muOS Lodor library. Sourced by lodor-override.sh, romm-run,
# romm-syncd, and mux_launch.sh.  MARKER: LODOR_MUOS_LIB
#
# HARD PRINCIPLES (carried from the MinUI build, learned the hard way):
#  1. LEAN ON muOS'S STOCK MECHANISMS. Wi-Fi and game launching are muOS's job - we use
#     its wpa_supplicant/dhcpcd/iw path and its lr-general.sh launcher, we do not reinvent
#     them. (On MinUI we reinvented DHCP and broke a working stock client. Never again.)
#  2. HONEST UI. Every status line written to /tmp/romm-phase reflects CONFIRMED state.
#     On failure we write the SPECIFIC real reason, never fake forward-progress.
#  3. DETECT-AND-REHEAL. muOS moves paths between releases; resolve them live from
#     func.sh + the card's own files, never hardcode a release's layout.
#
# CGO-free shell; no bashisms beyond POSIX sh (muOS uses busybox/dash-style sh).

# --- muOS environment (detect-and-reheal: source func.sh for the canonical vars) -------
MUOS_FUNC="/opt/muos/script/var/func.sh"
[ -f "$MUOS_FUNC" ] && . "$MUOS_FUNC" 2>/dev/null
# Fallbacks if func.sh wasn't present (sandbox/off-hardware): honor env overrides.
: "${MUOS_SHARE_DIR:=/opt/muos/share}"
: "${MUOS_STORE_DIR:=/run/muos/storage}"

# Launch-script dir (lr-general.sh etc.) - reheal-located, never assumed.
lodor_launch_dir() {
	for d in /opt/muos/script/launch "$MUOS_SHARE_DIR/../script/launch"; do
		[ -d "$d" ] && { echo "$d"; return 0; }
	done
	echo "/opt/muos/script/launch"
}

# RetroArch core .info dir (corename source). Reheal: read libretro_info_path from the
# base config if present, else the known 2601 location.
lodor_info_dir() {
	if [ -n "${LODOR_INFO_DIR:-}" ]; then echo "$LODOR_INFO_DIR"; return 0; fi
	cfg="$MUOS_SHARE_DIR/emulator/retroarch/retroarch.default.cfg"
	if [ -f "$cfg" ]; then
		p=$(sed -n 's/^libretro_info_path *= *"\(.*\)"/\1/p' "$cfg" | head -1)
		[ -n "$p" ] && [ -d "$p" ] && { echo "$p"; return 0; }
	fi
	echo "$MUOS_SHARE_DIR/emulator/retroarch/info"
}

# --- App + data locations --------------------------------------------------------------
# APPDIR is where the engine binary + scripts live (the installed .muxapp). Resolve from
# the active storage mount so it follows an SD1->SD2 storage migration without re-stamp.
lodor_appdir() {
	if [ -n "${LODOR_APPDIR:-}" ]; then echo "$LODOR_APPDIR"; return 0; fi
	for d in "$MUOS_STORE_DIR/application/Lodor Sync" \
	         /mnt/mmc/MUOS/application/"Lodor Sync" \
	         /mnt/sdcard/MUOS/application/"Lodor Sync"; do
		[ -d "$d" ] && { echo "$d"; return 0; }
	done
	echo "$MUOS_STORE_DIR/application/Lodor Sync"
}

APPDIR="$(lodor_appdir)"
BIN="$APPDIR/lodor-sync"
DATA_DIR="$APPDIR"                       # config.json, catalog-index.json, pending live here
LOG="$DATA_DIR/romm.log"
PHASE="/tmp/romm-phase"                  # honest one-line status the app/splash reads
PROGRESS="/tmp/dl-progress"              # 0..100 the engine writes during downloads
INGAME_LOCK="/tmp/romm-in-game"
PENDING="$DATA_DIR/pending-saves.txt"

# ROMs live on the device's rom mount (mmc or sdcard) - ask muOS, don't assume.
lodor_roms_dir() {
	if [ -n "${ROMS_DIR:-}" ]; then echo "$ROMS_DIR"; return 0; fi
	if command -v GET_VAR >/dev/null 2>&1; then
		m="$(GET_VAR "device" "storage/rom/mount" 2>/dev/null)"
		[ -n "$m" ] && [ -d "$m/ROMS" ] && { echo "$m/ROMS"; return 0; }
	fi
	for d in /mnt/mmc/ROMS /mnt/sdcard/ROMS; do
		[ -d "$d" ] && { echo "$d"; return 0; }
	done
	echo "/mnt/mmc/ROMS"
}

log() { echo "$(date +'%F %T') $*" >> "$LOG" 2>/dev/null; }
phase() { echo "$1" > "$PHASE" 2>/dev/null; }   # HONEST: only call with a confirmed-true line

# Export the env the engine needs. ROMS_DIR/SAVES_DIR/BIOS_DIR default correctly inside
# the muOS engine build, but we pin ROMS_DIR to the live rom mount and the pak dir here.
lodor_export_env() {
	# LODOR_PAK_DIR is the canonical app-working-dir env (engine PakDir() + wizard);
	# LODOR_DATA_DIR is kept ONLY as a back-compat alias for older scripts.
	export LODOR_PAK_DIR="$DATA_DIR"
	export LODOR_DATA_DIR="$DATA_DIR"
	ROMS_DIR="$(lodor_roms_dir)"
	export ROMS_DIR
	# SDCARD_PATH: the engine's shared catalog code joins sdcardRoot()+"/Roms" under this
	# root. Pin it to the live rom mount's parent (default /mnt/mmc); exFAT/vfat case-
	# insensitivity makes ".../Roms" land in .../ROMS on-card. (Tracked ENGINE cleanup —
	# do not "fix" the Roms/ROMS case here in shell.)
	if [ -z "${SDCARD_PATH:-}" ]; then
		SDCARD_PATH="$(dirname "$ROMS_DIR")"
		[ -d "$SDCARD_PATH" ] || SDCARD_PATH="/mnt/mmc"
	fi
	export SDCARD_PATH
	# SAVES_DIR / BIOS_DIR: let the muOS engine defaults stand (/run/muos/storage/...).
	# TLS: the engine is a static Go binary; point Go's TLS at a CA bundle so HTTPS RomM
	# servers verify. Prefer our bundled certs, fall back to the system store if present.
	if [ -z "${SSL_CERT_FILE:-}" ]; then
		for c in "$APPDIR/certs/ca-certificates.crt" /etc/ssl/certs/ca-certificates.crt; do
			[ -f "$c" ] && { export SSL_CERT_FILE="$c"; break; }
		done
	fi
}

# --- corename resolution: CORE (.so) -> RetroArch save folder (detect-and-reheal) ------
# RetroArch sorts savefiles into save/file/<corename>/. corename is the libretro core's
# display name, read from the card's own <core>.info - NOT guessable from the .so name
# (pcsx_rearmed_libretro.so -> "PCSX-ReARMed"). This is the version-proof source.
lodor_corename_for() {
	_core="$1"   # e.g. pcsx_rearmed_libretro.so
	[ -n "$_core" ] || return 1
	_info="$(lodor_info_dir)/${_core%.so}.info"
	if [ -f "$_info" ]; then
		_cn=$(sed -n 's/^corename *= *"\(.*\)"/\1/p' "$_info" | head -1)
		[ -n "$_cn" ] && { echo "$_cn"; return 0; }
	fi
	return 1   # caller falls back to the engine's default-core map (no env export)
}

# --- Wi-Fi: lean on muOS's stock path. HARDWARE-DEFERRED verification. -----------------
# muOS owns Wi-Fi (wpa_supplicant -B + dhcpcd, creds in config/network/*). We do NOT
# bring up a custom client. We (a) check if it's already up, and (b) ask muOS to connect
# via its own network script, then gate on association + a real IP. Honest status only.
wifi_is_up() {
	[ "$(cat /sys/class/net/wlan0/operstate 2>/dev/null)" = "up" ] || return 1
	ip addr show wlan0 2>/dev/null | grep -q "inet " || return 1
	return 0
}

# wifi_bring_up: trigger muOS's stock connect (if creds exist) and wait, bounded, for a
# verified link. Returns 0 only on a CONFIRMED online link. Writes honest phase lines.
# NOTE: on-hardware verification pending (RG34XX, RTL8821CS). Off-hardware this no-ops to
# "already up?" so the sandbox can exercise everything downstream.
wifi_bring_up() {
	wifi_is_up && { phase "Wi-Fi already connected"; return 0; }
	_ssid=""
	command -v GET_VAR >/dev/null 2>&1 && _ssid="$(GET_VAR "config" "network/ssid" 2>/dev/null)"
	if [ -z "$_ssid" ]; then phase "No Wi-Fi network configured"; return 1; fi
	phase "Connecting to $_ssid..."
	# Lean on muOS's own connector. Its script name has moved across releases - reheal.
	for nsc in /opt/muos/script/system/network.sh /opt/muos/script/web/ssid.sh; do
		[ -x "$nsc" ] && { "$nsc" connect >/dev/null 2>&1 || "$nsc" >/dev/null 2>&1; break; }
	done
	_w=0
	while [ "$_w" -lt 30 ]; do
		wifi_is_up && { phase "Connected to $_ssid"; return 0; }
		sleep 1; _w=$((_w + 1))
	done
	phase "Couldn't connect to $_ssid"   # SPECIFIC, honest - no fake success
	return 1
}

# --- clock: bounded NTP after we're online (true post-online step) ---------------------
set_clock_bounded() {
	command -v ntpd >/dev/null 2>&1 || return 0
	phase "Setting the clock..."
	( ntpd -q -n -p pool.ntp.org >/dev/null 2>&1 ) & _cp=$!
	_w=0; while kill -0 "$_cp" 2>/dev/null && [ "$_w" -lt 15 ]; do sleep 1; _w=$((_w + 1)); done
	kill -0 "$_cp" 2>/dev/null && { kill -9 "$_cp" 2>/dev/null; killall -9 ntpd 2>/dev/null; }
	return 0
}

# --- charging gate (daemon): RG34XX AXP sysfs. HARDWARE-DEFERRED node confirmation. ----
is_charging() {
	for n in /sys/class/power_supply/axp2202-battery/status \
	         /sys/class/power_supply/*/status; do
		[ -f "$n" ] || continue
		s="$(cat "$n" 2>/dev/null)"
		[ "$s" = "Charging" ] || [ "$s" = "Full" ] && return 0
	done
	return 1
}

creds_present() {
	[ -f "$DATA_DIR/config.json" ] || return 1
	grep -q '"token"' "$DATA_DIR/config.json" 2>/dev/null || grep -q '"password"' "$DATA_DIR/config.json" 2>/dev/null
}

not_in_game() {
	[ -f "$INGAME_LOCK" ] || return 0
	_p="$(cat "$INGAME_LOCK" 2>/dev/null)"
	[ -n "$_p" ] && kill -0 "$_p" 2>/dev/null && return 1
	rm -f "$INGAME_LOCK" 2>/dev/null   # stale lock (game killed) - reap
	return 0
}
