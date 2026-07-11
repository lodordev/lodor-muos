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
	for d in "$MUOS_STORE_DIR/application/Lodor" \
	         /mnt/mmc/MUOS/application/Lodor \
	         /mnt/sdcard/MUOS/application/Lodor; do
		[ -d "$d" ] && { echo "$d"; return 0; }
	done
	echo "$MUOS_STORE_DIR/application/Lodor"
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

# --- seed gate (#180B) ------------------------------------------------------------------
# Shared by mux_launch.sh (the launch gate), lodor-seed.sh (post-seed stamping) and the
# wizard's post-mirror re-seed. The stamp records the SETTLED post-seed signal; a launch
# whose live signal matches it skips the seeder entirely.
SEED_STAMP="$DATA_DIR/.seed-stamp"

# lodor_seed_signal: sorted rom SUBDIR names + a marker + sorted Lodor override SYMLINK
# names, hashed. Directories only (glob trailing-slash), so transient FILES churning in
# ROMS (box-art, index/lock files) never move it; the override half is restricted to OUR
# symlinks so muOS's own override files (if any) don't either. Changes ONLY when a
# re-seed could change the outcome: a new/removed system folder, or a missing/extra
# Lodor override (reheal: deleting an override flips the signal and forces a re-seed).
lodor_seed_signal() {
	_ssig_roms="${ROMS_DIR:-$(lodor_roms_dir)}"
	_ssig_ovr="$MUOS_SHARE_DIR/info/override"
	{
		for _ssig_d in "$_ssig_roms"/*/; do
			[ -d "$_ssig_d" ] || continue
			_ssig_d=${_ssig_d%/}; printf '%s\n' "${_ssig_d##*/}"
		done
		printf '@overrides@\n'
		for _ssig_o in "$_ssig_ovr"/*.sh; do
			[ -L "$_ssig_o" ] || continue
			_ssig_o=${_ssig_o%.sh}; printf '%s\n' "${_ssig_o##*/}"
		done
	} | sort | (md5sum 2>/dev/null || cksum) | awk '{print $1}'
}

# lodor_seed_gated <seed-script>: run the seeder only when the live signal differs from
# the stamp. ROOT CAUSE of the 2026-07-05 RG40XXV field bug (#180B, gate from edf76bd):
# the old skip condition ALSO required at least one override symlink to exist
# (have_override) as a "reheal" belt — but ZERO overrides is a legitimate settled state
# (fresh install before the first mirror, or an all-standalone library), so the gate
# could never skip there and re-seeded every launch with an IDENTICAL sig. The signal
# already encodes the override set (a deleted override changes it), so the extra
# conjunct was redundant where it was right and wrong where it mattered. Sig match =
# skip, full stop. The stamp itself is written by lodor-seed.sh AFTER a successful seed
# (settled state), so every seed path — launch, boot hook, wizard post-mirror — leaves
# a fresh stamp.
lodor_seed_gated() {
	_sg_cur="$(lodor_seed_signal)"
	_sg_old="$(cat "$SEED_STAMP" 2>/dev/null)"
	if [ -n "$_sg_cur" ] && [ "$_sg_cur" = "$_sg_old" ]; then
		log "seed-gate: unchanged (sig $_sg_cur) - skip"
		return 0
	fi
	if "$1" >> "$LOG" 2>&1; then
		log "seed-gate: re-seeded + re-stamped (sig $(cat "$SEED_STAMP" 2>/dev/null))"
		return 0
	fi
	log "seed-gate: seeder FAILED (stamp left as-is; will retry next launch)"
	return 1
}

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

# --- transfer coordination mutex (ported from lodoros/nextui, liveness-correct) ----------
# Serializes ENGINE TRANSFERS across the daemon, romm-run (the app path), and anything else
# that syncs. Pure coordination — NO radio control (wifi_bring_up owns the network answer on
# this lane). mkdir-atomic; fg preempts a preemptible (push) holder so a user action never
# waits on a background save upload; bg (the daemon) never preempts and is never preempted.
# Reclaim ONLY a dead/absent owner — a LIVE holder keeps the mutex no matter how old its ts
# (long downloads are legitimate); the age constant is a tiebreak ONLY when kill -0 can't
# answer (unparseable owner pid).
_WIFI_LOCK="/tmp/romm-wifi.lock"
_WIFI_STALE=180   # age tiebreak: only consulted when owner liveness is inconclusive

# True while a LIVE actor holds the mutex (dead/absent-owner locks read as free).
_actor_active() {
	[ -d "$_WIFI_LOCK" ] || return 1
	o=$(cat "$_WIFI_LOCK/owner" 2>/dev/null); t=$(cat "$_WIFI_LOCK/ts" 2>/dev/null || echo 0); n=$(date +%s)
	case "$o" in
		'') return 1 ;;
		*[!0-9]*) [ $((n - t)) -le "$_WIFI_STALE" ] ;;
		*) kill -0 "$o" 2>/dev/null ;;
	esac
}

