# Lodor for muOS

A [muOS](https://muos.dev) application that brings [Lodor](https://github.com/lodordev/lodor)'s
transparent RomM library to muOS handhelds — your whole [RomM](https://github.com/rommapp/romm)
library appears as zero-byte stubs, games download when you launch them, and saves sync back to the
server automatically around each session.

**This is a no-fork add-on.** It's our own application that runs *on* muOS and uses muOS's standard
app conventions (`mux_launch.sh`, `.muxapp`). It does **not** modify, fork, or redistribute muOS
itself — you install muOS yourself, then drop this app in.

## What's here

```
RomM Sync/
  mux_launch.sh          muOS app entry point
  lib/romm-sync-lib.sh   shared sync library (Wi-Fi, clock, run)
  bin/                   helpers: launch override, seed, run, periodic sync daemon
  config.json.example    copy to config.json with your server + paired token
  glyph/romm.png         menu glyph
```

The sync **engine** itself (`lodor-sync`) is **not** committed here — it's a build artifact of the
[Lodor engine](https://github.com/lodordev/lodor). Build it for your device and drop it in the pak:

```sh
# RG34XX / H700 is ARM64
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -o lodor-sync ./cmd/lodor-sync
```

## Install

1. Build `lodor-sync` (above) and place it in `RomM Sync/`.
2. Copy `config.json.example` to `config.json` and fill in your RomM host; pair on first run.
3. Package `RomM Sync/` as a muOS `.muxapp` and copy it to your device's application directory.
4. Launch it from muOS's Applications menu, onboard, and your library mirrors in.

## Status

Built and **emulation-validated** against muOS on the Anbernic RG34XX. **On-hardware testing is still
pending** — treat it as untested on real silicon until that's confirmed.

## License

MIT — see [LICENSE](LICENSE). Acknowledgements in [CREDITS.md](CREDITS.md). Ships no BIOS, firmware,
muOS image, or game content.
