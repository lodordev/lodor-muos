#!/bin/sh
# lodor-ts.sh — thin host-side shim the Go wizard shells for Tailscale onboarding. ALL of the
# tunnel bring-up / login-URL / status / tier-1 logic lives in lib/tailscale-lib.sh (a faithful
# port of the field-tested NextUI lib); this only dispatches subcommands so NEITHER the engine
# NOR the Go wizard embeds any Tailscale logic (boundary: host delivery, not engine capability).
#  MARKER: LODOR_MUOS_TS_SHIM
set -u
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export LODOR_APPDIR="${LODOR_APPDIR:-$SELF_DIR}"
. "$SELF_DIR/lib/romm-sync-lib.sh"
lodor_export_env
. "$SELF_DIR/lib/tailscale-lib.sh"

case "${1:-}" in
	available)      ts_available ;;                # exit status only (0 = offer the option)
	up-interactive) tailscale_up_interactive ;;    # stdout = login URL (empty if already up / failed)
	status)         tailscale_status ;;            # connected | pending | stopped
	ip)             tailscale_ip ;;                # tailnet IPv4 (empty if not up)
	mark-tier1)     tailscale_mark_tier1 ;;        # promote hosts[0] -> SOCKS5 tier-1 host
	is-tier1)       tailscale_is_tier1 ;;          # exit status only
	down)           tailscale_down ;;
	reconnect)      tailscale_reconnect ;;         # stdout = connected[:ip] | no-login | not-running | ...
	reset)          ts_reset ;;
	*) echo "usage: lodor-ts.sh {available|up-interactive|status|ip|mark-tier1|is-tier1|down|reconnect|reset}" >&2; exit 2 ;;
esac
