import argparse
import json
import os
import socket
import threading
import time
import urllib.request
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

try:
    import cv2
except Exception:
    cv2 = None


def profile_sort_key(profile_name):
    order = {
        "default": 0,
        "fast": 1,
        "sharp": 2,
    }
    return order.get(profile_name, 99), profile_name


def pick_camera_profile(camera, requested=None):
    profiles = camera["profiles"]
    if requested and requested in profiles:
        return profiles[requested]

    default_profile = camera.get("defaultProfile")
    if default_profile and default_profile in profiles:
        return profiles[default_profile]

    for profile_name in ("default", "fast", "sharp"):
        if profile_name in profiles:
            return profiles[profile_name]

    first_key = sorted(profiles.keys(), key=profile_sort_key)[0]
    return profiles[first_key]


def camera_profile_key(camera_id, profile_name):
    return f"{camera_id}:{profile_name}"


def parse_camera_specs(raw_specs):
    cameras = {}
    for raw_spec in raw_specs:
        parts = raw_spec.split("|", 5)
        if len(parts) == 4:
            camera_id, name, ip, source = parts
            mode = "mjpeg"
            profile_name = "default"
        elif len(parts) == 5:
            camera_id, name, ip, mode, source = parts
            profile_name = "default"
        elif len(parts) == 6:
            camera_id, name, ip, mode, source, profile_name = parts
        else:
            raise ValueError("Each --camera value must be id|name|ip|source, id|name|ip|mode|source, or id|name|ip|mode|source|profile")

        profile_name = (profile_name or "default").strip() or "default"
        camera = cameras.setdefault(camera_id, {
            "id": camera_id,
            "name": name,
            "ip": ip,
            "profiles": {},
        })
        camera["name"] = name
        camera["ip"] = ip

        stream_path = f"/camera/{camera_id}/stream.mjpg"
        latest_path = f"/camera/{camera_id}/latest.jpg"
        if profile_name != "default":
            stream_path = f"/camera/{camera_id}/{profile_name}/stream.mjpg"
            latest_path = f"/camera/{camera_id}/{profile_name}/latest.jpg"

        camera["profiles"][profile_name] = {
            "profile": profile_name,
            "mode": mode,
            "source": source,
            "upstream": source,
            "streamPath": stream_path,
            "latestPath": latest_path,
        }

    for camera in cameras.values():
        default_profile = pick_camera_profile(camera)
        camera["defaultProfile"] = default_profile["profile"]
        camera["mode"] = default_profile["mode"]
        camera["source"] = default_profile["source"]
        camera["upstream"] = default_profile["upstream"]
        camera["streamPath"] = f"/camera/{camera['id']}/stream.mjpg"
        camera["latestPath"] = f"/camera/{camera['id']}/latest.jpg"
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


class ViewerRegistry:
    def __init__(self):
        self.lock = threading.Lock()
        self.sessions = {}
        self.active_streams = 0

    def _prune_locked(self, max_age_seconds=35):
        cutoff = time.time() - max_age_seconds
        stale_ids = [
            session_id
            for session_id, session in self.sessions.items()
            if session["seen_at"] < cutoff
        ]
        for session_id in stale_ids:
            self.sessions.pop(session_id, None)

    def heartbeat(self, session_id, client_ip="", user_agent=""):
        if not session_id:
            session_id = f"anon:{client_ip or 'unknown'}"

        with self.lock:
            self.sessions[session_id] = {
                "seen_at": time.time(),
                "client_ip": client_ip,
                "user_agent": user_agent[:160],
            }
            self._prune_locked()
            return {
                "viewerCount": len(self.sessions),
                "activeStreams": self.active_streams,
            }

    def snapshot(self):
        with self.lock:
            self._prune_locked()
            return {
                "viewerCount": len(self.sessions),
                "activeStreams": self.active_streams,
            }

    def open_stream(self):
        with self.lock:
            self.active_streams += 1

    def close_stream(self):
        with self.lock:
            self.active_streams = max(0, self.active_streams - 1)


