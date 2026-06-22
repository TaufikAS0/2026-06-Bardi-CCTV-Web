import argparse
import json
import os
import socket
import threading
import time
import urllib.request
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse


def parse_camera_specs(raw_specs):
    cameras = {}
    for raw_spec in raw_specs:
        parts = raw_spec.split("|", 4)
        if len(parts) == 4:
            camera_id, name, ip, source = parts
            mode = "mjpeg"
        elif len(parts) == 5:
            camera_id, name, ip, mode, source = parts
        else:
            raise ValueError("Each --camera value must be id|name|ip|source or id|name|ip|mode|source")

        cameras[camera_id] = {
            "id": camera_id,
            "name": name,
            "ip": ip,
            "mode": mode,
            "source": source,
            "upstream": source,
            "streamPath": f"/camera/{camera_id}/stream.mjpg",
        }
    return cameras


def read_first_boundary(resp):
    boundary_line = resp.readline()
    while boundary_line in (b"\r\n", b"\n", b""):
        boundary_line = resp.readline()
    return boundary_line


def probe_upstream(url):
    parsed = urlparse(url)
    host = parsed.hostname or "127.0.0.1"
    port = parsed.port or (443 if parsed.scheme == "https" else 80)
    try:
        with socket.create_connection((host, port), timeout=2):
            return True
    except Exception:
        return False


class CameraFeedStore:
    def __init__(self, camera):
        self.camera = camera
        self.lock = threading.Lock()
        self.latest_frame = None
        self.last_update = 0.0
        self.frame_counter = 0
        self.thread = threading.Thread(target=self.run, daemon=True)

    def start(self):
        self.thread.start()

    def is_recent(self, max_age_seconds=8):
        with self.lock:
            return self.latest_frame is not None and (time.time() - self.last_update) <= max_age_seconds

    def snapshot(self):
        with self.lock:
            return self.latest_frame, self.frame_counter, self.last_update

    def _store_frame(self, frame):
        with self.lock:
            self.latest_frame = frame
            self.last_update = time.time()
            self.frame_counter += 1

    def run(self):
        while True:
            if self.camera["mode"] == "scene-dir":
                self._run_scene_dir()
            else:
                self._run_mjpeg_upstream()

    def _run_scene_dir(self):
        source_dir = self.camera["source"]
        newest_path = None
        newest_mtime = 0.0

        try:
            candidates = []
            for name in os.listdir(source_dir):
                if not name.lower().endswith(".jpg"):
                    continue
                path = os.path.join(source_dir, name)
                try:
                    mtime = os.path.getmtime(path)
                except OSError:
                    continue
                candidates.append((mtime, path))

            if not candidates:
                time.sleep(0.4)
                return

            candidates.sort()
            newest_mtime, newest_path = candidates[-1]
            if newest_mtime > self.last_update and newest_path:
                with open(newest_path, "rb") as fh:
                    frame = fh.read()
                if frame:
                    self._store_frame(frame)

            if len(candidates) > 6:
                for _, old_path in candidates[:-6]:
                    try:
                        os.remove(old_path)
                    except OSError:
                        pass
        except Exception:
            time.sleep(0.8)
            return

        time.sleep(0.3)

    def _run_mjpeg_upstream(self):
        req = urllib.request.Request(
            self.camera["upstream"],
            headers={"User-Agent": "BardiCctvWebBridge/1.0"},
        )
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                boundary_line = read_first_boundary(resp)
                if not boundary_line.startswith(b"--"):
                    time.sleep(1)
                    return

                boundary = boundary_line.strip()
                while True:
                    headers = {}
                    while True:
                        line = resp.readline()
                        if not line:
                            raise EOFError("Stream ended while reading headers")
                        if line in (b"\r\n", b"\n"):
                            break
                        decoded = line.decode("latin1", errors="replace")
                        if ":" in decoded:
                            key, value = decoded.split(":", 1)
                            headers[key.strip().lower()] = value.strip()

                    length = int(headers.get("content-length", "0") or "0")
                    if length <= 0:
                        raise EOFError("Missing frame length in MJPEG stream")

                    frame = resp.read(length)
                    if len(frame) != length:
                        raise EOFError("Incomplete frame read from MJPEG stream")
                    self._store_frame(frame)

                    trailer = resp.readline()
                    if not trailer:
                        raise EOFError("Stream ended after frame payload")

                    while trailer in (b"\r\n", b"\n"):
                        trailer = resp.readline()
                        if not trailer:
                            raise EOFError("Stream ended before boundary")

                    if not trailer.startswith(boundary):
                        raise EOFError("Unexpected boundary while reading MJPEG stream")
        except Exception:
            time.sleep(1)


