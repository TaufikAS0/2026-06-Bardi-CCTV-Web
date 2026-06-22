# 2026-06-Bardi-CCTV-Web

Local dashboard untuk menampilkan dua kamera Bardi di browser melalui bridge lokal.

## Files

- `index.html`: UI dua kamera
- `server.py`: local proxy/cache server untuk stream browser
- `start-bardi-cctv-web.ps1`: start bridge lokal
- `stop-bardi-cctv-web.ps1`: stop bridge lokal
- `CLAUDE-HANDOFF.md`: batas scope untuk redesign UI oleh Claude

## Notes

- Kamera browser-facing disajikan lewat endpoint lokal, bukan RTSP langsung.
- `CLAUDE-HANDOFF.md` sengaja membatasi Claude ke desain frontend saja.
