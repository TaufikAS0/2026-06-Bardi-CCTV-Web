# CCTV_HACK Ghost Grid

Local dashboard untuk menampilkan dua kamera LAN di browser melalui bridge lokal.

## Files

- `index.html`: UI dua kamera
- `server.py`: local proxy/cache server untuk stream browser
- launcher PowerShell untuk menyalakan bridge lokal
- launcher PowerShell untuk mematikan bridge lokal
- `CLAUDE-HANDOFF.md`: batas scope untuk redesign UI oleh Claude

## Notes

- Kamera browser-facing disajikan lewat endpoint lokal, bukan RTSP langsung.
- `CLAUDE-HANDOFF.md` sengaja membatasi Claude ke desain frontend saja.
