import html
import json
import re
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

import yt_dlp


MAX_BODY_BYTES = 64 * 1024
MAX_TRANSCRIPT_CHARS = 120_000
YOUTUBE_HOSTS = {
    "youtube.com",
    "www.youtube.com",
    "m.youtube.com",
    "music.youtube.com",
    "youtu.be",
}


def is_youtube_url(value: str) -> bool:
    try:
        parsed = urlparse(value)
    except ValueError:
        return False
    return parsed.scheme in {"http", "https"} and (parsed.hostname or "").lower() in YOUTUBE_HOSTS


def choose_language(tracks: dict, preferred=None, prefer_original=False):
    if not tracks:
        return None, []
    keys = list(tracks.keys())
    if preferred:
        for wanted in (f"{preferred}-orig", preferred):
            if wanted in tracks:
                return wanted, tracks[wanted]
    if prefer_original:
        original = next((key for key in keys if key.lower().endswith("-orig")), None)
        if original:
            return original, tracks[original]
    for wanted in ("uk", "uk-orig", "ru", "ru-orig", "en", "en-orig"):
        if wanted in tracks:
            return wanted, tracks[wanted]
    for prefix in ("uk", "ru", "en"):
        match = next((key for key in keys if key.lower().startswith(prefix)), None)
        if match:
            return match, tracks[match]
    key = keys[0]
    return key, tracks[key]


def choose_tracks(formats: list):
    priorities = {"json3": 0, "vtt": 1, "srv3": 2, "srv2": 3, "srv1": 4}
    tracks = [item for item in formats if item.get("url")]
    return sorted(tracks, key=lambda item: priorities.get(item.get("ext"), 99))


def clean_lines(lines: list[str]) -> str:
    cleaned = []
    previous = None
    for value in lines:
        line = html.unescape(re.sub(r"<[^>]+>", "", value or ""))
        line = re.sub(r"\s+", " ", line).strip()
        if not line or line == previous:
            continue
        cleaned.append(line)
        previous = line
    return "\n".join(cleaned)[:MAX_TRANSCRIPT_CHARS]


def parse_json3(raw: bytes) -> str:
    payload = json.loads(raw.decode("utf-8", errors="replace"))
    groups = []
    current_bucket = None
    current_parts = []

    def flush_group():
        if current_bucket is None or not current_parts:
            return
        seconds = current_bucket * 30
        timestamp = f"{seconds // 3600:02d}:{(seconds % 3600) // 60:02d}:{seconds % 60:02d}"
        text = clean_lines(current_parts).replace("\n", " ")
        if text:
            groups.append(f"[{timestamp}] {text}")

    for event in payload.get("events", []):
        text = "".join(segment.get("utf8", "") for segment in event.get("segs", []))
        if not text.strip():
            continue
        bucket = max(0, int(event.get("tStartMs") or 0) // 30000)
        if current_bucket is not None and bucket != current_bucket:
            flush_group()
            current_parts = []
        current_bucket = bucket
        current_parts.append(text)
    flush_group()
    return "\n".join(groups)[:MAX_TRANSCRIPT_CHARS]


def parse_vtt(raw: bytes) -> str:
    lines = []
    for line in raw.decode("utf-8", errors="replace").splitlines():
        stripped = line.strip()
        if not stripped or stripped == "WEBVTT" or "-->" in stripped:
            continue
        if re.fullmatch(r"\d+", stripped) or stripped.startswith(("Kind:", "Language:", "NOTE")):
            continue
        lines.append(stripped)
    return clean_lines(lines)


def download_transcript(track: dict, ydl) -> str:
    response = ydl.urlopen(track["url"])
    try:
        raw = response.read(4 * 1024 * 1024)
    finally:
        response.close()
    return parse_json3(raw) if track.get("ext") == "json3" else parse_vtt(raw)


def extract_youtube(url: str) -> dict:
    options = {
        "quiet": True,
        "no_warnings": True,
        "skip_download": True,
        "noplaylist": True,
        "socket_timeout": 20,
        "retries": 2,
        "extractor_retries": 2,
    }
    with yt_dlp.YoutubeDL(options) as ydl:
        info = ydl.extract_info(url, download=False)

        source_language = info.get("language")
        language, formats = choose_language(
            info.get("subtitles") or {}, preferred=source_language
        )
        subtitle_type = "manual"
        if not formats:
            language, formats = choose_language(
                info.get("automatic_captions") or {},
                preferred=source_language,
                prefer_original=True,
            )
            subtitle_type = "automatic"

        transcript = ""
        transcript_errors = []
        tracks = choose_tracks(formats)
        for attempt, track in enumerate(tracks[:4]):
            try:
                transcript = download_transcript(track, ydl)
                if transcript:
                    break
            except Exception as exc:  # Metadata is still useful if captions fail.
                transcript_errors.append(str(exc)[:500])
                if attempt < min(len(tracks), 4) - 1:
                    time.sleep(1.5)

    transcript_error = transcript_errors[-1] if transcript_errors and not transcript else None

    return {
        "ok": True,
        "id": info.get("id"),
        "title": info.get("title") or "",
        "description": (info.get("description") or "")[:20_000],
        "channel": info.get("channel") or info.get("uploader") or "",
        "channel_url": info.get("channel_url") or info.get("uploader_url") or "",
        "duration": info.get("duration"),
        "upload_date": info.get("upload_date"),
        "webpage_url": info.get("webpage_url") or url,
        "categories": (info.get("categories") or [])[:20],
        "tags": (info.get("tags") or [])[:50],
        "chapters": (info.get("chapters") or [])[:200],
        "language": language,
        "subtitle_type": subtitle_type if tracks else None,
        "transcript": transcript,
        "transcript_characters": len(transcript),
        "transcript_error": transcript_error,
    }


class Handler(BaseHTTPRequestHandler):
    server_version = "InboxYouTubeReader/1.0"

    def log_message(self, fmt, *args):
        return

    def send_json(self, status: int, payload: dict):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/healthz":
            self.send_json(200, {"status": "ok"})
        else:
            self.send_json(404, {"ok": False, "error": "not_found"})

    def do_POST(self):
        if self.path != "/extract":
            self.send_json(404, {"ok": False, "error": "not_found"})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length <= 0 or length > MAX_BODY_BYTES:
                raise ValueError("invalid_body_size")
            payload = json.loads(self.rfile.read(length))
            url = str(payload.get("url") or "").strip()
            if not is_youtube_url(url):
                self.send_json(400, {"ok": False, "error": "unsupported_url"})
                return
            self.send_json(200, extract_youtube(url))
        except Exception as exc:
            self.send_json(200, {"ok": False, "error": str(exc)[:1000]})


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
