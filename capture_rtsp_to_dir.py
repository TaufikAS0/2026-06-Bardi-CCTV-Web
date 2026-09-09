import argparse
import os
import time

import cv2


def prune_old_jpegs(output_dir, keep_count):
    try:
        names = [
            name for name in os.listdir(output_dir)
            if name.lower().endswith(".jpg")
        ]
    except OSError:
        return

    if len(names) <= keep_count:
        return

    paths = []
    for name in names:
        path = os.path.join(output_dir, name)
        try:
            paths.append((os.path.getmtime(path), path))
        except OSError:
            continue

    paths.sort()
    for _, old_path in paths[:-keep_count]:
        try:
            os.remove(old_path)
        except OSError:
            pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--uri", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--prefix", default="cam1")
    parser.add_argument("--interval-ms", type=int, default=900)
    parser.add_argument("--jpeg-quality", type=int, default=82)
    parser.add_argument("--keep-count", type=int, default=8)
    parser.add_argument("--reconnect-seconds", type=int, default=18)
    args = parser.parse_args()

    os.environ.setdefault("OPENCV_FFMPEG_CAPTURE_OPTIONS", "rtsp_transport;tcp")
    os.makedirs(args.output_dir, exist_ok=True)

    counter = 0
    min_interval = max(0.1, args.interval_ms / 1000.0)

    while True:
        capture = cv2.VideoCapture(args.uri, cv2.CAP_FFMPEG)
        if not capture.isOpened():
            capture.release()
            time.sleep(2)
            continue

        try:
            consecutive_failures = 0
            opened_at = time.time()
            while True:
                if (time.time() - opened_at) >= max(5, args.reconnect_seconds):
                    break

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
                    [int(cv2.IMWRITE_JPEG_QUALITY), args.jpeg_quality],
                )
                if not encoded:
                    continue

                counter += 1
                temp_path = os.path.join(
                    args.output_dir,
                    f"{args.prefix}-{counter:06d}.tmp",
                )
                final_path = os.path.join(
                    args.output_dir,
                    f"{args.prefix}-{counter:06d}.jpg",
                )
                with open(temp_path, "wb") as fh:
                    fh.write(buffer.tobytes())
                os.replace(temp_path, final_path)
                prune_old_jpegs(args.output_dir, args.keep_count)
                time.sleep(min_interval)
        finally:
            capture.release()

        time.sleep(1)


if __name__ == "__main__":
    main()