# wifi_acquire [mode]  mode: fg = user action (preempts a push holder) | push = post-game
# save upload (preemptible by fg) | bg = daemon (default). Returns 0 = mutex held (caller
# MUST wifi_release), 2 = busy (a live, non-preemptible holder). Never touches the radio.
wifi_acquire() {
	_acq_mode="${1:-bg}"
	while :; do
		if mkdir "$_WIFI_LOCK" 2>/dev/null; then
			echo "$$" > "$_WIFI_LOCK/owner"; date +%s > "$_WIFI_LOCK/ts"
			if [ "$_acq_mode" = push ]; then echo 1 > "$_WIFI_LOCK/preempt"; else rm -f "$_WIFI_LOCK/preempt" 2>/dev/null; fi
			[ "$(cat "$_WIFI_LOCK/owner" 2>/dev/null)" = "$$" ] && break
			continue   # reclaimed during our setup window — re-evaluate
		fi
		owner=$(cat "$_WIFI_LOCK/owner" 2>/dev/null)
		ts=$(cat "$_WIFI_LOCK/ts" 2>/dev/null || echo 0); now=$(date +%s)
		_reclaim=0
		case "$owner" in
			'') _reclaim=1 ;;                                                   # absent owner
			*[!0-9]*) [ $((now - ts)) -gt "$_WIFI_STALE" ] && _reclaim=1 ;;     # unparseable: age tiebreak
			*) kill -0 "$owner" 2>/dev/null || _reclaim=1 ;;                    # parseable: liveness decides
		esac
		if [ "$_reclaim" = 1 ]; then
			rm -f "$_WIFI_LOCK/owner" "$_WIFI_LOCK/ts" "$_WIFI_LOCK/preempt" 2>/dev/null
			rmdir "$_WIFI_LOCK" 2>/dev/null
			continue   # retry the atomic mkdir; if we lose, we re-evaluate the new owner
		fi
		if [ "$_acq_mode" = fg ] && [ "$(cat "$_WIFI_LOCK/preempt" 2>/dev/null)" = 1 ]; then
			log "mutex PREEMPT push owner=$owner (fg incoming)"
			kill -TERM "-$owner" 2>/dev/null || kill -TERM "$owner" 2>/dev/null
			j=0; while kill -0 "$owner" 2>/dev/null && [ "$j" -lt 30 ]; do sleep 0.1; j=$((j + 1)); done
			continue   # holder dying -> loop reclaims the now-free lock
		fi
		log "wifi_acquire BUSY owner=$owner mode=$_acq_mode"
		return 2
	done
	return 0
}

# wifi_release — drop the mutex ONLY (owner-scoped: a trap/racer never disturbs another
# actor's transfer). Never touches the radio.
wifi_release() {
	if [ "$(cat "$_WIFI_LOCK/owner" 2>/dev/null)" = "$$" ]; then
		rm -f "$_WIFI_LOCK/owner" "$_WIFI_LOCK/ts" "$_WIFI_LOCK/preempt" 2>/dev/null
		rmdir "$_WIFI_LOCK" 2>/dev/null
	fi
	return 0
}

# wifi_lock_refresh — bump the held lock's ts (owner-scoped; no-op otherwise). Long-cycle
# holders (the daemon between engine calls) call this so a reader that can't verify our
# liveness (unparseable-owner tiebreak) never mistakes a working holder for a stale one.
wifi_lock_refresh() {
	[ "$(cat "$_WIFI_LOCK/owner" 2>/dev/null)" = "$$" ] && date +%s > "$_WIFI_LOCK/ts" 2>/dev/null
	return 0
}

# lodor_ensure_device - quiet first-run heal (ported from Knulli, 6b29c2c): a preseeded or
# card-cloned config carries a token but NO device_id (the release device-state strip is
# the contract), and every save-sync engine mode hard-requires one - so saves would
# silently never sync until a full re-onboarding. When the config is paired but
# unregistered AND the caller already established the network side, register ONCE.
# Name source: the wizard's default is only a keyboard preset ("RG34XX"), not derivable
# here - so board devicetree model, else hostname, else "handheld". Callers proceed
# regardless of the outcome: on failure the engine keeps refusing loudly (honest), and
# the next reachable save-sync call retries.
lodor_ensure_device() {
	[ -f "$DATA_DIR/config.json" ] || return 1
	grep -q '"device_id"' "$DATA_DIR/config.json" 2>/dev/null && return 0
	grep -q '"token"' "$DATA_DIR/config.json" 2>/dev/null || return 1
	_dn=$({ tr -d '\0' < /sys/firmware/devicetree/base/model; } 2>/dev/null)
	[ -n "$_dn" ] || _dn=$(hostname 2>/dev/null)
	[ -n "$_dn" ] || _dn="handheld"
	log "paired-but-unregistered config - registering device as: $_dn"
	phase "First run - registering this device..."
	( cd "$DATA_DIR" 2>/dev/null && "$BIN" --register-device "$_dn" ) >> "$LOG" 2>&1 \
		|| log "device registration failed (will retry next time the server is reachable)"
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
