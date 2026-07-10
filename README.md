# Lodor for muOS

A **no-fork** [RomM](https://github.com/rommapp/romm) client for stock
[muOS](https://muos.dev) (MustardOS). Wireless library mirroring, download-on-launch,
and automatic save sync — delivered entirely through muOS's own extension surfaces
(an Application, launch overrides, and a boot-init hook). Stock muOS stays stock:
nothing in the firmware is patched or replaced.

Validated target: Anbernic RG34XX (Allwinner H700, arm64) on muOS 2601 "Jacaranda".

## What it does

- **Mirror your RomM library** — every game on your server appears in the muOS menus
  (0-byte stubs for games not yet on the card), with box art.
- **Download on launch** — pick a game you don't have; it downloads over Wi-Fi
  (hash-verified), then launches. Already-downloaded games launch instantly, offline.
- **Automatic save sync** — saves are pulled before play and pushed after (or queued
  offline and pushed later by a charging-gated background daemon). Play the same game
  across devices without thinking about it.
- **On-device onboarding** — a built-in wizard (framebuffer UI) walks through server
  pairing on first launch; later launches offer Sync-now / re-setup.

## How it stays no-fork

| Piece | muOS surface used |
|---|---|
| `Lodor` app (wizard + engine) | `MUOS/application/` — a standard `.muxapp` |
| Download-on-launch + save bracket | `info/override/<System>.sh` — muOS's own per-folder launch override; the stock `lr-general.sh` still runs the game |
| Background save daemon | `MUOS/init/*.sh` — muOS's user-init boot hook |
| Wi-Fi, RetroArch, box art | stock muOS — inherited, not re-implemented |

The launch override only wraps RetroArch folders (decided from muOS's own
`info/assign` config); standalone systems (PSP, etc.) are never touched. Launching a
game is **never** gated on sync — if anything network-side fails, the game still runs.

## Build

The sync engine and wizard are CGO-free static Go binaries (muOS variant is the
`muos` build tag):

```sh
cd engine
CGO_ENABLED=0 GOARCH=arm64 go build -tags muos -trimpath -ldflags "-s -w" ./cmd/lodor-sync
CGO_ENABLED=0 GOARCH=arm64 go build -tags muos -trimpath -ldflags "-s -w" ./cmd/lodor-wizard
```

The release pipeline (`release/release.sh`) builds both, gates them (static,
branding, PII, redistributable), and assembles `Lodor-muOS-<version>.muxapp`.

## Install

1. Copy `Lodor-muOS-<version>.muxapp` to `ARCHIVE/` on SD1 (`/mnt/mmc/ARCHIVE`).
2. On the device: **Applications → Archive Manager** → install it.
3. Launch **Lodor** from Applications. The wizard walks you through pairing
   with your RomM server (e.g. `https://romm.example.com`) and the initial mirror.
   Wi-Fi setup stays in muOS Settings — connect first.

Configuration lives in the app folder (`config.json`; see `config.json.example`).
The app ships the public Mozilla CA bundle (`certs/ca-certificates.crt`) so HTTPS
verification works on-device.

## Layout

```
App/Lodor/
  mux_launch.sh          # muOS app entry → onboarding wizard / sync menu
  lodor-sync             # headless engine (built artifact, muos-arm64)
  lodor-wizard           # framebuffer onboarding UI (built artifact, arm64)
  lib/romm-sync-lib.sh   # shared shell library (env contract, Wi-Fi, corename lookup)
  bin/lodor-override.sh  # launch override: stub-fetch → save-pull → stock launcher → save-push
  bin/lodor-seed.sh      # (re)installs overrides + boot hook; idempotent
  bin/romm-run           # app → engine bridge (network bring-up, logging)
  bin/romm-syncd         # charging-gated offline save-push daemon
  certs/                 # public Mozilla CA bundle
  glyph/                 # app icon
test/
  check.sh               # shell-surface gate (parse + shellcheck)
  integ-harness.sh       # end-to-end sandbox harness (real card image, qemu engine)
  mockromm.go            # loopback RomM stand-in for the offline harness legs
```

## Cross-device "Continue" (native History injection)

muOS has no MinUI-style `recent.txt`; its History menu (`muxhistory`) renders one
pointer file per game under `MUOS/info/history` (`/run/muos/storage/info/history`
at runtime) — `<name>-<FNV1a-32-of-path>.cfg`, three lines (rom path / system
folder / content name), ordered by file **mtime**. The engine's `--sync-continue`
(the fast "Sync now" leg; the full Refresh runs the same delivery) materializes
the cross-device RomM feed as those pointer files, mtime-stamped to each save's
**server** `updated_at` — games played on another device surface in muOS's own
History, in true recency order, with zero launcher changes. Injected entries
launch through the standard assign/override pipeline, so download-on-launch and
the save bracket apply. Pointers the engine did not create are never touched (the
user's real history is sacred); a stale Lodor pointer stranded by the ✘→✓
download rename is re-keyed to the live name.

## Notes

- BYOB: no BIOS or firmware is bundled, ever. Use the engine's `--download-bios`
  against your own server's collection.
- Saves are matched per libretro corename (read from the card's own core `.info`
  files), exactly where stock RetroArch reads them.