class CameraFeedStore:
    def __init__(self, camera):
        self.camera = camera
        self.lock = threading.Lock()
        self.latest_frame = None
        self.last_update = 0.0
        self.last_source_mtime = 0.0
        self.frame_counter = 0
        self.thread = threading.Thread(target=self.run, daemon=True)

    def start(self):
        if self.camera["mode"] != "placeholder":
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
            elif self.camera["mode"] == "rtsp-opencv":
                self._run_rtsp_opencv()
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
            if newest_mtime > self.last_source_mtime and newest_path:
                with open(newest_path, "rb") as fh:
                    frame = fh.read()
                if frame:
                    self.last_source_mtime = newest_mtime
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
            headers={"User-Agent": "CctvHackGhostGridBridge/1.0"},
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

    def _run_rtsp_opencv(self):
        if cv2 is None:
            time.sleep(2)
            return

        os.environ.setdefault("OPENCV_FFMPEG_CAPTURE_OPTIONS", "rtsp_transport;tcp")
        capture = cv2.VideoCapture(self.camera["source"], cv2.CAP_FFMPEG)
        if not capture.isOpened():
            capture.release()
            time.sleep(2)
            return

        try:
            consecutive_failures = 0
            while True:
                ok, frame = capture.read()
                if not ok or frame is None:
                    consecutive_failures += 1
                    if consecutive_failures >= 8:
                        break
                    time.sleep(0.2)
                    continue

                consecutive_failures = 0
                encoded, buffer = cv2.imencode(
                    ".jpg",
                    frame,
                    [int(cv2.IMWRITE_JPEG_QUALITY), 82],
                )
                if encoded:
                    self._store_frame(buffer.tobytes())
        finally:
            capture.release()

        time.sleep(1)


