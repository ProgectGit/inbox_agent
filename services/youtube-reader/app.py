import html
import json
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse
from urllib.request import Request, urlopen

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


def choose_language(tracks: dict):
    if not tracks:
        return None, []
    keys = list(tracks.keys())
    for wanted in ("uk", "uk-orig", "ru", "ru-orig", "en", "en-orig"):
        if wanted in tracks:
            return wanted, tracks[wanted]
    for prefix in ("uk", "ru", "en"):
        match = next((key for key in keys if key.lower().startswith(prefix)), None)
        if match:
            return match, tracks[match]
    key = keys[0]
    return key, tracks[key]


def choose_track(formats: list):
    for extension in ("json3", "vtt", "srv3", "srv2", "srv1"):
        track = next((item for item in formats if item.get("ext") == extension and item.get("url")), None)
        if track:
            return track
    return next((item for item in formats if item.get("url")), None)


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
    lines = []
    for event in payload.get("events", []):
        text = "".join(segment.get("utf8", "") for segment in event.get("segs", []))
        if text:
            lines.append(text)
    return clean_lines(lines)


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


def download_transcript(track: dict) -> str:
    request = Request(
        track["url"],
        headers={"User-Agent": "Mozilla/5.0 (compatible; InboxAgent/1.0)"},
    )
    with urlopen(request, timeout=20) as response:
        raw = response.read(4 * 1024 * 1024)
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

    language, formats = choose_language(info.get("subtitles") or {})
    subtitle_type = "manual"
    if not formats:
        language, formats = choose_language(info.get("automatic_captions") or {})
        subtitle_type = "automatic"

    transcript = ""
    transcript_error = None
    track = choose_track(formats)
    if track:
        try:
            transcript = download_transcript(track)
        except Exception as exc:  # Metadata is still useful if captions fail.
            transcript_error = str(exc)[:500]

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
        "subtitle_type": subtitle_type if track else None,
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
