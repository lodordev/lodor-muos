# shellcheck shell=sh
# (sourced library — no shebang; the sourcing script sets the shell)
# tailscale-lib.sh (muOS / Allwinner H700, RG34XX) — tier-1 (Tailscale) bring-up + sign-in.
#
# PORT of integrations/nextui/Lodor.pak/lib/tailscale-lib.sh (itself a port of the LodorOS
# fork's lib). The daemon/socket/URL-scrape/status/tier-1 logic below is COPIED VERBATIM from
# that field-tested NextUI lib — only the path derivation + capability gate are muOS-specific:
#   - config.json + all app data live in the muxapp dir (DATA_DIR, from romm-sync-lib.sh),
#     NOT a separate shared config home. tier-1 marker + hostname key off $DATA_DIR/config.json.
#   - the arm64 tailscale binaries are bundled in the muxapp at bin/tailscale/{tailscaled,
#     tailscale} (RG34XX is arm64) — release.sh copies them in from the staged official build.
#   - tailscaled state + log persist under $DATA_DIR/tailscale (the muxapp dir is on the SD,
#     so a QR/interactive sign-in survives reboots without an authkey).
#   - _ts_capable is single-arch (H700 arm64) with a RAM floor, not a TrimUI platform list.
#
# Sourced AFTER romm-sync-lib.sh (it reuses $APPDIR + $DATA_DIR).
#
# DESIGN: userspace-networking means NO /dev/net/tun, NO iptables, NO resolvconf, NO root caps
# beyond running the binary — just a process with a socket that exposes a local SOCKS5 proxy.
# The engine reaches the tier-1 RomM host by socks5h-dialing that proxy (config:
# hosts[].socks5_proxy). RAM is capped (GOGC=10 + GOMEMLIMIT) so the handheld is not starved.
# muOS owns the radio; this only overlays a tunnel on an already-up Wi-Fi link.
#
# SECURITY: the interactive sign-in path uses NO auth key (the user authenticates in a
# browser). The headless authkey path is preserved for parity but no key file ships in the app.

# --- paths / tunables (muOS) -------------------------------------------------
_ts_arch() { case "$(uname -m 2>/dev/null)" in aarch64|arm64) echo arm64 ;; *) echo armhf ;; esac; }
# muOS bundles the (arm64) daemon + CLI in the muxapp. Honor a TS_BIN_DIR override, else the
# app's bin/tailscale. APPDIR/DATA_DIR come from romm-sync-lib.sh (sourced first).
TS_BIN_DIR="${TS_BIN_DIR:-$APPDIR/bin/tailscale}"
_TS_CFG="${_TS_CFG:-$DATA_DIR/config.json}"

TS_STATEDIR="${TS_STATEDIR:-/tmp/lodor-ts-state}"
if command -v nohup >/dev/null 2>&1; then TS_BG=nohup
elif command -v setsid >/dev/null 2>&1; then TS_BG=setsid
else TS_BG=; fi
TS_STATE_PERSIST="${TS_STATE_PERSIST:-$DATA_DIR/tailscale/tailscaled.state}"
TS_SOCK="${TS_SOCK:-/tmp/lodor-tailscaled.sock}"
# Cold-start socket budget: 30s (a cold H700 userspace start can be slow; a shorter wait used
# to KILL the still-starting daemon on the TrimUI field boots — never kill a slow starter).
TS_SOCK_WAIT_SECS="${TS_SOCK_WAIT_SECS:-30}"
TS_SOCKS5_ADDR="${TS_SOCKS5_ADDR:-localhost:1055}"   # MUST match hosts[].socks5_proxy
TS_MEMLIMIT="${TS_MEMLIMIT:-256MiB}"
TS_AUTHKEY_FILE="${TS_AUTHKEY_FILE:-$APPDIR/tailscale.authkey}"
TS_TAGS="${TS_TAGS:-tag:lodor}"
TS_LOG="${TS_LOG:-$DATA_DIR/tailscale/tailscaled.log}"
PLAT="${PLAT:-muos}"
mkdir -p "$(dirname "$TS_LOG")" 2>/dev/null
TS_DAEMON_PID=""


