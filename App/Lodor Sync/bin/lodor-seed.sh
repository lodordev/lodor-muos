#!/bin/sh
# lodor-seed.sh - (re)install the launch overrides + daemon autostart. Idempotent; safe to
# run on every app launch and at boot. Detect-and-reheal: it re-finds muOS's override dir
# and decides RetroArch-vs-standalone per folder from muOS's OWN assign config, so it never
# breaks a standalone system (PSP/DS etc.) by routing it through lr-general.  MARKER: LODOR_SEED
SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$SELF_DIR/../lib/romm-sync-lib.sh"
lodor_export_env

OVERRIDE_ROOT="$MUOS_SHARE_DIR/info/override"
ASSIGN_ROOT="$MUOS_SHARE_DIR/info/assign"
TARGET="$APPDIR/bin/lodor-override.sh"
ROMS="$(lodor_roms_dir)"

mkdir -p "$OVERRIDE_ROOT" 2>/dev/null

# norm: lowercase, strip everything but a-z0-9 (muOS folder<->friendly matching is fuzzy).
norm() { echo "$1" | tr 'A-Z' 'a-z' | tr -cd 'a-z0-9'; }

# find_system_dir <folder> : echo the assign system dir whose catalogue/name/friendly alias
# matches <folder>. Empty if none (then we can't tell launcher type -> skip, honestly).
find_system_dir() {
	_want="$(norm "$1")"
	for gi in "$ASSIGN_ROOT"/*/global.ini; do
		[ -f "$gi" ] || continue
		_d=$(dirname "$gi")
		_cat=$(sed -n 's/^catalogue=//p' "$gi" | head -1)
		_nam=$(sed -n 's/^name=//p' "$gi" | head -1)
		if [ "$(norm "${_cat:-}")" = "$_want" ] || [ "$(norm "${_nam:-}")" = "$_want" ] || [ "$(norm "$(basename "$_d")")" = "$_want" ]; then
			echo "$_d"; return 0
		fi
		# friendly aliases (one per line under [friendly])
		if sed -n '/^\[friendly\]/,/^\[/p' "$gi" | sed '1d;/^\[/d' | while read -r fa; do
			[ -n "$fa" ] && [ "$(norm "$fa")" = "$_want" ] && exit 0; done; then
			echo "$_d"; return 0
		fi
	done
	return 1
}

# is_retroarch_folder <folder> : true if the folder's DEFAULT launcher exec is an lr-*.sh
# (RetroArch). Standalone (ext-*.sh) -> false. Unknown -> false (skip, never mis-route).
is_retroarch_folder() {
	_sys="$(find_system_dir "$1")" || return 1
	_def=$(sed -n 's/^default=//p' "$_sys/global.ini" | head -1)
	[ -n "$_def" ] || return 1
	_ini="$_sys/$_def.ini"
	[ -f "$_ini" ] || return 1
	_exec=$(sed -n 's#^exec=##p' "$_ini" | head -1)
	case "$(basename "${_exec:-}")" in
		lr-*) return 0 ;;
		*) return 1 ;;
	esac
}

seeded=0; skipped=0
[ -d "$ROMS" ] && for d in "$ROMS"/*/; do
	[ -d "$d" ] || continue
	f=$(basename "$d")
	if is_retroarch_folder "$f"; then
		ln -sf "$TARGET" "$OVERRIDE_ROOT/$f.sh" 2>/dev/null && seeded=$((seeded+1))
	else
		# Standalone or unknown launcher: do NOT override (would break its ext-*.sh launch).
		# Remove any stale Lodor override we previously placed there.
		[ -L "$OVERRIDE_ROOT/$f.sh" ] && rm -f "$OVERRIDE_ROOT/$f.sh"
		skipped=$((skipped+1))
	fi
done

# Daemon autostart: ensure the single boot hook exists in MUOS/init/ (user_init runs every
# *.sh there backgrounded at boot). Written only if ABSENT so we never duplicate the shipped
# 00-lodor.sh or double-start the daemon. Deleting it disables autostart; this re-heals it.
INIT_DIR="$MUOS_STORE_DIR/init"
if [ -d "$INIT_DIR" ] || mkdir -p "$INIT_DIR" 2>/dev/null; then
	if [ ! -f "$INIT_DIR/00-lodor.sh" ]; then
		cat > "$INIT_DIR/00-lodor.sh" <<EOF
#!/bin/sh
# Lodor Sync boot hook (re-healed by lodor-seed.sh; delete to disable autostart).
"$APPDIR/bin/lodor-seed.sh" >/dev/null 2>&1     # refresh launch overrides
"$APPDIR/bin/romm-syncd" &                       # start the charging-gated save daemon
EOF
		chmod +x "$INIT_DIR/00-lodor.sh" 2>/dev/null
	fi
fi

log "seed: overrides=$seeded skipped=$skipped (RetroArch folders get launch interception; standalone untouched)"
echo "SEED overrides=$seeded skipped=$skipped"