def build_handler(directory, cameras, feed_stores, viewer_registry):
    default_stream_camera_id = next(
        (
            camera_id
            for camera_id, camera in cameras.items()
            if any(profile["mode"] != "placeholder" for profile in camera["profiles"].values())
        ),
        next(iter(cameras.keys()), None),
    )

    def resolve_store(camera_id, profile_name=None):
        camera = cameras[camera_id]
        profile = pick_camera_profile(camera, profile_name)
        return profile, feed_stores[camera_profile_key(camera_id, profile["profile"])]

    class CctvHackHandler(SimpleHTTPRequestHandler):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, directory=directory, **kwargs)

        def do_GET(self):
            parsed = urlparse(self.path)
            clean_path = parsed.path

            legacy_camera_map = {
                "/stream.mjpg": default_stream_camera_id,
                "/camera1.mjpg": "1",
                "/camera2.mjpg": "2",
            }
            if clean_path in legacy_camera_map:
                camera_id = legacy_camera_map[clean_path]
                if camera_id in cameras:
                    self.serve_cached_mjpeg(camera_id)
                    return
                self.send_error(404, "Unknown camera")
                return

            if clean_path.startswith("/camera/") and clean_path.endswith("/stream.mjpg"):
                parts = clean_path.strip("/").split("/")
                if parts[0] == "camera":
                    if len(parts) == 3:
                        camera_id = parts[1]
                        profile_name = None
                    elif len(parts) == 4:
                        camera_id = parts[1]
                        profile_name = parts[2]
                    else:
                        camera_id = None
                        profile_name = None

                    camera = cameras.get(camera_id) if camera_id else None
                    if camera:
                        self.serve_cached_mjpeg(camera_id, profile_name)
                        return
                    self.send_error(404, "Unknown camera")
                    return

            if clean_path.startswith("/camera/") and clean_path.endswith("/latest.jpg"):
                parts = clean_path.strip("/").split("/")
                if parts[0] == "camera":
                    if len(parts) == 3:
                        camera_id = parts[1]
                        profile_name = None
                    elif len(parts) == 4:
                        camera_id = parts[1]
                        profile_name = parts[2]
                    else:
                        camera_id = None
                        profile_name = None

                    camera = cameras.get(camera_id) if camera_id else None
                    if camera:
                        self.serve_latest_jpeg(camera_id, profile_name)
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
                            "latestPath": cam["latestPath"],
                            "profiles": {
                                profile_name: {
                                    "streamPath": profile["streamPath"],
                                    "latestPath": profile["latestPath"],
                                    "mode": profile["mode"],
                                }
                                for profile_name, profile in sorted(cam["profiles"].items(), key=lambda item: profile_sort_key(item[0]))
                            },
                        }
                        for cam in cameras.values()
                    ]
                }
                self.send_json(payload)
                return

            if clean_path == "/api/status":
                metrics = viewer_registry.snapshot()
                payload = {
                    "cameras": {
                        camera_id: any(
                            feed_stores[camera_profile_key(camera_id, profile_name)].is_recent()
                            for profile_name in camera["profiles"].keys()
                        )
                        for camera_id, camera in cameras.items()
                    },
                    "viewerCount": metrics["viewerCount"],
                    "activeStreams": metrics["activeStreams"],
                }
                self.send_json(payload)
                return

            if clean_path == "/api/heartbeat":
                query = parse_qs(parsed.query)
                session_id = (query.get("sid") or [""])[0].strip()
                metrics = viewer_registry.heartbeat(
                    session_id=session_id,
                    client_ip=self.client_address[0] if self.client_address else "",
                    user_agent=self.headers.get("User-Agent", ""),
                )
                self.send_json(metrics)
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

        def serve_latest_jpeg(self, camera_id, profile_name=None):
            profile, store = resolve_store(camera_id, profile_name)
            if profile["mode"] == "placeholder":
                self.send_error(503, "Camera disabled")
                return

            frame, _, _ = store.snapshot()
            if not frame or not store.is_recent():
                self.send_error(503, "Frame not ready")
                return

            self.send_response(200)
            self.send_header("Content-Type", "image/jpeg")
            self.send_header("Content-Length", str(len(frame)))
            self.send_header("Cache-Control", "no-cache, no-store, must-revalidate")
            self.send_header("Pragma", "no-cache")
            self.end_headers()
            self.wfile.write(frame)

        def serve_cached_mjpeg(self, camera_id, profile_name=None):
            profile, store = resolve_store(camera_id, profile_name)
            if profile["mode"] == "placeholder":
                self.send_error(503, "Camera disabled")
                return

            boundary_token = "frame"
            stream_registered = False
            try:
                first_frame = None
                first_counter = -1
                for _ in range(12):
                    frame, counter, _ = store.snapshot()
                    if frame:
                        first_frame = frame
                        first_counter = counter
                        break
                    time.sleep(0.2)

                if not first_frame:
                    self.send_error(503, "Frame not ready")
                    return

                viewer_registry.open_stream()
                stream_registered = True
                self.send_response(200)
                self.send_header(
                    "Content-Type",
                    f"multipart/x-mixed-replace; boundary={boundary_token}",
                )
                self.send_header("Cache-Control", "no-cache, no-store, must-revalidate")
                self.send_header("Pragma", "no-cache")
                self.send_header("Connection", "close")
                self.end_headers()

                last_counter = first_counter - 1
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
            finally:
                if stream_registered:
                    viewer_registry.close_stream()

        def log_message(self, format, *args):
            return

    return CctvHackHandler


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bind", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=18081)
    parser.add_argument("--directory", default=os.path.dirname(os.path.abspath(__file__)))
    parser.add_argument("--camera", action="append", required=True)
    args = parser.parse_args()

    cameras = parse_camera_specs(args.camera)
    feed_stores = {
        camera_profile_key(camera_id, profile_name): CameraFeedStore(profile)
        for camera_id, camera in cameras.items()
        for profile_name, profile in camera["profiles"].items()
    }
    for store in feed_stores.values():
        store.start()

    viewer_registry = ViewerRegistry()
    handler = build_handler(args.directory, cameras, feed_stores, viewer_registry)
    server = ThreadingHTTPServer((args.bind, args.port), handler)
    try:
        server.serve_forever()
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