_ts_state_restore() {
	mkdir -p "$TS_STATEDIR" 2>/dev/null
	[ -f "$TS_STATE_PERSIST" ] && [ ! -s "$TS_STATEDIR/tailscaled.state" ] && cp "$TS_STATE_PERSIST" "$TS_STATEDIR/tailscaled.state" 2>/dev/null
	return 0
}
_ts_state_save() {
	[ -s "$TS_STATEDIR/tailscaled.state" ] || return 0
	cmp -s "$TS_STATEDIR/tailscaled.state" "$TS_STATE_PERSIST" 2>/dev/null && return 0
	mkdir -p "$(dirname "$TS_STATE_PERSIST")" 2>/dev/null
	_tsp="$TS_STATE_PERSIST.tmp.$$"
	cp "$TS_STATEDIR/tailscaled.state" "$_tsp" 2>/dev/null && mv -f "$_tsp" "$TS_STATE_PERSIST" 2>/dev/null && sync 2>/dev/null
	return 0
}

ts_log() { printf '%s %s\n' "$(date '+%H:%M:%S' 2>/dev/null)" "$1" >> "$TS_LOG" 2>/dev/null; }

# _ts_sock_present — THE probe for the daemon's control socket. A one-line seam on purpose:
# the off-device sim overrides it with a plain-file check (shell cannot mint unix sockets),
# so the REAL wait/reuse logic below is what the scenarios exercise.
_ts_sock_present() { [ -S "$TS_SOCK" ]; }

# _ts_running_pid — PID of an already-running tailscaled (ours from this session, else any
# on the box via pidof), empty when none. Lets a retry REUSE a daemon that is still starting
# instead of spawning a duplicate — the "address already in use" pile-up on the 2026-07-02
# field boots came from every retry launching another daemon at the same SOCKS5 port.
_ts_running_pid() {
	if [ -n "${TS_DAEMON_PID:-}" ] && kill -0 "$TS_DAEMON_PID" 2>/dev/null; then
		printf '%s' "$TS_DAEMON_PID"
		return 0
	fi
	command -v pidof >/dev/null 2>&1 && pidof tailscaled 2>/dev/null | awk '{print $1}'
	return 0
}

# _ts_spawn_daemon — start userspace tailscaled in the background (all output -> $TS_LOG so
# a dying daemon's own words are captured), recording TS_DAEMON_PID. ONE spawn site, shared
# by tailscale_up and tailscale_up_interactive.
_ts_spawn_daemon() {
	$TS_BG env GOGC=10 GOMAXPROCS=1 GOMEMLIMIT="$TS_MEMLIMIT" "$TS_BIN_DIR/tailscaled" \
		--tun=userspace-networking \
		--socks5-server="$TS_SOCKS5_ADDR" \
		--statedir="$TS_STATEDIR" \
		--socket="$TS_SOCK" </dev/null >> "$TS_LOG" 2>&1 &
	TS_DAEMON_PID=$!
}

# _ts_wait_socket <pid> — wait up to TS_SOCK_WAIT_SECS for the control socket, WATCHING the
# daemon process so "starting slowly" and "already dead" are DIFFERENT outcomes:
#   0 = socket up
#   1 = daemon EXITED first — rc captured here; its stdout/stderr already landed in $TS_LOG
#       via the spawn redirect, so the log finally shows WHY a cold start fails
#   2 = timeout with the daemon STILL ALIVE — callers must NOT kill it (killing a slow
#       starter was the 22:30 field bug); the next attempt reuses it via _ts_running_pid
_ts_wait_socket() {
	_wpid="$1"
	_wmax=$((TS_SOCK_WAIT_SECS * 5))   # 0.2s steps
	_wi=0
	while [ "$_wi" -lt "$_wmax" ]; do
		_ts_sock_present && return 0
		if [ -n "$_wpid" ] && ! kill -0 "$_wpid" 2>/dev/null; then
			wait "$_wpid" 2>/dev/null; _wrc=$?
			[ "$_wrc" = 127 ] && _wrc="?"   # not our child — exit status unknowable
			ts_log "tailscaled EXITED (rc=$_wrc) before its socket appeared — its own output above is the why"
			return 1
		fi
		_wi=$((_wi + 1))
		[ $((_wi % 25)) = 0 ] && ts_log "still waiting for tailscaled socket ($((_wi / 5))s, pid ${_wpid:-?} alive)"
		sleep 0.2
	done
	_ts_sock_present && return 0
	ts_log "tailscaled socket not up after ${TS_SOCK_WAIT_SECS}s — daemon still starting; left running for the next attempt (NOT killed)"
	return 2
}

