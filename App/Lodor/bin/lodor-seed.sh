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

# PERF (BUG 1b): the old path called find_system_dir PER ROM FOLDER, each time rescanning
# EVERY assign global.ini with a fistful of sed/subshell spawns - O(folders x systems) on
# busybox, a big chunk of "takes forever to load". Rework: build the assign -> launcher-type
# map in ONE pass (O(systems)), then match each folder against it (O(folders)). Total O(n).
#
# build_assign_map: for every assign system, decide RetroArch (RA) vs standalone (SA) ONCE
# from its DEFAULT launcher's exec (lr-* => RA), then emit "<normkey> <type>" for each name it
# can be matched by (catalogue / name / dir-basename / [friendly] aliases). One map file.
ASSIGN_MAP="${TMPDIR:-/tmp}/lodor-assign-map.$$"
: > "$ASSIGN_MAP" 2>/dev/null
build_assign_map() {
	for gi in "$ASSIGN_ROOT"/*/global.ini; do
		[ -f "$gi" ] || continue
		_d=$(dirname "$gi")
		_def=$(sed -n 's/^default=//p' "$gi" | head -1)
		_type=SA
		if [ -n "$_def" ] && [ -f "$_d/$_def.ini" ]; then
			_exec=$(sed -n 's#^exec=##p' "$_d/$_def.ini" | head -1)
			case "$(basename "${_exec:-}")" in lr-*) _type=RA ;; esac
		fi
		# all match keys for this system: catalogue, name, dir basename, friendly aliases.
		{
			sed -n 's/^catalogue=//p;s/^name=//p' "$gi"
			basename "$_d"
			sed -n '/^\[friendly\]/,/^\[/p' "$gi" | sed '1d;/^\[/d'
		} | while IFS= read -r _k; do
			_nk=$(norm "$_k")
			[ -n "$_nk" ] && printf '%s %s\n' "$_nk" "$_type"
		done >> "$ASSIGN_MAP"
	done
}

# folder_type <folder> : RA | SA | "" (unknown) from the in-memory map (one awk lookup).
folder_type() {
	_nk=$(norm "$1")
	[ -n "$_nk" ] || return 0
	awk -v k="$_nk" '$1==k {print $2; exit}' "$ASSIGN_MAP" 2>/dev/null
}

build_assign_map

seeded=0; skipped=0
[ -d "$ROMS" ] && for d in "$ROMS"/*/; do
	[ -d "$d" ] || continue
	f=$(basename "$d")
	if [ "$(folder_type "$f")" = "RA" ]; then
		ln -sf "$TARGET" "$OVERRIDE_ROOT/$f.sh" 2>/dev/null && seeded=$((seeded+1))
	else
		# Standalone or unknown launcher: do NOT override (would break its ext-*.sh launch).
		# Remove any stale Lodor override we previously placed there.
		[ -L "$OVERRIDE_ROOT/$f.sh" ] && rm -f "$OVERRIDE_ROOT/$f.sh"
		skipped=$((skipped+1))
	fi
done
rm -f "$ASSIGN_MAP" 2>/dev/null

# Daemon autostart: ensure the single boot hook exists in MUOS/init/ (user_init runs every
# *.sh there backgrounded at boot). Written only if ABSENT so we never duplicate the shipped
# 00-lodor.sh or double-start the daemon. Deleting it disables autostart; this re-heals it.
INIT_DIR="$MUOS_STORE_DIR/init"
if [ -d "$INIT_DIR" ] || mkdir -p "$INIT_DIR" 2>/dev/null; then
	if [ ! -f "$INIT_DIR/00-lodor.sh" ]; then
		cat > "$INIT_DIR/00-lodor.sh" <<EOF
#!/bin/sh
# Lodor boot hook (re-healed by lodor-seed.sh; delete to disable autostart).
"$APPDIR/bin/lodor-seed.sh" >/dev/null 2>&1     # refresh launch overrides
"$APPDIR/bin/romm-syncd" &                       # start the charging-gated save daemon
EOF
		chmod +x "$INIT_DIR/00-lodor.sh" 2>/dev/null
	fi
fi

log "seed: overrides=$seeded skipped=$skipped (RetroArch folders get launch interception; standalone untouched)"
echo "SEED overrides=$seeded skipped=$skipped"