def build_handler(directory, cameras, feed_stores):
    class BardiHandler(SimpleHTTPRequestHandler):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, directory=directory, **kwargs)

        def do_GET(self):
            clean_path = self.path.split("?", 1)[0]

            legacy_camera_map = {
                "/stream.mjpg": "1",
                "/camera1.mjpg": "1",
                "/camera2.mjpg": "2",
            }
            if clean_path in legacy_camera_map:
                camera_id = legacy_camera_map[clean_path]
                if camera_id not in cameras and clean_path == "/stream.mjpg" and cameras:
                    camera_id = next(iter(cameras.keys()))
                if camera_id in cameras:
                    self.serve_cached_mjpeg(camera_id)
                    return
                self.send_error(404, "Unknown camera")
                return

            if clean_path.startswith("/camera/") and clean_path.endswith("/stream.mjpg"):
                parts = clean_path.strip("/").split("/")
                if len(parts) == 3 and parts[0] == "camera":
                    camera_id = parts[1]
                    camera = cameras.get(camera_id)
                    if camera:
                        self.serve_cached_mjpeg(camera_id)
                        return
                    self.send_error(404, "Unknown camera")
                    return

            if clean_path.startswith("/camera/") and clean_path.endswith("/latest.jpg"):
                parts = clean_path.strip("/").split("/")
                if len(parts) == 3 and parts[0] == "camera":
                    camera_id = parts[1]
                    camera = cameras.get(camera_id)
                    if camera:
                        self.serve_latest_jpeg(camera_id)
                        return
                    self.send_error(404, "Unknown camera")
                    return

            if clean_path == "/api/cameras":
                payload = {
                    "cameras": [
                        {
                            "id": cam["id"],
                            "name": cam["name"],
                            "ip": cam["ip"],
                            "streamPath": cam["streamPath"],
                            "latestPath": f"/camera/{cam['id']}/latest.jpg",
                        }
                        for cam in cameras.values()
                    ]
                }
                self.send_json(payload)
                return

            if clean_path == "/api/status":
                payload = {
                    "cameras": {
                        camera_id: feed_stores[camera_id].is_recent()
                        for camera_id in cameras.keys()
                    }
                }
                self.send_json(payload)
                return

            super().do_GET()

        def send_json(self, payload):
            encoded = json.dumps(payload).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(encoded)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(encoded)

        def serve_latest_jpeg(self, camera_id):
            store = feed_stores[camera_id]
            frame, _, _ = store.snapshot()
            if not frame:
                self.send_error(503, "Frame not ready")
                return

            self.send_response(200)
            self.send_header("Content-Type", "image/jpeg")
            self.send_header("Content-Length", str(len(frame)))
            self.send_header("Cache-Control", "no-cache, no-store, must-revalidate")
            self.send_header("Pragma", "no-cache")
            self.end_headers()
            self.wfile.write(frame)

        def serve_cached_mjpeg(self, camera_id):
            store = feed_stores[camera_id]
            boundary_token = "frame"
            try:
                self.send_response(200)
                self.send_header(
                    "Content-Type",
                    f"multipart/x-mixed-replace; boundary={boundary_token}",
                )
                self.send_header("Cache-Control", "no-cache, no-store, must-revalidate")
                self.send_header("Pragma", "no-cache")
                self.send_header("Connection", "close")
                self.end_headers()

                last_counter = -1
                idle_loops = 0
                while True:
                    frame, counter, _ = store.snapshot()
                    if frame and counter != last_counter:
                        header = (
                            f"--{boundary_token}\r\n"
                            "Content-Type: image/jpeg\r\n"
                            f"Content-Length: {len(frame)}\r\n\r\n"
                        ).encode("ascii")
                        self.wfile.write(header)
                        self.wfile.write(frame)
                        self.wfile.write(b"\r\n")
                        self.wfile.flush()
                        last_counter = counter
                        idle_loops = 0
                    else:
                        time.sleep(0.2)
                        idle_loops += 1
                        if idle_loops > 150 and not store.is_recent():
                            raise TimeoutError("No fresh frame available")
            except BrokenPipeError:
                pass
            except ConnectionResetError:
                pass
            except Exception as exc:
                if not self.wfile.closed:
                    try:
                        self.wfile.write(
                            f"--{boundary_token}\r\nContent-Type: text/plain\r\n\r\nStream error: {exc}\r\n".encode(
                                "utf-8",
                                errors="replace",
                            )
                        )
                    except Exception:
                        pass

        def log_message(self, format, *args):
            return

    return BardiHandler


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bind", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=18081)
    parser.add_argument("--directory", default=os.path.dirname(os.path.abspath(__file__)))
    parser.add_argument("--camera", action="append", required=True)
    args = parser.parse_args()

    cameras = parse_camera_specs(args.camera)
    feed_stores = {
        camera_id: CameraFeedStore(camera)
        for camera_id, camera in cameras.items()
    }
    for store in feed_stores.values():
        store.start()

    handler = build_handler(args.directory, cameras, feed_stores)
    server = ThreadingHTTPServer((args.bind, args.port), handler)
    try:
        server.serve_forever()
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