_ts_meminfo_kb() { awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || echo 0; }
_ts_avail_kb()   { awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo 2>/dev/null || echo 0; }

# _ts_capable — arch + RAM gate. muOS on the RG34XX is a single arm64 (H700) target, so
# (unlike the multi-platform NextUI/fork gate) this checks arch + a RAM floor rather than a
# platform allow-list. A non-arm64 build (or a sub-256MB device) is opt-in only via
# LODOR_TS_FORCE=1. userspace tailscaled + the engine both fit under the 256MiB GOMEMLIMIT.
_ts_capable() {
	if [ "$(_ts_arch)" != "arm64" ] && [ "${LODOR_TS_FORCE:-0}" != "1" ]; then
		return 1
	fi
	mem=$(_ts_meminfo_kb)
	[ "${mem:-0}" -gt 0 ] && [ "$mem" -lt 256000 ] && return 1
	avail=$(_ts_avail_kb)
	if [ "${avail:-0}" -gt 0 ] && [ "$avail" -lt 122880 ] && [ "${LODOR_TS_FORCE:-0}" != "1" ]; then
		ts_log "tailscale: MemAvailable ${avail}kB < 120MB -> skip"
		return 1
	fi
	return 0
}

# ts_available — does THIS device/build offer the Tailscale option at all? Binaries bundled +
# capable. The wizard shells `lodor-ts.sh available` and hides the Tailscale row when this is
# non-zero, so a build without the binaries (or a non-arm64 host) never shows a dead option.
ts_available() {
	[ -x "$TS_BIN_DIR/tailscaled" ] || return 1
	[ -x "$TS_BIN_DIR/tailscale" ]  || return 1
	_ts_capable
}

