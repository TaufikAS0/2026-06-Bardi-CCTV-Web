# Claude Handoff

## Scope

Claude hanya diminta membantu **desain/tampilan web UI** untuk dashboard CCTV ini.

Jangan ubah:

- logika bridge stream
- proses VLC
- endpoint backend Python
- IP kamera, port, atau autentikasi

Fokus Claude:

- layout
- typography
- warna
- status badges
- responsive behavior
- tombol / card arrangement
- polishing visual hierarchy

## Current Backend Contract

Frontend sekarang harus menganggap endpoint ini sudah ada dan dipakai apa adanya:

- `/api/cameras`
- `/api/status`
- `/camera/1/stream.mjpg`
- `/camera/2/stream.mjpg`
- `/camera/1/latest.jpg`
- `/camera/2/latest.jpg`

## Current Situation

- Kamera 2 di `192.168.1.43` sudah ditemukan valid lewat:
  - `rtsp://admin:12345678@192.168.1.43:8554/Streaming/Channels/102`
- Kamera 1 di `192.168.1.9` lebih sensitif.
- Eksperimen menunjukkan stream kamera 1 bermasalah kalau terlalu sering dibuka sebagai upstream MJPEG mentah.
- Karena itu backend sedang diarahkan ke model cache / replay lokal agar browser tidak langsung merusak upstream.

## What Claude Should Not Do

Jangan mengganti:

- nama endpoint
- struktur JSON `/api/cameras`
- struktur JSON `/api/status`
- asumsi bahwa browser bisa membaca RTSP langsung
- file PowerShell launcher kecuali memang hanya komentar atau teks dokumentasi

## Files Claude Can Edit

Utama:

- `ghost-grid/index.html`

Kalau sangat perlu untuk tampilan saja, boleh sentuh:

- `ghost-grid/server.py`

Tetapi hanya jika perubahan itu murni untuk cara frontend menerima asset/status, bukan mengubah arsitektur stream.

## Goal

Bikin UI dua kamera yang:

- jelas dibaca
- enak di desktop dan mobile
- punya fallback visual saat stream belum ready
- terlihat seperti dashboard lokal yang rapi, bukan halaman debug
