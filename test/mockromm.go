// mockromm.go — a tiny offline RomM stand-in for the muOS integ harness (#181).
//
// Serves JUST the surface --sync-continue touches: /api/platforms and /api/saves
// for one mapped platform (gamegear) with two cross-device saves at FIXED
// timestamps, so the harness can assert exact injected history mtimes without
// ever touching a real RomM. Auth is accepted-and-ignored (the engine sends its
// token; a mock has nothing to protect). Built ad-hoc by the harness
// (`go build mockromm.go` — no module), run on loopback, killed when the harness
// exits. NEVER points at, or is reachable from, production.
package main

import (
	"flag"
	"log"
	"net/http"
)

const platformsJSON = `[
  {"id": 1, "slug": "gamegear", "fs_slug": "gamegear", "name": "Sega Game Gear", "rom_count": 2}
]`

// Two playable (non-ghost: file_size_bytes > 0) saves, one per rom, pushed from
// another device. updated_at values are the harness's ground truth for mtimes:
//	rom 71 ("✘ Zilion")   2026-07-01T10:00:00Z  (older)
//	rom 72 ("Real Game")  2026-07-02T10:00:00Z  (newer)
const savesJSON = `[
  {"id": 501, "rom_id": 71, "file_name": "Zilion (USA).srm", "file_name_no_ext": "Zilion (USA)",
   "file_extension": "srm", "file_size_bytes": 1024, "updated_at": "2026-07-01T10:00:00Z",
   "emulator": "genesis_plus_gx",
   "device_syncs": [{"device_id": "dev-flip", "device_name": "Mini Flip",
                     "last_synced_at": "2026-07-01T10:00:00Z", "is_current": true}]},
  {"id": 502, "rom_id": 72, "file_name": "Real Game (USA).srm", "file_name_no_ext": "Real Game (USA)",
   "file_extension": "srm", "file_size_bytes": 2048, "updated_at": "2026-07-02T10:00:00Z",
   "emulator": "genesis_plus_gx",
   "device_syncs": [{"device_id": "dev-flip", "device_name": "Mini Flip",
                     "last_synced_at": "2026-07-02T10:00:00Z", "is_current": true}]}
]`

func jsonHandler(body string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(body))
	}
}

func main() {
	addr := flag.String("addr", "127.0.0.1:8199", "listen address (loopback only)")
	flag.Parse()

	mux := http.NewServeMux()
	mux.HandleFunc("/api/heartbeat", jsonHandler(`{}`))
	mux.HandleFunc("/api/platforms", jsonHandler(platformsJSON))
	mux.HandleFunc("/api/saves", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("platform_id") == "1" {
			jsonHandler(savesJSON)(w, r)
			return
		}
		jsonHandler(`[]`)(w, r)
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		log.Printf("mockromm: unhandled %s %s", r.Method, r.URL.Path)
		http.NotFound(w, r)
	})
	log.Printf("mockromm: listening on %s", *addr)
	log.Fatal(http.ListenAndServe(*addr, mux))
}