# _ts_hostname — DNS label for this node: device_name from config.json (sanitized), else
# lodor-<platform>.
_ts_hostname() {
	dn=$(sed -n 's/.*"device_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_TS_CFG" 2>/dev/null | head -1)
	[ -n "$dn" ] || dn="lodor-$PLAT"
	printf '%s' "$dn" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9-' '-' | sed 's/^-*//; s/-*$//'
}

# _ts_wantrunning_up — drive a persisted-login node from Stopped -> Running. Restoring the
# tailscaled state can ALSO restore WantRunning=false (the node was "Tailscale: stopped" when
# its state was last saved) — the daemon then loads the login but never connects, the backend
# sits at "Stopped", MagicDNS never resolves the RomM host, and the engine's SOCKS5 dial fails
# with "no such host" (the 2026-07-04 field DLFAIL). `tailscale up` REUSES the persisted login
# (NO re-auth, NO key, NO --reset) and only flips WantRunning=true. Backgrounded via $TS_BG so
# a wedged/blocked up never stalls the caller's Running poll; a valid persisted login connects
# in a second or two. Idempotent: a no-op when the backend is already Running.
_ts_wantrunning_up() {
	if "$TS_BIN_DIR/tailscale" --socket="$TS_SOCK" status --json 2>/dev/null \
		| grep -q '"BackendState"[[:space:]]*:[[:space:]]*"Running"'; then
		return 0
	fi
	ts_log "backend not Running (persisted state may carry WantRunning=false) — 'tailscale up' to reuse login + set WantRunning=true"
	$TS_BG "$TS_BIN_DIR/tailscale" --socket="$TS_SOCK" up \
		--hostname="$(_ts_hostname)" \
		--accept-dns=false \
		--accept-routes=false >> "$TS_LOG" 2>&1 &
	return 0
}

# tailscale_up — start userspace tailscaled + REUSE a persisted login (QR-onboarded state).
# No authkey required for the QR path. Returns 0 only when Running (SOCKS5 listening); any
# skip/failure returns non-0. NEVER logs the authkey.
tailscale_up() {
	_ts_capable || { return 1; }
	[ -x "$TS_BIN_DIR/tailscaled" ] || { return 1; }
	[ -x "$TS_BIN_DIR/tailscale" ]  || { return 1; }

	_ts_state_restore
	printf '\n--- ts run ---\n' >> "$TS_LOG" 2>/dev/null

	if _ts_sock_present && "$TS_BIN_DIR/tailscale" --socket="$TS_SOCK" status >/dev/null 2>&1; then
		ts_log "tailscaled already up; reusing"
		return 0
	fi

	# A daemon may still be STARTING from an earlier attempt this boot (cold start):
	# wait on IT — never spawn a duplicate at the same SOCKS5 port / socket path.
	_tsrp="$(_ts_running_pid)"
	if [ -n "$_tsrp" ]; then
		ts_log "tailscaled already running (pid $_tsrp) but its socket is not answering yet — waiting on it instead of spawning a duplicate"
	else
		ts_log "starting userspace tailscaled (GOGC=10 GOMAXPROCS=1 GOMEMLIMIT=$TS_MEMLIMIT socks5=$TS_SOCKS5_ADDR)"
		_ts_spawn_daemon
		_tsrp="$TS_DAEMON_PID"
	fi
	# Died -> honest failure (rc + daemon output in the ts log). Still starting at the
	# deadline -> honest failure too, but the daemon is LEFT UP for the next attempt.
	_ts_wait_socket "$_tsrp" || return 1

	# Reuse persisted login (QR onboarding) — poll to Running (a returning node re-auths a
	# few seconds after the socket appears; a single-shot check races it to a false NeedsLogin).
	if [ -s "$TS_STATEDIR/tailscaled.state" ]; then
		# CRITICAL (2026-07-04 field DLFAIL): restoring the persisted state can leave the
		# backend Stopped (WantRunning=false) — the daemon has the login but never connects,
		# so MagicDNS never resolves and every download/sync dial fails. Kick WantRunning=true
		# (reuses the login, no key) BEFORE the poll, else this loop times out forever waiting
		# for a Running the daemon was never told to reach.
		_ts_wantrunning_up
		i=0
		while [ "$i" -lt 250 ]; do
			_bs=$("$TS_BIN_DIR/tailscale" --socket="$TS_SOCK" status --json 2>/dev/null \
				| grep -oE '"BackendState"[[:space:]]*:[[:space:]]*"[A-Za-z]+"' | head -1 \
				| grep -oE '"[A-Za-z]+"' | tail -1 | tr -d '"')
			if [ "$_bs" = "Running" ]; then
				ts_log "tier-1 up: reusing persisted login (no key)"
				_ts_state_save
				return 0
			fi
			# Settled back to Stopped (WantRunning still false — the up call raced the daemon's
			# state load, or the daemon flipped it): re-kick, bounded to a few tries so a
			# genuinely unreachable node still fails honestly instead of looping.
			if [ "$_bs" = "Stopped" ] && [ $((i % 50)) = 0 ] && [ "$i" -gt 0 ]; then
				_ts_wantrunning_up
			fi
			sleep 0.1; i=$((i + 1))
		done
		ts_log "persisted state present but not Running after 25s (daemon left up)"
		return 1
	fi
	# Not authenticated and no persisted state. Headless authkey path (parity; no key ships).
	if [ ! -f "$TS_AUTHKEY_FILE" ]; then
		ts_log "not authenticated and no authkey -> sign in via onboarding QR"
		tailscale_down
		return 1
	fi
	if ! "$TS_BIN_DIR/tailscale" --socket="$TS_SOCK" up \
		--auth-key="file:$TS_AUTHKEY_FILE" \
		--hostname="$(_ts_hostname)" \
		--advertise-tags="$TS_TAGS" \
		--accept-dns=false \
		--accept-routes=false >> "$TS_LOG" 2>&1; then
		ts_log "tailscale up failed"
		tailscale_down
		return 1
	fi
	ts_log "tier-1 up: node joined, SOCKS5 on $TS_SOCKS5_ADDR"
	_ts_state_save
	return 0
}

# tailscale_down — stop the userspace daemon + remove the socket; leave node state on card.
tailscale_down() {
	_ts_state_save
	if _ts_sock_present; then "$TS_BIN_DIR/tailscale" --socket="$TS_SOCK" down >/dev/null 2>&1; fi
	if [ -n "${TS_DAEMON_PID:-}" ]; then kill "$TS_DAEMON_PID" >/dev/null 2>&1; TS_DAEMON_PID=""; fi
	killall tailscaled >/dev/null 2>&1
	rm -f "$TS_SOCK" 2>/dev/null
	return 0
}

# ts_reset — hard reset: log out, stop the daemon, wipe tmpfs + persisted state so the NEXT
# sign-in is completely fresh (recovery for a wedged/half-authed node).
ts_reset() {
	_ts_sock_present && "$TS_BIN_DIR/tailscale" --socket="$TS_SOCK" logout >/dev/null 2>&1
	tailscale_down
	rm -f "$TS_STATEDIR/tailscaled.state" "$TS_STATE_PERSIST" "$TS_STATEDIR/up.log" 2>/dev/null
	ts_log "ts_reset: logged out + state wiped (fresh sign-in next time)"
	return 0
}

# tailscale_reconnect — the "Tailscale: Reconnect" menu action (task #134): restart tailscaled
# from the PERSISTED login and report honestly. NEVER re-auths — it only ever reuses the saved
# state (the QR sign-in that Reset & forget wipes) and never touches the RomM pairing token.
# stdout = ONE machine-readable token the menu translates into UX text:
#   connected[:<tailnet-ip>]  Running again (rc 0)
#   no-login                  no saved sign-in anywhere (tmpfs or card) — QR onboarding is
#                             the only way to mint one; nothing was torn down (rc 1)
#   not-running               daemon restarted but never reached Running — the ts log's
#                             watched-wait lines say why (rc 1)
#   not-capable / no-binary   device/build can't run Tailscale at all (rc 1)
tailscale_reconnect() {
	_ts_capable || { ts_log "reconnect: device not Tailscale-capable"; echo "not-capable"; return 1; }
	if [ ! -x "$TS_BIN_DIR/tailscaled" ] || [ ! -x "$TS_BIN_DIR/tailscale" ]; then
		ts_log "reconnect: tailscale binaries missing ($TS_BIN_DIR)"; echo "no-binary"; return 1
	fi
	printf '\n--- ts reconnect ---\n' >> "$TS_LOG" 2>/dev/null
	# No saved login anywhere -> reconnect CANNOT work; say so BEFORE tearing anything down.
	_ts_state_restore
	if [ ! -s "$TS_STATEDIR/tailscaled.state" ]; then
		ts_log "reconnect: no saved login (state absent) — sign in via the onboarding QR"
		echo "no-login"; return 1
	fi
	# Explicit RESTART: tailscale_up would happily "reuse" a wedged daemon that still answers
	# its socket, so tear the old one down first (tailscale_down SAVES state — the login is
	# never touched) and wait for it to actually die so the fresh spawn can bind the same
	# SOCKS5 port + socket path (the "address already in use" trap).
	_rk="$(_ts_running_pid)"
	tailscale_down >/dev/null 2>&1
	if [ -n "$_rk" ]; then
		_ri=0
		while kill -0 "$_rk" 2>/dev/null && [ "$_ri" -lt 25 ]; do sleep 0.2; _ri=$((_ri + 1)); done
		if kill -0 "$_rk" 2>/dev/null; then
			ts_log "reconnect: old tailscaled (pid $_rk) ignored TERM for 5s — KILL"
			kill -9 "$_rk" 2>/dev/null
			sleep 0.2
		fi
	fi
	# Fresh bring-up from the persisted login. tailscale_up does the watched socket wait then
	# polls to Running — with state present its rc 0 MEANS BackendState=Running.
	if tailscale_up; then
		_rip="$(tailscale_ip 2>/dev/null)"
		ts_log "reconnect: Running again${_rip:+ ($_rip)}"
		echo "connected${_rip:+:$_rip}"
		return 0
	fi
	ts_log "reconnect: restart did not reach Running — the watched-wait lines above say why"
	echo "not-running"
	return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# QR onboarding: INTERACTIVE login (no auth key).
# ─────────────────────────────────────────────────────────────────────────────

# tailscale_up_interactive — start userspace tailscaled (if needed), then run an INTERACTIVE
# `tailscale up` (NO --auth-key) in the BACKGROUND so it prints the login URL and waits for
# the user to authenticate. Scrapes the https://login.tailscale.com/... URL and echoes ONLY
# that URL on stdout (empty on skip/failure OR when already signed in). NEVER blocks longer
# than the ~15s scrape window.
tailscale_up_interactive() {
	_ts_capable || { echo ""; return 1; }
	[ -x "$TS_BIN_DIR/tailscaled" ] || { echo ""; return 1; }
	[ -x "$TS_BIN_DIR/tailscale" ]  || { echo ""; return 1; }

	_ts_state_restore
	printf '\n--- ts run (interactive) ---\n' >> "$TS_LOG" 2>/dev/null

	if ! { _ts_sock_present && "$TS_BIN_DIR/tailscale" --socket="$TS_SOCK" status >/dev/null 2>&1; }; then
		_tsrp="$(_ts_running_pid)"
		if [ -n "$_tsrp" ]; then
			ts_log "interactive: tailscaled already running (pid $_tsrp) — waiting on its socket (no duplicate spawn)"
		else
			ts_log "starting userspace tailscaled (interactive login; socks5=$TS_SOCKS5_ADDR)"
			_ts_spawn_daemon
			_tsrp="$TS_DAEMON_PID"
		fi
		# Same contract as tailscale_up: a dead daemon is an honest failure (rc + its own
		# output in the ts log); a slow starter is NEVER killed — left up for the retry.
		if ! _ts_wait_socket "$_tsrp"; then echo ""; return 1; fi
	fi

	# Already signed in (prior sign-in survived)? Report empty URL + success.
	if "$TS_BIN_DIR/tailscale" --socket="$TS_SOCK" status --json 2>/dev/null \
		| grep -q '"BackendState"[[:space:]]*:[[:space:]]*"Running"'; then
		ts_log "interactive: already Running (state reused) — no login URL needed"
		echo ""
		return 0
	fi

	UP_LOG="$TS_STATEDIR/up.log"; : > "$UP_LOG"
	"$TS_BIN_DIR/tailscale" --socket="$TS_SOCK" up \
		--hostname="$(_ts_hostname)" \
		--accept-dns=false \
		--accept-routes=false >> "$UP_LOG" 2>&1 &
	echo $! > "$TS_STATEDIR/up.pid" 2>/dev/null

	i=0; url=""; _prev=""
	while [ "$i" -lt 150 ]; do
		# PRIMARY: the daemon's status JSON AuthURL — atomic and complete by construction.
		# (Scraping up.log raced `tailscale up`'s buffered writes: boot 3 captured a 31-char
		# half-flushed URL. The JSON field can never be partially written.)
		url=$("$TS_BIN_DIR/tailscale" --socket="$TS_SOCK" status --json 2>/dev/null \
			| grep -oE '"AuthURL"[[:space:]]*:[[:space:]]*"https://login\.tailscale\.com/[A-Za-z0-9./_-]+"' \
			| grep -oE 'https://login\.tailscale\.com/[A-Za-z0-9./_-]+' | head -1)
		[ -n "$url" ] && break
		# FALLBACK: up.log, but only accept a value that is stable across two consecutive polls
		# (a half-flushed line differs from its completed self 100ms later).
		_u2=$(grep -oE 'https://login\.tailscale\.com/[A-Za-z0-9./_-]+' "$UP_LOG" 2>/dev/null | head -1)
		if [ -n "$_u2" ] && [ "$_u2" = "$_prev" ]; then url="$_u2"; break; fi
		_prev="$_u2"
		"$TS_BIN_DIR/tailscale" --socket="$TS_SOCK" status --json 2>/dev/null \
			| grep -q '"BackendState"[[:space:]]*:[[:space:]]*"Running"' && break
		sleep 0.1; i=$((i + 1))
	done
	[ -n "$url" ] && ts_log "interactive: login URL captured (len=${#url})"
	echo "$url"
	return 0
}

# tailscale_status — one stable token for the poll loop: "connected" (Running), "pending"
# (still waiting on the user), or "stopped" (no daemon). Reads BackendState from --json.
tailscale_status() {
	_ts_sock_present || { echo "stopped"; return 0; }
	st=$("$TS_BIN_DIR/tailscale" --socket="$TS_SOCK" status --json 2>/dev/null \
		| grep -oE '"BackendState"[[:space:]]*:[[:space:]]*"[A-Za-z]+"' | head -1 \
		| grep -oE '"[A-Za-z]+"' | tail -1 | tr -d '"')
	case "$st" in
		Running)                      _ts_state_save; echo "connected" ;;
		NeedsLogin|Starting|NoState)  echo "pending" ;;
		Stopped|"")                   echo "pending" ;;
		*)                            echo "pending" ;;
	esac
}

# tailscale_ip — the node's tailnet IPv4 (for the status screen). Empty if not up.
tailscale_ip() {
	_ts_sock_present || { echo ""; return 0; }
	"$TS_BIN_DIR/tailscale" --socket="$TS_SOCK" ip -4 2>/dev/null | head -1
}

# tailscale_mark_tier1 — promote hosts[0] in config.json to a TIER-1 (SOCKS5) host by adding
# "socks5_proxy":"<addr>" and "tier":1 next to "root_uri". The engine's config writer
# round-trips config.json through a generic map and PRESERVES these keys across later
# --pair / --register-device writes. Idempotent + JSON-safe. UNLIKE the LodorOS fork it does
# NOT rewrite http->https: a NextUI tier-1 root_uri is a MagicDNS "http://name" URL resolved
# INSIDE the SOCKS5 proxy (socks5h), so its scheme is kept exactly as the user entered it.
tailscale_mark_tier1() {
	cfg="$_TS_CFG"
	[ -f "$cfg" ] || { ts_log "mark-tier1: no config.json ($cfg)"; return 1; }
	if grep -q '"socks5_proxy"' "$cfg" 2>/dev/null; then
		ts_log "mark-tier1: already tier-1 (idempotent skip)"
		return 0
	fi
	tmp="$cfg.ts-tmp.$$"
	awk -v proxy="$TS_SOCKS5_ADDR" '
		BEGIN { done = 0 }
		{
			if (!done && $0 ~ /"root_uri"[[:space:]]*:/) {
				line = $0
				sub(/\r$/, "", line)
				match(line, /^[ \t]*/); ind = substr(line, 1, RLENGTH)
				had_comma = (line ~ /,[ \t]*$/)
				if (!had_comma) sub(/[ \t]*$/, ",", line)
				print line
				print ind "\"socks5_proxy\": \"" proxy "\","
				if (had_comma) print ind "\"tier\": 1,"
				else           print ind "\"tier\": 1"
				done = 1
				next
			}
			print
		}
	' "$cfg" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
	if grep -q '"socks5_proxy"' "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
		# FAT32/exFAT-safe: atomically rename over config.json (never truncate-in-place).
		if mv -f "$tmp" "$cfg"; then sync 2>/dev/null; ts_log "mark-tier1: tier-1 ($TS_SOCKS5_ADDR)"; return 0; fi
	fi
	rm -f "$tmp"
	ts_log "mark-tier1: insert failed (root_uri not found?) — config left untouched"
	return 1
}

# tailscale_is_tier1 — 0 if config.json already carries a socks5_proxy (tier-1 configured).
tailscale_is_tier1() { [ -f "$_TS_CFG" ] && grep -q '"socks5_proxy"' "$_TS_CFG" 2>/dev/null; }
