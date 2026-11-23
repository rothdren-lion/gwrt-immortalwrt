#!/usr/bin/env python3
"""Small GWRT control plane: stdlib HTTP server, SQLite, and JSON only."""

from __future__ import annotations

import base64
from contextlib import contextmanager
import hashlib
import hmac
import ipaddress
import json
import mimetypes
import os
from http import HTTPStatus
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import re
import secrets
import sqlite3
import sys
import threading
import time
import traceback
from urllib.error import URLError
from urllib.parse import urlencode, quote
from urllib.request import Request, urlopen
from urllib.parse import parse_qs, unquote, urlparse

import geo


ROOT = Path(__file__).resolve().parent
STATIC = ROOT / "static"
VERSION = "17.17"


def _build_time() -> str:
    """Build timestamp baked at image build time (GWRT_BUILD_TIME, /app/BUILD_TIME,
    or the server.py mtime as a last resort)."""
    value = os.environ.get("GWRT_BUILD_TIME", "").strip()
    if value:
        return value[:64]
    try:
        value = (ROOT / "BUILD_TIME").read_text(encoding="utf-8").strip()
    except OSError:
        value = ""
    if value:
        return value[:64]
    try:
        return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(os.path.getmtime(__file__)))
    except OSError:
        return "unknown"


BUILD_TIME = _build_time()
AGENT_UPDATE_MANIFEST = STATIC / "updates" / "agent" / "manifest.json"
DB_PATH = Path(os.environ.get("GWRT_DB", str(ROOT / "data" / "gwrt.sqlite3")))
HOST = os.environ.get("GWRT_HOST", "0.0.0.0")
PORT = int(os.environ.get("GWRT_PORT", "8000"))
SESSION_TTL = 7 * 24 * 60 * 60
DEVICE_ONLINE_TTL = 900
MAX_BODY = 512 * 1024
MAX_TELEMETRY_BYTES = 128 * 1024
MAX_CLIENTS = 512
MAX_PENDING_COMMANDS = 64
CLAIM_TTL = 5 * 60
APP_LOGIN_CODE_TTL = 2 * 60
APP_LOGIN_CODE_LENGTH = 8
APP_LOGIN_CODE_ALPHABET = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"
CAPTCHA_TTL = 5 * 60
CAPTCHA_ALPHABET = "23456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz"
_CAPTCHA_LOCK = threading.Lock()
_CAPTCHAS = {}


def captcha_new():
    """生成一个验证码：返回 (id, answer, svg)。"""
    import random as _random
    code = "".join(_random.choice(CAPTCHA_ALPHABET) for _ in range(4))
    captcha_id = secrets.token_urlsafe(12)
    with _CAPTCHA_LOCK:
        _CAPTCHAS[captcha_id] = (hash_token(code.lower()), now() + CAPTCHA_TTL)
        if len(_CAPTCHAS) > 512:
            expired = [k for k, (_, t) in list(_CAPTCHAS.items()) if t <= now()]
            for k in expired[:256]:
                _CAPTCHAS.pop(k, None)
    return captcha_id, code, captcha_svg(code)


def captcha_consume(captcha_id: str, answer: str) -> bool:
    """校验并单次消费验证码。"""
    with _CAPTCHA_LOCK:
        entry = _CAPTCHAS.pop(captcha_id, None)
    if not entry:
        return False
    expected_hash, expires = entry
    if expires <= now():
        return False
    return hmac.compare_digest(expected_hash, hash_token(str(answer or "").strip().lower()))


def captcha_svg(code: str) -> str:
    """绘制一个简单的 SVG 验证码（无字体依赖，客户端渲染字符）。"""
    import random as _random
    rng = _random.Random()
    colors = ["#3b82f6", "#06b6d4", "#8b5cf6", "#f59e0b", "#10b981", "#ef4444"]
    chars = list(code)
    parts = []
    for i, ch in enumerate(chars):
        x = 18 + i * 26 + rng.randint(-3, 3)
        y = 30 + rng.randint(-4, 4)
        angle = rng.randint(-18, 18)
        color = colors[rng.randrange(len(colors))]
        parts.append(
            '<text x="%d" y="%d" transform="rotate(%d %d %d)" font-family="monospace" '
            'font-size="28" font-weight="600" fill="%s">%s</text>'
            % (x, y, angle, x, y, color, ch)
        )
    lines = []
    for _ in range(4):
        lines.append(
            '<line x1="%d" y1="%d" x2="%d" y2="%d" stroke="rgba(148,163,184,0.5)" stroke-width="1"/>'
            % (rng.randint(0, 40), rng.randint(0, 44), rng.randint(80, 120), rng.randint(0, 44))
        )
    dots = []
    for _ in range(8):
        dots.append('<circle cx="%d" cy="%d" r="1.2" fill="rgba(148,163,184,0.6)"/>' % (rng.randint(0, 120), rng.randint(0, 44)))
    return (
        '<svg viewBox="0 0 120 44" width="120" height="44" xmlns="http://www.w3.org/2000/svg" '
        'role="img" aria-label="captcha">'
        '<rect width="120" height="44" rx="6" fill="rgba(148,163,184,0.08)"/>'
        + "".join(lines) + "".join(dots) + "".join(parts) + "</svg>"
    )
SESSION_SECRET = os.environ.get("GWRT_SESSION_SECRET", "") or secrets.token_hex(32)

_RATE_LOCK = threading.Lock()
_RATE_BUCKETS = {}

DEVICE_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{2,79}$")
MAC_RE = re.compile(r"^[0-9a-f]{2}(?::[0-9a-f]{2}){5}$", re.I)
TIME_RE = re.compile(r"^[0-2][0-9]:[0-5][0-9]$")
HOSTNAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9.-]{0,62}[A-Za-z0-9]$")
USERNAME_RE = re.compile(r"^[^\s\x00-\x1f\x7f]{3,64}$")
PACKAGE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]{0,95}$")
PACKAGE_QUERY_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+:-]{0,63}$")
PLUGIN_IDS = {"easytier", "passwall", "openclash", "aria2", "daed", "appfilter", "istore", "istoreenhance"}
PLUGIN_CONFIG_KEYS = {
    "easytier": {"etcmd", "config_file", "auto_config_interface", "interface_netmask", "auto_config_firewall", "et_forward"},
    "passwall": {"subscription_url", "subscription_remark", "subscription_boot_update"},
    "openclash": {"subscription_url", "subscription_name", "auto_update"},
}
ISTORE_API = "https://istore.istoreos.com/api/store/list"
ISTORE_ICON_BASE = "https://istore.linkease.com.cdn.koolcenter.com"
ISTORE_FALLBACK_API = "https://istore.linkease.com.cdn.koolcenter.com/api/store/list"
_ISTORE_CACHE = {}
_ISTORE_CACHE_TTL = 600
WEATHER_API = "https://wttr.in/%s?format=j1"
WEATHER_TTL = 600
_WEATHER_LOCK = threading.Lock()
_WEATHER_CACHE = {}
_ACTIVE_LOCK = threading.Lock()
_LAST_ACTIVE_AT = 0.0


def mark_active():
    """任一客户端拉取设备列表时调用：让 agent 进入实时上报模式。"""
    global _LAST_ACTIVE_AT
    with _ACTIVE_LOCK:
        _LAST_ACTIVE_AT = time.monotonic()


def report_interval_for_agent():
    """有人在看（60 秒内有拉取）→ 5 秒实时；否则 10 分钟空闲。"""
    with _ACTIVE_LOCK:
        active = time.monotonic() - _LAST_ACTIVE_AT < 60
    return 5 if active else 600


def fetch_weather(client_ip: str):
    """按客户端公网 IP 取环境温度（wttr.in 定位），10 分钟缓存。"""
    key = client_ip or "unknown"
    current = time.monotonic()
    with _WEATHER_LOCK:
        cached = _WEATHER_CACHE.get(key)
        if cached and current - cached[0] < WEATHER_TTL:
            return cached[1]
    request = Request(WEATHER_API % quote(key), headers={"User-Agent": "GWRT-Control/16.3"})
    try:
        with urlopen(request, timeout=8) as response:
            data = json.loads(response.read(1024 * 1024).decode("utf-8"))
        condition = ((data.get("current_condition") or [{}])[0]) or {}
        area = (data.get("nearest_area") or [{}])[0] or {}
        area_name = ""
        try:
            area_name = str((area.get("areaName") or [{}])[0].get("value") or "")
        except (AttributeError, IndexError, TypeError):
            area_name = ""
        result = {
            "ok": True,
            "temp_c": condition.get("temp_C"),
            "feels_c": condition.get("FeelsLikeC"),
            "humidity": condition.get("humidity"),
            "desc": str((condition.get("weatherDesc") or [{}])[0].get("value") or "") if isinstance(condition.get("weatherDesc"), list) else "",
            "area": area_name,
        }
    except (OSError, URLError, ValueError, UnicodeError):
        result = {"ok": False}
    with _WEATHER_LOCK:
        _WEATHER_CACHE[key] = (time.monotonic(), result)
        if len(_WEATHER_CACHE) > 256:
            expired = [k for k, (t, _) in list(_WEATHER_CACHE.items()) if time.monotonic() - t >= WEATHER_TTL]
            for k in expired[:128]:
                _WEATHER_CACHE.pop(k, None)
    return result


def client_ip(request) -> str:
    forwarded = request.headers.get("X-Forwarded-For", "")
    if forwarded:
        return forwarded.split(",")[0].strip()
    real = request.headers.get("X-Real-IP", "")
    if real:
        return real.strip()
    return request.client_address[0] if request.client_address else ""


class RequestError(Exception):
    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = status
        self.message = message


def now() -> int:
    return int(time.time())


def rate_limit(scope: str, identity: str, limit: int, window: int):
    """Small in-process guard; the reverse proxy should still enforce edge limits."""
    key = "%s:%s" % (scope, identity)
    current = time.monotonic()
    with _RATE_LOCK:
        entries = [stamp for stamp in _RATE_BUCKETS.get(key, []) if current - stamp < window]
        if len(entries) >= limit:
            _RATE_BUCKETS[key] = entries
            raise RequestError(HTTPStatus.TOO_MANY_REQUESTS, "请求过于频繁，请稍后再试")
        entries.append(current)
        _RATE_BUCKETS[key] = entries
        if len(_RATE_BUCKETS) > 2048:
            expired = [name for name, stamps in _RATE_BUCKETS.items() if not stamps or current - stamps[-1] >= window]
            for name in expired[:1024]:
                _RATE_BUCKETS.pop(name, None)


def bounded_json(value, name: str, max_bytes: int):
    encoded = json_text(value).encode("utf-8")
    if len(encoded) > max_bytes:
        raise RequestError(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, "%s is too large" % name)
    return encoded.decode("utf-8")


@contextmanager
def db():
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def hash_token(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def app_login_code() -> str:
    return "".join(secrets.choice(APP_LOGIN_CODE_ALPHABET) for _ in range(APP_LOGIN_CODE_LENGTH))


def clean_app_login_code(value) -> str:
    value = clean_text(value, "code", APP_LOGIN_CODE_LENGTH, True).upper()
    if len(value) != APP_LOGIN_CODE_LENGTH or any(char not in APP_LOGIN_CODE_ALPHABET for char in value):
        raise RequestError(HTTPStatus.BAD_REQUEST, "invalid app login code")
    return value


def password_hash(password: str) -> str:
    iterations = 180_000
    salt = secrets.token_bytes(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, iterations)
    return "pbkdf2_sha256$%d$%s$%s" % (
        iterations,
        base64.urlsafe_b64encode(salt).decode(),
        base64.urlsafe_b64encode(digest).decode(),
    )


def password_matches(password: str, encoded: str) -> bool:
    try:
        algorithm, iterations, salt, expected = encoded.split("$", 3)
        if algorithm != "pbkdf2_sha256":
            return False
        salt_bytes = base64.urlsafe_b64decode(salt.encode())
        expected_bytes = base64.urlsafe_b64decode(expected.encode())
        actual = hashlib.pbkdf2_hmac(
            "sha256", password.encode(), salt_bytes, int(iterations)
        )
        return hmac.compare_digest(actual, expected_bytes)
    except (ValueError, TypeError):
        return False


def csrf_token(session_token: str) -> str:
    return hmac.new(
        SESSION_SECRET.encode(), session_token.encode(), hashlib.sha256
    ).hexdigest()


def json_text(value) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def parse_json_text(value: str, fallback):
    try:
        return json.loads(value)
    except (TypeError, ValueError):
        return fallback


def _device_notify_enabled(device_id: str, owner_id: int) -> bool:
    with db() as conn:
        row = conn.execute(
            "SELECT enabled FROM device_notifications WHERE device_id=? AND owner_id=?",
            (device_id, owner_id),
        ).fetchone()
    if row is None:
        return True
    return bool(row["enabled"])


def agent_update_for(arch: str, current_version: int):
    """Return one allowlisted artifact; the Agent verifies its detached usign signature."""
    try:
        manifest = json.loads(AGENT_UPDATE_MANIFEST.read_text(encoding="utf-8"))
        version = int(manifest["version"])
        artifacts = manifest["artifacts"]
    except (OSError, ValueError, KeyError, TypeError):
        return None
    normalized_arch = "aarch64" if "aarch64" in arch.lower() or "arm64" in arch.lower() else arch.lower()
    artifact = artifacts.get(normalized_arch) if isinstance(artifacts, dict) else None
    if version <= current_version or not isinstance(artifact, dict):
        return None
    url = artifact.get("url", "")
    signature = artifact.get("signature", "")
    checksum = artifact.get("sha256", "")
    if (
        not isinstance(url, str)
        or not url.startswith("/updates/agent/")
        or ".." in url
        or not isinstance(signature, str)
        or not signature.startswith("/updates/agent/")
        or ".." in signature
        or not re.fullmatch(r"[a-f0-9]{64}", str(checksum), re.I)
    ):
        return None
    result = {"version": version, "url": url, "signature": signature, "sha256": checksum.lower(), "arch": normalized_arch}
    # 可选：裸二进制通道（绕开 apk/opkg；旧固件 world/源不一致时 apk 会拒绝安装）
    binary = artifact.get("binary", "")
    binary_signature = artifact.get("binary_signature", "")
    binary_sha256 = artifact.get("binary_sha256", "")
    if (
        isinstance(binary, str)
        and binary.startswith("/updates/agent/")
        and ".." not in binary
        and isinstance(binary_signature, str)
        and binary_signature.startswith("/updates/agent/")
        and ".." not in binary_signature
        and re.fullmatch(r"[a-f0-9]{64}", str(binary_sha256), re.I)
    ):
        result.update({
            "binary": binary,
            "binary_signature": binary_signature,
            "binary_sha256": str(binary_sha256).lower(),
        })
    return result


def bounded_external_text(value, max_len: int = 320) -> str:
    if not isinstance(value, str):
        return ""
    value = "".join(char for char in value if ord(char) >= 32 and ord(char) != 127)
    return value[:max_len]


def istore_arch(row) -> str:
    packages = parse_json_text(row["packages"], {})
    for item in packages.get("items", []) if isinstance(packages, dict) else []:
        match = re.search(r"\b(aarch64_cortex-[A-Za-z0-9_-]+|x86_64|arm[a-z0-9_-]*)\b", str(item))
        if match:
            return match.group(1)
    arch = bounded_external_text(row["arch"], 64)
    return "aarch64" if "arm" in arch.lower() or "aarch" in arch.lower() else arch


def fetch_istore_apps(row):
    """iStore 市场列表：10 分钟缓存 + 双源兜底，任一上游失败不阻塞。"""
    arch = istore_arch(row)
    cached = _ISTORE_CACHE.get(arch)
    if cached and cached[0] > time.monotonic():
        return cached[1]
    items = None
    for api in (ISTORE_API, ISTORE_FALLBACK_API):
        try:
            items = _fetch_istore_from(api, arch, row)
            break
        except (OSError, URLError, ValueError, UnicodeError):
            items = None
    if items is None:
        raise RequestError(HTTPStatus.BAD_GATEWAY, "iStore 市场暂时不可用，请稍后再试")
    _ISTORE_CACHE[arch] = (time.monotonic() + _ISTORE_CACHE_TTL, items)
    return items


def _fetch_istore_from(api, arch, row):
    query = urlencode(
        {
            "modelArch": arch,
            "deviceId": bounded_external_text(row["device_id"], 80),
            "channel": "",
            "ver": bounded_external_text(row["version"], 64),
            "feature": "",
        }
    )
    request = Request(api + "?" + query, headers={"User-Agent": "GWRT-Control/0.7"})
    with urlopen(request, timeout=8) as response:
        data = json.loads(response.read(2 * 1024 * 1024).decode("utf-8"))
    result = data.get("result") if isinstance(data, dict) and data.get("success") == 0 else None
    apps = result.get("apps", []) if isinstance(result, dict) else []
    if not isinstance(apps, list):
        raise RequestError(HTTPStatus.BAD_GATEWAY, "iStore 返回格式无效")
    items = []
    for app in apps[:200]:
        if not isinstance(app, dict):
            continue
        package = bounded_external_text(app.get("name"), 96)
        if not PACKAGE_RE.fullmatch(package):
            continue
        icon = bounded_external_text(app.get("icon"), 320)
        if icon.startswith("/"):
            icon = ISTORE_ICON_BASE + icon
        elif not icon.startswith("https://istore."):
            icon = ""
        items.append(
            {
                "id": package,
                "package": package,
                "name": bounded_external_text(app.get("title") or package, 120),
                "description": bounded_external_text(app.get("description"), 320),
                "version": bounded_external_text(app.get("version"), 64),
                "icon": icon,
                "installed": bool(app.get("installed")),
            }
        )
    return items


def clean_text(value, name: str, max_len: int, required: bool = False) -> str:
    if value is None:
        if required:
            raise RequestError(HTTPStatus.BAD_REQUEST, "%s is required" % name)
        return ""
    if not isinstance(value, str):
        raise RequestError(HTTPStatus.BAD_REQUEST, "%s must be a string" % name)
    value = value.strip()
    if required and not value:
        raise RequestError(HTTPStatus.BAD_REQUEST, "%s is required" % name)
    if len(value) > max_len:
        raise RequestError(HTTPStatus.BAD_REQUEST, "%s is too long" % name)
    return value


def clean_username(value) -> str:
    value = clean_text(value, "username", 64, True)
    if not USERNAME_RE.fullmatch(value):
        raise RequestError(HTTPStatus.BAD_REQUEST, "username must be 3-64 non-space characters")
    return value


def clean_password(value) -> str:
    if not isinstance(value, str) or not 8 <= len(value) <= 128:
        raise RequestError(HTTPStatus.BAD_REQUEST, "password must be 8-128 characters")
    if any(ord(char) < 32 or ord(char) == 127 for char in value):
        raise RequestError(HTTPStatus.BAD_REQUEST, "control characters are not allowed")
    return value


def clean_device_id(value) -> str:
    value = clean_text(value, "device_id", 80, True)
    if not DEVICE_ID_RE.fullmatch(value):
        raise RequestError(HTTPStatus.BAD_REQUEST, "invalid device_id")
    return value


def clean_mac(value, required: bool = False) -> str:
    value = clean_text(value, "mac", 17, required).lower()
    if value and not MAC_RE.fullmatch(value):
        raise RequestError(HTTPStatus.BAD_REQUEST, "invalid mac")
    return value


# 克隆设备标记：+xxN（xx=2位随机hex，N=发现的台数），追加在 serial/hardware_id 尾部
CLONE_SUFFIX_RE = re.compile(r"\+[0-9a-f]{2}[0-9]+\Z")


def strip_clone_suffix(text: str) -> str:
    """剥离克隆设备标记 +xxN，返回原始 S/N 或 hardware_id。"""
    return CLONE_SUFFIX_RE.sub("", text) if text else text


def clone_suffix(device_id: str, n: int) -> str:
    """克隆设备后缀：+<2位hex随机数><台数>。随机数由 device_id 派生，稳定不抖动
    （每次注册重新计算结果一致，避免 serial 反复变化）。"""
    return "+" + hashlib.sha256(device_id.encode("utf-8")).hexdigest()[:2] + str(n)


def _clone_members(conn, serial: str, mac: str):
    """返回 (S/N,MAC) 克隆组的全部成员：[(table, device_id, serial, hardware_id)]。"""
    base = strip_clone_suffix(serial)
    if not base or not mac:
        return []
    members = []
    for table in ("devices", "unbound_devices"):
        rows = conn.execute(
            "SELECT device_id, serial, hardware_id FROM %s WHERE mac=? AND (serial=? OR serial LIKE ?)" % table,
            (mac, base, base + "+%"),
        ).fetchall()
        for row in rows:
            if strip_clone_suffix(row["serial"] or "") == base:
                members.append((table, row["device_id"], row["serial"] or "", row["hardware_id"] or ""))
    return members


def is_clone_group(conn, serial: str, mac: str, device_id: str) -> bool:
    """克隆镜像（同 S/N+MAC）的其他设备是否"在线"（last_seen 近 5 分钟）。
    只拦截活跃克隆机：克隆机正在心跳（30s 一次）；单台设备重刷/重置后旧记录
    已离线（last_seen 陈旧），放行硬件指纹认领（重刷自动归还原账号）。"""
    base = strip_clone_suffix(serial)
    if not base or not mac:
        return False
    cutoff = now() - 300
    for table in ("devices", "unbound_devices"):
        row = conn.execute(
            "SELECT 1 FROM %s WHERE mac=? AND device_id!=? AND last_seen>=? AND (serial=? OR serial LIKE ?) LIMIT 1" % table,
            (mac, device_id, cutoff, base, base + "+%"),
        ).fetchone()
        if row:
            return True
    return False


def dedupe_clones(conn, device_id: str, serial: str, mac: str, hardware_id: str):
    """克隆镜像（同 S/N+MAC）设备统一追加 +xxN 标记（xx=随机数，N=发现的台数）。
    组内全部成员按 device_id 排序重新编号，幂等：重复注册不叠加、不抖动。
    同时给 hardware_id 追加相同后缀，避免克隆机凭相同指纹互认领。"""
    members = _clone_members(conn, serial, mac)
    if len(members) < 2:
        return
    base_serial = strip_clone_suffix(serial)
    base_hw = strip_clone_suffix(hardware_id) if hardware_id else ""
    members.sort(key=lambda m: m[1])
    for n, (table, dev_id, _, hw) in enumerate(members, 1):
        suffix = clone_suffix(dev_id, n)
        new_hw = (base_hw + suffix) if base_hw else hw
        conn.execute(
            "UPDATE %s SET serial=?, hardware_id=? WHERE device_id=?" % table,
            (base_serial + suffix, new_hw, dev_id),
        )


def clean_int(value, name: str, low: int, high: int) -> int:
    if isinstance(value, bool):
        raise RequestError(HTTPStatus.BAD_REQUEST, "%s must be an integer" % name)
    try:
        result = int(value)
    except (TypeError, ValueError):
        raise RequestError(HTTPStatus.BAD_REQUEST, "%s must be an integer" % name)
    if not low <= result <= high:
        raise RequestError(HTTPStatus.BAD_REQUEST, "%s is out of range" % name)
    return result


def clean_int_list(value, name: str, high: int = 99999):
    if not isinstance(value, list) or len(value) > 512:
        raise RequestError(HTTPStatus.BAD_REQUEST, "%s must be a short list" % name)
    return [clean_int(item, name, 0, high) for item in value]


def clean_url(value, name: str, max_len: int = 1800) -> str:
    value = clean_text(value, name, max_len, True)
    if not re.fullmatch(r"https?://[^\s<>\x00-\x1f\x7f]+", value, re.I):
        raise RequestError(HTTPStatus.BAD_REQUEST, "%s must be an http(s) URL" % name)
    return value


def clean_config(value, name: str, max_len: int = 16000) -> str:
    if not isinstance(value, str) or not value.strip():
        raise RequestError(HTTPStatus.BAD_REQUEST, "%s is required" % name)
    value = value.replace("\r\n", "\n")
    if len(value) > max_len or any((ord(char) < 32 and char not in "\n\t") or ord(char) == 127 for char in value):
        raise RequestError(HTTPStatus.BAD_REQUEST, "%s contains invalid content" % name)
    return value


def validate_command(kind, payload):
    """Return a normalized, shell-friendly payload for the allowlisted commands."""
    kind = clean_text(kind, "kind", 64, True)
    if not isinstance(payload, dict):
        raise RequestError(HTTPStatus.BAD_REQUEST, "payload must be an object")

    if kind in {"agent.refresh", "agent.update", "agent.issue_local_token"}:
        return {}

    if kind in {"mesh.pair", "mesh.unpair"}:
        return {"mac": clean_mac(payload.get("mac"), True)}
    if kind == "mesh.role":
        role = clean_text(payload.get("role"), "role", 32, True)
        if role not in {"cap", "unconfigured"}:
            raise RequestError(HTTPStatus.BAD_REQUEST, "子 AP 必须通过添加配对入网")
        return {"role": role}
    if kind == "mesh.apmode":
        return {"enabled": clean_int(payload.get("enabled"), "enabled", 0, 1)}
    if kind == "mesh.ssid_sync":
        return {}

    if kind == "oaf.set_apps":
        apps = clean_int_list(payload.get("app_list", payload.get("apps", [])), "app_list")
        return {"app_list_json": json_text(apps)}

    if kind == "oaf.set_base":
        return {
            "enable": clean_int(payload.get("enable", 1), "enable", 0, 1),
            "work_mode": clean_int(payload.get("work_mode", 0), "work_mode", 0, 2),
            "record_enable": clean_int(
                payload.get("record_enable", 1), "record_enable", 0, 1
            ),
            "disable_quic": clean_int(
                payload.get("disable_quic", 0), "disable_quic", 0, 1
            ),
            "app_filter_mode": clean_int(
                payload.get("app_filter_mode", 0), "app_filter_mode", 0, 2
            ),
        }

    if kind == "oaf.set_user_mode":
        return {"mode": clean_int(payload.get("mode", 0), "mode", 0, 2)}

    if kind == "oaf.add_users":
        macs = payload.get("mac_list", [])
        if not isinstance(macs, list) or len(macs) > 128:
            raise RequestError(HTTPStatus.BAD_REQUEST, "mac_list is too long")
        normalized = [clean_mac(item, True) for item in macs]
        return {"mac_list_json": json_text(normalized)}

    if kind == "oaf.del_user":
        return {"mac": clean_mac(payload.get("mac"), True)}

    if kind == "oaf.get_users":
        return {}

    if kind == "oaf.nickname":
        return {
            "mac": clean_mac(payload.get("mac"), True),
            "nickname": clean_text(payload.get("nickname"), "nickname", 64, True),
        }

    if kind == "oaf.set_time":
        mode = clean_int(payload.get("mode", 0), "mode", 0, 1)
        weekdays = clean_int_list(payload.get("weekday_list", [0, 1, 2, 3, 4, 5, 6]), "weekday_list", 6)
        start = clean_text(payload.get("start_time", "00:00"), "start_time", 5, True)
        end = clean_text(payload.get("end_time", "23:59"), "end_time", 5, True)
        if not TIME_RE.fullmatch(start) or not TIME_RE.fullmatch(end):
            raise RequestError(HTTPStatus.BAD_REQUEST, "invalid time")
        return {
            "data_json": json_text(
                {
                    "mode": mode,
                    "weekday_list": weekdays,
                    "start_time": start,
                    "end_time": end,
                    "allow_time": clean_int(payload.get("allow_time", 0), "allow_time", 0, 1440),
                    "deny_time": clean_int(payload.get("deny_time", 0), "deny_time", 0, 1440),
                }
            )
        }

    if kind == "wifi.set":
        ssid = clean_text(payload.get("ssid"), "ssid", 32, True)
        password = clean_text(payload.get("password"), "password", 63, True)
        if len(password) < 8:
            raise RequestError(HTTPStatus.BAD_REQUEST, "password must be 8-63 characters")
        if any(ord(char) < 32 or ord(char) == 127 for char in ssid + password):
            raise RequestError(HTTPStatus.BAD_REQUEST, "control characters are not allowed")
        return {"ssid": ssid, "password": password}

    if kind == "wifi.radio.set":
        values = {
            "radio": clean_int(payload.get("radio"), "radio", 0, 7),
            "channel": clean_int(payload.get("channel"), "channel", 0, 233),
            "txpower": clean_int(payload.get("txpower"), "txpower", 0, 40),
        }
        ssid = clean_text(payload.get("ssid"), "ssid", 32)
        password = clean_text(payload.get("password"), "password", 63)
        if ssid and any(ord(char) < 32 or ord(char) == 127 for char in ssid):
            raise RequestError(HTTPStatus.BAD_REQUEST, "control characters are not allowed")
        if password and (len(password) < 8 or any(ord(char) < 32 or ord(char) == 127 for char in password)):
            raise RequestError(HTTPStatus.BAD_REQUEST, "password must be 8-63 characters")
        values.update({"ssid": ssid, "password": password})
        encryption = clean_text(payload.get("encryption"), "encryption", 32)
        if encryption and encryption not in ("none", "psk", "psk2", "psk-mixed", "sae", "sae-mixed", "owe"):
            raise RequestError(HTTPStatus.BAD_REQUEST, "invalid encryption")
        values["encryption"] = encryption
        values["hidden"] = "1" if str(payload.get("hidden", "")) in ("1", "true", "True") else "0"
        return values

    if kind == "package.update":
        return {}

    if kind == "plugin.service.set":
        app = clean_text(payload.get("app"), "app", 32, True)
        if app not in PLUGIN_IDS:
            raise RequestError(HTTPStatus.BAD_REQUEST, "unsupported plugin")
        return {
            "app": app,
            "enabled": clean_int(payload.get("enabled", 0), "enabled", 0, 1),
            "running": clean_int(payload.get("running", 0), "running", 0, 1),
        }

    if kind == "plugin.config.set":
        app = clean_text(payload.get("app"), "app", 32, True)
        key = clean_text(payload.get("key"), "key", 64, True)
        if key not in PLUGIN_CONFIG_KEYS.get(app, set()):
            raise RequestError(HTTPStatus.BAD_REQUEST, "unsupported plugin option")
        index = clean_int(payload.get("index", 0), "index", 0, 31)
        if key in {"subscription_url"}:
            value = clean_url(payload.get("value"), "value")
        elif key == "config_file":
            value = clean_config(payload.get("value"), "value")
        elif key == "et_forward":
            raw = clean_text(payload.get("value"), "value", 128)
            allowed = {"etfwlan", "etfwwan", "lanfwet", "wanfwet"}
            values = raw.split()
            if any(item not in allowed for item in values):
                raise RequestError(HTTPStatus.BAD_REQUEST, "invalid EasyTier access control")
            value = " ".join(dict.fromkeys(values))
        elif key == "interface_netmask":
            value = clean_text(payload.get("value"), "value", 64, True)
            try:
                if ipaddress.ip_address(value).version != 4:
                    raise ValueError
            except ValueError:
                raise RequestError(HTTPStatus.BAD_REQUEST, "invalid interface netmask")
        elif key in {"auto_config_interface", "auto_config_firewall", "subscription_boot_update", "auto_update"}:
            value = str(clean_int(payload.get("value"), "value", 0, 1))
        else:
            value = clean_text(payload.get("value"), "value", 64, True)
            if key == "etcmd" and value not in {"config", "etcmd", "web"}:
                raise RequestError(HTTPStatus.BAD_REQUEST, "invalid EasyTier startup method")
            if any(ord(char) < 32 or ord(char) == 127 for char in value):
                raise RequestError(HTTPStatus.BAD_REQUEST, "control characters are not allowed")
        return {"app": app, "key": key, "index": index, "value": value}

    if kind == "plugin.download":
        app = clean_text(payload.get("app"), "app", 32, True)
        if app != "easytier":
            raise RequestError(HTTPStatus.BAD_REQUEST, "only EasyTier online download is supported")
        return {"app": app}

    if kind == "mesh.config.set":
        key = clean_text(payload.get("key"), "key", 32, True)
        value = payload.get("value")
        if key in {"enabled", "vtun_enable", "luci_enable"}:
            value = str(clean_int(value, "value", 0, 1))
        elif key == "auto_config":
            value = str(clean_int(value, "value", 0, 2))
        elif key == "mesh_gate_enable":
            value = str(clean_int(value, "value", 0, 2))
        elif key == "mesh_gate_encryption":
            value = str(clean_int(value, "value", 0, 4))
        elif key == "auto_mesh_band":
            value = clean_text(value, "value", 8, True)
            if value not in {"2g", "2g40", "5g", "6g", "60g"}:
                raise RequestError(HTTPStatus.BAD_REQUEST, "invalid mesh band")
        elif key == "auto_mesh_id":
            value = clean_text(value, "value", 32, True)
        elif key in {"auto_mesh_key", "mesh_gate_key"}:
            value = clean_text(value, "value", 63, False)
            if value and len(value) < 8:
                raise RequestError(HTTPStatus.BAD_REQUEST, "mesh key must be 8-63 characters")
            if any(ord(char) < 32 or ord(char) == 127 for char in value):
                raise RequestError(HTTPStatus.BAD_REQUEST, "invalid mesh key")
        else:
            raise RequestError(HTTPStatus.BAD_REQUEST, "unsupported mesh option")
        return {"key": key, "value": value}

    if kind == "plugin.subscription.add":
        app = clean_text(payload.get("app"), "app", 32, True)
        if app not in {"passwall", "openclash"}:
            raise RequestError(HTTPStatus.BAD_REQUEST, "unsupported plugin")
        url = clean_url(payload.get("url"), "url")
        remark = clean_text(payload.get("remark", payload.get("name", "")), "remark", 80)
        return {"app": app, "url": url, "remark": remark}

    if kind == "plugin.subscription.delete":
        app = clean_text(payload.get("app"), "app", 32, True)
        if app not in {"passwall", "openclash"}:
            raise RequestError(HTTPStatus.BAD_REQUEST, "unsupported plugin")
        return {"app": app, "index": clean_int(payload.get("index"), "index", 0, 127)}

    if kind == "plugin.subscription.update":
        app = clean_text(payload.get("app"), "app", 32, True)
        if app not in {"passwall", "openclash"}:
            raise RequestError(HTTPStatus.BAD_REQUEST, "unsupported plugin")
        return {"app": app, "index": clean_int(payload.get("index", -1), "index", -1, 127)}

    if kind == "package.search":
        query = clean_text(payload.get("query"), "query", 64, True)
        if not PACKAGE_QUERY_RE.fullmatch(query):
            raise RequestError(HTTPStatus.BAD_REQUEST, "invalid package query")
        return {"query": query}

    if kind == "terminal.exec":
        command = clean_text(payload.get("command"), "command", 256, True)
        if any(ord(char) < 32 or ord(char) == 127 for char in command) or any(char in command for char in ";&|><`$()"):
            raise RequestError(HTTPStatus.BAD_REQUEST, "terminal only accepts a single safe command")
        return {"command": command}

    if kind == "package.install":
        package = clean_text(payload.get("package"), "package", 96, True)
        if not PACKAGE_RE.fullmatch(package):
            raise RequestError(HTTPStatus.BAD_REQUEST, "invalid package name")
        return {"package": package}

    if kind == "istore.install":
        app = clean_text(payload.get("app"), "app", 96, True)
        if not PACKAGE_RE.fullmatch(app):
            raise RequestError(HTTPStatus.BAD_REQUEST, "invalid iStore app name")
        return {"app": app}

    if kind == "client.block":
        return {"mac": clean_mac(payload.get("mac"), True), "blocked": clean_int(payload.get("blocked", 1), "blocked", 0, 1)}

    if kind == "client.limit":
        fallback = payload.get("limit_kbps")
        down = clean_int(payload.get("down_kbps", fallback), "down_kbps", 0, 100000000)
        up = clean_int(payload.get("up_kbps", fallback), "up_kbps", 0, 100000000)
        return {"mac": clean_mac(payload.get("mac"), True), "down_kbps": down, "up_kbps": up}

    if kind == "client.wake":
        return {"mac": clean_mac(payload.get("mac"), True)}

    if kind == "system.reboot":
        return {}

    if kind == "system.hostname.set":
        hostname = clean_text(payload.get("hostname"), "hostname", 64, True)
        if len(hostname) < 2 or not HOSTNAME_RE.fullmatch(hostname):
            raise RequestError(HTTPStatus.BAD_REQUEST, "invalid hostname")
        return {"hostname": hostname}

    if kind == "network.lan.set":
        values = {}
        for key in ("ipaddr", "netmask", "gateway"):
            value = clean_text(payload.get(key), key, 64, key != "gateway")
            if value:
                try:
                    address = ipaddress.ip_address(value)
                except ValueError:
                    raise RequestError(HTTPStatus.BAD_REQUEST, "invalid %s" % key)
                if address.version != 4:
                    raise RequestError(HTTPStatus.BAD_REQUEST, "%s must be IPv4" % key)
            values[key] = value
        return values

    if kind == "network.firewall.set":
        allowed = {"ACCEPT", "DROP", "REJECT"}
        values = {}
        for key in ("input", "output", "forward"):
            value = clean_text(payload.get(key, "ACCEPT"), key, 16, True).upper()
            if value not in allowed:
                raise RequestError(HTTPStatus.BAD_REQUEST, "invalid firewall policy")
            values[key] = value
        return values

    if kind == "network.set_wan":
        raise RequestError(
            HTTPStatus.FORBIDDEN,
            "WAN changes are local-only and require a direct LAN connection to the router",
        )

    raise RequestError(HTTPStatus.BAD_REQUEST, "unsupported command")


# ── 采集回传：人工标注设备 + 未知 eMMC 的整理导出 ──
_OUI_DB = None

def oui_db():
    """加载 OUI 品牌库（与主题共用同一份 oui-vendors.json）"""
    global _OUI_DB
    if _OUI_DB is not None:
        return _OUI_DB
    _OUI_DB = {}
    try:
        with open(Path(__file__).resolve().parent / "oui-vendors.json", encoding="utf-8") as fh:
            data = json.load(fh)
        vendors = data.get("vendors") or []
        for prefix, idx in (data.get("prefixes") or {}).items():
            if isinstance(idx, int) and 0 <= idx < len(vendors) and vendors[idx]:
                _OUI_DB[str(prefix).upper()] = vendors[idx][0]
    except Exception:
        _OUI_DB = {}
    return _OUI_DB


def oui_lookup(mac) -> str:
    """MAC → 品牌 slug（用 9/7/6 位前缀，与主题一致）"""
    db_map = oui_db()
    hexd = "".join(c for c in str(mac or "").lower() if c in "0123456789abcdef")
    if len(hexd) < 6:
        return ""
    for size in (9, 7, 6):
        prefix = hexd[:size].upper()
        if prefix in db_map:
            return db_map[prefix]
    return ""


def build_collected_export():
    """按 R2 规则判定并输出回传 JSON（供开发机合并回主题识别库）。"""
    with db() as conn:
        labels = conn.execute("SELECT * FROM collected_labels ORDER BY updated_at DESC").fetchall()
        emmcs = conn.execute("SELECT * FROM collected_emmc ORDER BY updated_at DESC").fetchall()
    oui, unconfirmed, seen = [], [], set()
    for row in labels:
        brand = (row["brand"] or "").strip()
        devtype = (row["type"] or "").strip()
        prefix = (row["oui"] or "").strip().upper()
        official = oui_lookup(row["mac"])
        if official:
            if not brand or brand == official:
                status, final_brand = "confirmed", (brand or official)
            else:
                status, final_brand = "official_override", official
            if prefix and prefix not in seen:
                seen.add(prefix)
                oui.append({"prefix": prefix, "brand": final_brand, "type": devtype, "status": status})
        else:
            unconfirmed.append({
                "mac": row["mac"], "oui": prefix,
                "manual": {"brand": brand, "type": devtype, "name": row["name"] or ""},
                "auto": parse_json_text(row["auto"], {}),
                "reason": "no_official_record",
            })
    return {
        "generated": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "source": "gwrt-control",
        "oui": oui,
        "hostname": [],
        "unconfirmed": unconfirmed,
        "emmc_unknown": [
            {k: r[k] for k in ("cid", "manfid", "oemid", "product", "mdt", "manufacturer", "model")}
            for r in emmcs
        ],
    }


def init_db():
    with db() as conn:
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS users (
                id INTEGER PRIMARY KEY,
                username TEXT NOT NULL UNIQUE,
                password_hash TEXT NOT NULL,
                is_admin INTEGER NOT NULL DEFAULT 0,
                device_notifications INTEGER NOT NULL DEFAULT 1,
                created_at INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS sessions (
                token_hash TEXT PRIMARY KEY,
                user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                expires_at INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS app_login_codes (
                code_hash TEXT PRIMARY KEY,
                user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                expires_at INTEGER NOT NULL,
                used_at INTEGER,
                created_at INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS devices (
                id INTEGER PRIMARY KEY,
                device_id TEXT NOT NULL UNIQUE,
                owner_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                pair_token_hash TEXT NOT NULL,
                local_token_hash TEXT NOT NULL DEFAULT '',
                bound INTEGER NOT NULL DEFAULT 1,
                display_name TEXT NOT NULL DEFAULT '',
                serial TEXT NOT NULL DEFAULT '',
                mac TEXT NOT NULL DEFAULT '',
                model TEXT NOT NULL DEFAULT '',
                arch TEXT NOT NULL DEFAULT '',
                version TEXT NOT NULL DEFAULT '',
                firmware_version TEXT NOT NULL DEFAULT '',
                agent_version INTEGER NOT NULL DEFAULT 0,
                last_seen INTEGER NOT NULL DEFAULT 0,
                telemetry TEXT NOT NULL DEFAULT '{}',
                clients TEXT NOT NULL DEFAULT '[]',
                packages TEXT NOT NULL DEFAULT '{}',
                containers TEXT NOT NULL DEFAULT '{}',
                oaf TEXT NOT NULL DEFAULT '{}',
                topology TEXT NOT NULL DEFAULT '{}',
                mesh TEXT NOT NULL DEFAULT '{}',
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS device_notifications (
                device_id TEXT PRIMARY KEY,
                owner_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                enabled INTEGER NOT NULL DEFAULT 1,
                created_at INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS commands (
                id TEXT PRIMARY KEY,
                device_id TEXT NOT NULL REFERENCES devices(device_id) ON DELETE CASCADE,
                owner_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
                kind TEXT NOT NULL,
                payload TEXT NOT NULL,
                status TEXT NOT NULL DEFAULT 'queued',
                created_at INTEGER NOT NULL,
                delivered_at INTEGER,
                finished_at INTEGER,
                confirmed_at INTEGER,
                result TEXT
            );
            CREATE TABLE IF NOT EXISTS device_claims (
                device_id TEXT PRIMARY KEY,
                pair_token_hash TEXT NOT NULL,
                claim_token_hash TEXT NOT NULL,
                claim_expires_at INTEGER NOT NULL,
                serial TEXT NOT NULL DEFAULT '',
                mac TEXT NOT NULL DEFAULT '',
                model TEXT NOT NULL DEFAULT '',
                arch TEXT NOT NULL DEFAULT '',
                version TEXT NOT NULL DEFAULT '',
                firmware_version TEXT NOT NULL DEFAULT '',
                agent_version INTEGER NOT NULL DEFAULT 0,
                updated_at INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS commands_device_status
                ON commands(device_id, status, created_at);
            """
        )
        user_columns = {row[1] for row in conn.execute("PRAGMA table_info(users)")}
        if "is_admin" not in user_columns:
            conn.execute("ALTER TABLE users ADD COLUMN is_admin INTEGER NOT NULL DEFAULT 0")
        if "device_notifications" not in user_columns:
            conn.execute("ALTER TABLE users ADD COLUMN device_notifications INTEGER NOT NULL DEFAULT 1")
        device_columns = {row[1] for row in conn.execute("PRAGMA table_info(devices)")}
        if "local_token_hash" not in device_columns:
            conn.execute("ALTER TABLE devices ADD COLUMN local_token_hash TEXT NOT NULL DEFAULT ''")
        if "last_ip" not in device_columns:
            conn.execute("ALTER TABLE devices ADD COLUMN last_ip TEXT NOT NULL DEFAULT ''")
        if "region" not in device_columns:
            conn.execute("ALTER TABLE devices ADD COLUMN region TEXT NOT NULL DEFAULT ''")
        if "hardware_id" not in device_columns:
            conn.execute("ALTER TABLE devices ADD COLUMN hardware_id TEXT NOT NULL DEFAULT ''")
        if "bound" not in device_columns:
            conn.execute("ALTER TABLE devices ADD COLUMN bound INTEGER NOT NULL DEFAULT 1")
        if "display_name" not in device_columns:
            conn.execute("ALTER TABLE devices ADD COLUMN display_name TEXT NOT NULL DEFAULT ''")
        if "firmware_version" not in device_columns:
            conn.execute("ALTER TABLE devices ADD COLUMN firmware_version TEXT NOT NULL DEFAULT ''")
        if "agent_version" not in device_columns:
            conn.execute("ALTER TABLE devices ADD COLUMN agent_version INTEGER NOT NULL DEFAULT 0")
        if "topology" not in device_columns:
            conn.execute("ALTER TABLE devices ADD COLUMN topology TEXT NOT NULL DEFAULT '{}'")
        if "mesh" not in device_columns:
            conn.execute("ALTER TABLE devices ADD COLUMN mesh TEXT NOT NULL DEFAULT '{}'")

        claim_columns = {row[1] for row in conn.execute("PRAGMA table_info(device_claims)")}
        if "firmware_version" not in claim_columns:
            conn.execute("ALTER TABLE device_claims ADD COLUMN firmware_version TEXT NOT NULL DEFAULT ''")
        if "agent_version" not in claim_columns:
            conn.execute("ALTER TABLE device_claims ADD COLUMN agent_version INTEGER NOT NULL DEFAULT 0")
        if "hardware_id" not in claim_columns:
            conn.execute("ALTER TABLE device_claims ADD COLUMN hardware_id TEXT NOT NULL DEFAULT ''")
        command_columns = {row[1] for row in conn.execute("PRAGMA table_info(commands)")}
        if "confirmed_at" not in command_columns:
            conn.execute("ALTER TABLE commands ADD COLUMN confirmed_at INTEGER")
        conn.execute(
            """CREATE TABLE IF NOT EXISTS unbound_devices (
                id INTEGER PRIMARY KEY,
                device_id TEXT NOT NULL UNIQUE,
                pair_token_hash TEXT NOT NULL,
                serial TEXT NOT NULL DEFAULT '',
                mac TEXT NOT NULL DEFAULT '',
                model TEXT NOT NULL DEFAULT '',
                arch TEXT NOT NULL DEFAULT '',
                version TEXT NOT NULL DEFAULT '',
                firmware_version TEXT NOT NULL DEFAULT '',
                agent_version INTEGER NOT NULL DEFAULT 0,
                last_seen INTEGER NOT NULL DEFAULT 0,
                last_ip TEXT NOT NULL DEFAULT '',
                region TEXT NOT NULL DEFAULT '',
                hardware_id TEXT NOT NULL DEFAULT '',
                created_at INTEGER NOT NULL,
                updated_at INTEGER NOT NULL
            )"""
        )
        unbound_columns = {row[1] for row in conn.execute("PRAGMA table_info(unbound_devices)")}
        if "telemetry" not in unbound_columns:
            conn.execute("ALTER TABLE unbound_devices ADD COLUMN telemetry TEXT NOT NULL DEFAULT '{}'")
        if "hardware_id" not in unbound_columns:
            conn.execute("ALTER TABLE unbound_devices ADD COLUMN hardware_id TEXT NOT NULL DEFAULT ''")
        # 采集：人工标注的设备识别（只在 agent 上报 client_labels 时写入）
        conn.execute(
            """CREATE TABLE IF NOT EXISTS collected_labels (
                mac TEXT PRIMARY KEY,
                device_id TEXT NOT NULL DEFAULT '',
                oui TEXT NOT NULL DEFAULT '',
                brand TEXT NOT NULL DEFAULT '',
                type TEXT NOT NULL DEFAULT '',
                name TEXT NOT NULL DEFAULT '',
                auto TEXT NOT NULL DEFAULT '{}',
                ts INTEGER NOT NULL DEFAULT 0,
                updated_at INTEGER NOT NULL DEFAULT 0
            )"""
        )
        # 采集：未知 eMMC（只在 agent 上报 emmc_unknown 时写入）
        conn.execute(
            """CREATE TABLE IF NOT EXISTS collected_emmc (
                cid TEXT PRIMARY KEY,
                device_id TEXT NOT NULL DEFAULT '',
                manfid TEXT NOT NULL DEFAULT '',
                oemid TEXT NOT NULL DEFAULT '',
                product TEXT NOT NULL DEFAULT '',
                mdt TEXT NOT NULL DEFAULT '',
                manufacturer TEXT NOT NULL DEFAULT '',
                model TEXT NOT NULL DEFAULT '',
                ts INTEGER NOT NULL DEFAULT 0,
                updated_at INTEGER NOT NULL DEFAULT 0
            )"""
        )
        conn.execute(
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_devices_hardware ON devices(hardware_id) WHERE hardware_id != ''"
        )
        # 迁移旧 device_claims 中的无凭证注册行 → unbound_devices（未绑定设备目录）
        conn.execute(
            "INSERT OR IGNORE INTO unbound_devices(device_id,pair_token_hash,serial,mac,model,arch,version,firmware_version,agent_version,created_at,updated_at) "
            "SELECT device_id,pair_token_hash,serial,mac,model,arch,version,firmware_version,agent_version,updated_at,updated_at "
            "FROM device_claims WHERE claim_token_hash='' AND claim_expires_at=0"
        )
        conn.execute("DELETE FROM device_claims WHERE claim_token_hash='' AND claim_expires_at=0")
        admin_username = os.environ.get("GWRT_ADMIN_USER", "admin").strip() or "admin"
        conn.execute("DELETE FROM sessions WHERE expires_at<=?", (now(),))
        conn.execute("DELETE FROM device_claims WHERE claim_expires_at>0 AND claim_expires_at<?", (now(),))
        conn.execute("DELETE FROM app_login_codes WHERE expires_at<? OR used_at IS NOT NULL", (now(),))
        conn.execute("UPDATE users SET is_admin=1 WHERE username=?", (admin_username,))
        if conn.execute("SELECT 1 FROM users LIMIT 1").fetchone() is None:
            username = admin_username
            password = os.environ.get("GWRT_ADMIN_PASSWORD")
            if password == "change-this-before-start":
                raise RuntimeError("set GWRT_ADMIN_PASSWORD before starting the service")
            if not password:
                password = secrets.token_urlsafe(12)
                print("GWRT initial password: %s" % password, file=sys.stderr)
            conn.execute(
                "INSERT INTO users(username,password_hash,is_admin,created_at) VALUES(?,?,?,?)",
                (username, password_hash(password), 1, now()),
            )


def _client_labels_for(device_id: str) -> dict:
    """该设备的人工标注（终端名/品牌/类型），供 App 终端列表显示。"""
    out = {}
    if not device_id:
        return out
    with db() as conn:
        rows = conn.execute(
            "SELECT mac,brand,type,name FROM collected_labels WHERE device_id=?", (device_id,)
        ).fetchall()
    for row in rows:
        if row["brand"] or row["type"] or row["name"]:
            out[row["mac"]] = {"brand": row["brand"] or "", "type": row["type"] or "", "name": row["name"] or ""}
    return out


def device_json(row: sqlite3.Row, viewer_id: int | None = None):
    last_seen = int(row["last_seen"] or 0)
    agent_version = int(row["agent_version"] or 0)
    firmware_version = row["firmware_version"] or row["version"]
    update = agent_update_for(row["arch"], agent_version)
    return {
        "device_id": row["device_id"],
        "name": row["display_name"] or row["model"] or row["device_id"],
        "display_name": row["display_name"],
        "serial": row["serial"],
        "mac": row["mac"],
        "model": row["model"],
        "arch": row["arch"],
        "version": firmware_version,
        "firmware_version": firmware_version,
        "agent_version": agent_version,
        "agent_update": {"version": update["version"], "arch": update["arch"]} if update else None,
        "last_seen": last_seen,
        "online": bool(last_seen and now() - last_seen <= DEVICE_ONLINE_TTL),
        "bound": bool(row["bound"]) if "bound" in row.keys() else True,
        "owner_username": row["owner_username"] if "owner_username" in row.keys() else "",
        "can_manage": viewer_id is None or int(row["owner_id"]) == viewer_id,
        "last_ip": row["last_ip"] if "last_ip" in row.keys() else "",
        "region": row["region"] if "region" in row.keys() else "",
        "hardware_id": row["hardware_id"] if "hardware_id" in row.keys() else "",
        "notify_enabled": bool(_device_notify_enabled(row["device_id"], int(row["owner_id"]))),
        "local_control_ready": bool(row["local_token_hash"]),
        "telemetry": parse_json_text(row["telemetry"], {}),
        "clients": parse_json_text(row["clients"], []),
        "client_labels": _client_labels_for(row["device_id"]),
        "packages": parse_json_text(row["packages"], {}),
        "containers": parse_json_text(row["containers"], {}),
        "oaf": parse_json_text(row["oaf"], {}),
        "topology": parse_json_text(row["topology"], {}),
        "mesh": parse_json_text(row["mesh"], {}),
        "config_capabilities": [
            "wifi.set",
            "system.hostname.set",
            "system.reboot",
            "network.lan.set",
            "network.firewall.set",
            "wifi.radio.set",
            "plugin.service.set",
            "plugin.config.set",
            "plugin.download",
            "plugin.subscription.add",
            "mesh.config.set",
            "mesh.pair", "mesh.unpair", "mesh.role", "mesh.apmode", "mesh.ssid_sync",
            "plugin.subscription.delete",
            "plugin.subscription.update",
            "package.install",
            "istore.install",
            "package.search",
            "client.block",
            "client.limit",
            "client.wake",
            "terminal.exec",
            "oaf.*",
        ],
        "wan_config": "direct_lan_only",
    }


def dedupe_by_hardware(rows):
    """同一硬件指纹的多条记录只保留最新一条（rows 已按 updated_at DESC 排序）。"""
    seen = set()
    result = []
    for row in rows:
        hw = row["hardware_id"] or ""
        if hw:
            if hw in seen:
                continue
            seen.add(hw)
        result.append(row)
    return result


def unbound_device_json(row: sqlite3.Row):
    """未绑定设备的目录视图：只有 admin 可见，仅状态、不可管理。"""
    last_seen = int(row["last_seen"] or 0)
    firmware_version = row["firmware_version"] or row["version"]
    return {
        "device_id": row["device_id"],
        "name": row["model"] or row["device_id"],
        "display_name": "",
        "serial": row["serial"],
        "mac": row["mac"],
        "model": row["model"],
        "arch": row["arch"],
        "version": firmware_version,
        "firmware_version": firmware_version,
        "agent_version": int(row["agent_version"] or 0),
        "agent_update": None,
        "last_seen": last_seen,
        "online": bool(last_seen and now() - last_seen <= DEVICE_ONLINE_TTL),
        "bound": False,
        "owner_username": "",
        "can_manage": False,
        "last_ip": row["last_ip"] or "",
        "region": row["region"] or "",
        "hardware_id": row["hardware_id"] if "hardware_id" in row.keys() else "",
        "notify_enabled": False,
        "local_control_ready": False,
        "telemetry": parse_json_text(row["telemetry"], {}),
        "clients": [],
        "packages": {},
        "containers": {},
        "oaf": {},
        "topology": {},
        "mesh": {},
        "config_capabilities": [],
        "wan_config": "direct_lan_only",
    }


class Handler(BaseHTTPRequestHandler):
    server_version = "GWRTControl/" + VERSION

    def setup(self):
        super().setup()
        self.connection.settimeout(15)

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def send_json(self, value, status=HTTPStatus.OK, extra=None):
        body = json_text(value).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_security_headers()
        if extra:
            for key, val in extra.items():
                self.send_header(key, val)
        self.end_headers()
        self.wfile.write(body)

    def send_security_headers(self):
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' https://istore.istoreos.com https://istore.linkease.com.cdn.koolcenter.com data:; "
            "font-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'",
        )

    def fail(self, error: RequestError):
        self.send_json({"ok": False, "error": error.message}, error.status)

    def read_json(self):
        if "Content-Length" not in self.headers:
            raise RequestError(HTTPStatus.LENGTH_REQUIRED, "content length is required")
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            raise RequestError(HTTPStatus.BAD_REQUEST, "invalid content length")
        if length < 0 or length > MAX_BODY:
            raise RequestError(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, "request too large")
        raw = self.rfile.read(length)
        try:
            value = json.loads(raw.decode("utf-8") or "{}")
        except (UnicodeDecodeError, ValueError):
            raise RequestError(HTTPStatus.BAD_REQUEST, "invalid JSON")
        if not isinstance(value, dict):
            raise RequestError(HTTPStatus.BAD_REQUEST, "JSON object required")
        return value

    def session(self):
        cookie = SimpleCookie()
        cookie.load(self.headers.get("Cookie", ""))
        item = cookie.get("gwrt_session")
        if not item:
            raise RequestError(HTTPStatus.UNAUTHORIZED, "login required")
        token = item.value
        with db() as conn:
            row = conn.execute(
                "SELECT s.*, u.username, u.is_admin, u.device_notifications FROM sessions s JOIN users u ON u.id=s.user_id "
                "WHERE s.token_hash=? AND s.expires_at>?",
                (hash_token(token), now()),
            ).fetchone()
        if row is None:
            raise RequestError(HTTPStatus.UNAUTHORIZED, "session expired")
        return row, token

    def require_csrf(self, session_row, token):
        supplied = self.headers.get("X-GWRT-CSRF", "")
        if not hmac.compare_digest(supplied, csrf_token(token)):
            raise RequestError(HTTPStatus.FORBIDDEN, "invalid csrf token")

    def agent_token(self):
        token = self.headers.get("X-GWRT-Token", "")
        if not token:
            auth = self.headers.get("Authorization", "")
            if auth.lower().startswith("bearer "):
                token = auth[7:].strip()
        if not token:
            raise RequestError(HTTPStatus.UNAUTHORIZED, "agent token required")
        return clean_text(token, "agent_token", 256, True)

    def agent_device(self, payload, allow_unbound=False):
        device_id = clean_device_id(payload.get("device_id"))
        token = self.agent_token()
        with db() as conn:
            row = conn.execute(
                "SELECT * FROM devices WHERE device_id=? AND pair_token_hash=?",
                (device_id, hash_token(token)),
            ).fetchone()
        if row is None or (not allow_unbound and not row["bound"]):
            raise RequestError(HTTPStatus.UNAUTHORIZED, "unknown device or token")
        return row

    def agent_identity(self, payload):
        """设备身份：已绑定设备在 devices，未绑定注册设备在 unbound_devices。
        返回 (row, bound)。pair_token 均校验。"""
        device_id = clean_device_id(payload.get("device_id"))
        token = self.agent_token()
        token_hash = hash_token(token)
        with db() as conn:
            row = conn.execute(
                "SELECT * FROM devices WHERE device_id=? AND pair_token_hash=? AND bound=1",
                (device_id, token_hash),
            ).fetchone()
            if row is not None:
                return row, True
            row = conn.execute(
                "SELECT * FROM unbound_devices WHERE device_id=? AND pair_token_hash=?",
                (device_id, token_hash),
            ).fetchone()
        if row is None:
            raise RequestError(HTTPStatus.UNAUTHORIZED, "unknown device or token")
        return row, False

    def get_device(self, owner_id, device_id, is_admin=False):
        with db() as conn:
            row = conn.execute(
                "SELECT * FROM devices WHERE device_id=? AND bound=1" if is_admin else "SELECT * FROM devices WHERE owner_id=? AND device_id=? AND bound=1",
                (device_id,) if is_admin else (owner_id, device_id),
            ).fetchone()
        if row is None:
            raise RequestError(HTTPStatus.NOT_FOUND, "device not found")
        return row

    def do_GET(self):
        try:
            path = urlparse(self.path).path
            if path == "/api/healthz":
                self.send_json({"ok": True, "service": "gwrt-control", "version": VERSION, "build_time": BUILD_TIME})
                return
            if path == "/api/agent/update":
                params = parse_qs(urlparse(self.path).query)
                row, _ = self.agent_identity({"device_id": params.get("device_id", [""])[0]})
                current_version = clean_int(params.get("agent_version", [0])[0], "agent_version", 0, 999999)
                arch = clean_text(params.get("arch", [row["arch"]])[0], "arch", 64) or row["arch"]
                self.send_json({
                    "ok": True,
                    "current_agent_version": current_version,
                    "firmware_version": row["firmware_version"] or row["version"],
                    "update": agent_update_for(arch, current_version),
                })
                return
            if path == "/api/agent/ping":
                params = parse_qs(urlparse(self.path).query)
                ping_payload = {"device_id": params.get("device_id", [""])[0]}
                row = self.agent_identity(ping_payload)[0]
                agent_version = clean_int(params.get("agent_version", [0])[0], "agent_version", 0, 999999)
                timestamp = now()
                with db() as conn:
                    conn.execute(
                        "UPDATE devices SET agent_version=?,last_seen=?,updated_at=? WHERE device_id=?",
                        (agent_version, timestamp, timestamp, row["device_id"]),
                    )
                self.send_json({"ok": True, "server_time": timestamp, "report_interval": report_interval_for_agent()})
                return
            if path == "/api/agent/safe":
                params = parse_qs(urlparse(self.path).query)
                row = self.agent_device({"device_id": params.get("device_id", [""])[0]})
                command_id = clean_text(params.get("command_id", [""])[0], "command_id", 128, True)
                with db() as conn:
                    command = conn.execute(
                        "SELECT status,confirmed_at FROM commands WHERE id=? AND device_id=?",
                        (command_id, row["device_id"]),
                    ).fetchone()
                self.send_json({"ok": True, "confirmed": bool(command and command["status"] == "success" and command["confirmed_at"])})
                return
            if path == "/api/auth/captcha":
                remote_addr = self.client_address[0] if self.client_address else "unknown"
                rate_limit("captcha-ip", remote_addr, 30, 60)
                captcha_id, code, svg = captcha_new()
                self.send_json({"ok": True, "id": captcha_id, "svg": svg})
                return
            if path == "/api/me":
                session_row, token = self.session()
                self.send_json(
                    {
                        "ok": True,
                        "user": {"id": session_row["user_id"], "username": session_row["username"], "is_admin": bool(session_row["is_admin"])},
                        "csrf": csrf_token(token),
                    }
                )
                return
            if path == "/api/settings":
                session_row, _ = self.session()
                self.send_json({"ok": True, "settings": {"device_notifications": bool(session_row["device_notifications"])}})
                return
            if path == "/api/admin/collected/export":
                session_row, _ = self.session()
                if not session_row["is_admin"]:
                    raise RequestError(HTTPStatus.FORBIDDEN, "admin only")
                self.send_json(build_collected_export())
                return
            if path == "/api/weather":
                session_row, _ = self.session()
                params = parse_qs(urlparse(self.path).query)
                weather_ip = client_ip(self)
                device_id = params.get("device_id", [""])[0]
                if device_id:
                    device_id = clean_device_id(device_id)
                    row = self.get_device(session_row["user_id"], device_id, bool(session_row["is_admin"]))
                    public_ip = (parse_json_text(row["telemetry"], {}).get("public_ip") or "").strip()
                    if public_ip:
                        weather_ip = public_ip
                self.send_json(fetch_weather(weather_ip))
                return
            if path == "/api/devices":
                session_row, _ = self.session()
                mark_active()
                is_admin = bool(session_row["is_admin"])
                viewer_id = int(session_row["user_id"])
                with db() as conn:
                    if is_admin:
                        # 管理员：全站设备（含其他账号绑定的）+ 未绑定注册设备，按地域排列
                        rows = conn.execute(
                            "SELECT d.*, u.username AS owner_username FROM devices d LEFT JOIN users u ON u.id=d.owner_id "
                            "WHERE d.bound=1 ORDER BY d.region ASC, d.updated_at DESC"
                        ).fetchall()
                        unbound = conn.execute(
                            "SELECT * FROM unbound_devices ORDER BY region ASC, updated_at DESC"
                        ).fetchall()
                        devices = [device_json(row, viewer_id) for row in dedupe_by_hardware(rows)] + [unbound_device_json(row) for row in dedupe_by_hardware(unbound)]
                    else:
                        rows = conn.execute(
                            "SELECT d.*, u.username AS owner_username FROM devices d LEFT JOIN users u ON u.id=d.owner_id "
                            "WHERE d.bound=1 AND d.owner_id=? ORDER BY d.updated_at DESC",
                            (viewer_id,),
                        ).fetchall()
                        devices = [device_json(row, viewer_id) for row in rows]
                self.send_json({"ok": True, "devices": devices, "admin": is_admin})
                return
            if path == "/api/istore":
                session_row, _ = self.session()
                params = parse_qs(urlparse(self.path).query)
                device_id = clean_device_id(params.get("device_id", [""])[0])
                row = self.get_device(session_row["user_id"], device_id, bool(session_row["is_admin"]))
                self.send_json({"ok": True, "items": fetch_istore_apps(row), "source": "iStore"})
                return
            if path.startswith("/api/commands/"):
                session_row, _ = self.session()
                command_id = clean_text(unquote(path.rsplit("/", 1)[-1]), "command_id", 128, True)
                with db() as conn:
                    row = conn.execute(
                        "SELECT * FROM commands WHERE id=? AND owner_id=?",
                        (command_id, session_row["user_id"]),
                    ).fetchone()
                if row is None:
                    raise RequestError(HTTPStatus.NOT_FOUND, "command not found")
                self.send_json({"ok": True, "command": {"id": row["id"], "kind": row["kind"], "status": row["status"], "result": parse_json_text(row["result"], None), "created_at": row["created_at"], "finished_at": row["finished_at"]}})
                return
            if path.startswith("/api/devices/") and path.endswith("/notify"):
                session_row, _ = self.session()
                device_id = clean_device_id(unquote(path.split("/")[3]))
                self.get_device(session_row["user_id"], device_id, bool(session_row["is_admin"]))
                self.send_json({"ok": True, "enabled": _device_notify_enabled(device_id, int(session_row["user_id"]))})
                return
            if path.startswith("/api/devices/"):
                session_row, _ = self.session()
                device_id = clean_device_id(unquote(path.rsplit("/", 1)[-1]))
                row = self.get_device(session_row["user_id"], device_id, bool(session_row["is_admin"]))
                self.send_json({"ok": True, "device": device_json(row)})
                return
            self.serve_static(path)
        except RequestError as error:
            self.fail(error)
        except Exception:
            traceback.print_exc()
            self.fail(RequestError(HTTPStatus.INTERNAL_SERVER_ERROR, "internal server error"))

    def do_POST(self):
        try:
            path = urlparse(self.path).path
            payload = self.read_json()
            if path == "/api/auth/login":
                self.login(payload)
                return
            if path == "/api/auth/register":
                self.register(payload)
                return
            if path == "/api/auth/app-login":
                self.app_login(payload)
                return
            if path == "/api/agent/heartbeat":
                self.agent_heartbeat(payload)
                return
            if path == "/api/agent/report":
                self.agent_report(payload)
                return
            if path == "/api/agent/register":
                self.agent_register(payload)
                return
            if path == "/api/agent/pull":
                self.agent_pull(payload)
                return
            if path == "/api/agent/ack":
                self.agent_ack(payload)
                return

            session_row, session_token = self.session()
            self.require_csrf(session_row, session_token)
            if path == "/api/auth/logout":
                with db() as conn:
                    conn.execute("DELETE FROM sessions WHERE token_hash=?", (hash_token(session_token),))
                self.send_json({"ok": True})
                return
            if path == "/api/settings/notifications":
                enabled = clean_int(payload.get("enabled"), "enabled", 0, 1)
                with db() as conn:
                    conn.execute("UPDATE users SET device_notifications=? WHERE id=?", (enabled, session_row["user_id"]))
                self.send_json({"ok": True, "settings": {"device_notifications": bool(enabled)}})
                return
            if path == "/api/auth/app-code":
                self.issue_app_login_code(session_row)
                return
            if path == "/api/auth/password":
                self.change_password(session_row, payload)
                return
            if path == "/api/devices/claim":
                remote_addr = self.client_address[0] if self.client_address else "unknown"
                rate_limit("claim-user", str(session_row["user_id"]), 6, 300)
                rate_limit("claim-ip", remote_addr, 12, 300)
                self.claim_device(session_row["user_id"], payload)
                return
            if path.startswith("/api/devices/") and path.endswith("/notify"):
                device_id = clean_device_id(path.split("/")[3])
                self.set_device_notify(session_row["user_id"], device_id, payload)
                return
            if path.startswith("/api/devices/") and path.endswith("/client-label"):
                device_id = clean_device_id(path.split("/")[3])
                self.save_client_label(session_row["user_id"], device_id, payload)
                return
            if path.startswith("/api/devices/") and path.endswith("/rename"):
                device_id = clean_device_id(path.split("/")[3])
                self.rename_device(session_row["user_id"], device_id, payload)
                return
            if path.startswith("/api/devices/") and path.endswith("/unbind"):
                device_id = clean_device_id(path.split("/")[3])
                self.unbind_device(session_row["user_id"], device_id)
                return
            if path.startswith("/api/devices/") and path.endswith("/commands"):
                device_id = clean_device_id(path.split("/")[3])
                self.create_command(session_row["user_id"], device_id, payload)
                return
            if path.startswith("/api/commands/") and path.endswith("/confirm"):
                command_id = clean_text(unquote(path.split("/")[3]), "command_id", 128, True)
                self.confirm_command(session_row["user_id"], command_id)
                return
            raise RequestError(HTTPStatus.NOT_FOUND, "route not found")
        except RequestError as error:
            self.fail(error)
        except Exception:
            traceback.print_exc()
            self.fail(RequestError(HTTPStatus.INTERNAL_SERVER_ERROR, "internal server error"))

    @staticmethod
    def queue_internal_command(conn, device_id, owner_id, kind, payload=None):
        row = conn.execute(
            "SELECT id FROM commands WHERE device_id=? AND kind=? AND status IN ('queued','delivered') LIMIT 1",
            (device_id, kind),
        ).fetchone()
        if row:
            return row["id"]
        command_id = secrets.token_urlsafe(16)
        conn.execute(
            "INSERT INTO commands(id,device_id,owner_id,kind,payload,created_at) VALUES(?,?,?,?,?,?)",
            (command_id, device_id, owner_id, kind, json_text(payload or {}), now()),
        )
        return command_id

    def agent_register(self, payload):
        token = self.agent_token()
        device_id = clean_device_id(payload.get("device_id"))
        claim_token = clean_text(payload.get("claim_token"), "claim_token", 256)
        hardware_id = clean_text(payload.get("hardware_id"), "hardware_id", 80)
        serial = clean_text(payload.get("serial"), "serial", 128)
        mac = clean_mac(payload.get("mac"))
        model = clean_text(payload.get("model"), "model", 128)
        arch = clean_text(payload.get("arch"), "arch", 64)
        version = clean_text(payload.get("version"), "version", 128)
        firmware_version = clean_text(payload.get("firmware_version", version), "firmware_version", 128) or version
        agent_version = clean_int(payload.get("agent_version", 0), "agent_version", 0, 999999)
        token_hash = hash_token(token)
        timestamp = now()
        with db() as conn:
            existing = conn.execute("SELECT * FROM devices WHERE device_id=?", (device_id,)).fetchone()
            existing_unbound = None
            # 硬件指纹认领：同一硬件重刷固件后 device_id/pair_token 变化，凭 hardware_id 自动归还原账号，无需重新绑定。
            # 带 claim_token 的注册不走认领（首次绑定走 claim 流程，防抢在 claim 层校验）
            if existing is None and hardware_id and not claim_token:
                claimed = conn.execute(
                    "SELECT * FROM devices WHERE hardware_id=? AND bound=1 AND device_id!=?",
                    (hardware_id, device_id),
                ).fetchone()
                # 克隆镜像（同 S/N+MAC 的多台机器，hardware_id 相同）禁止互认领，
                # 否则后注册的会把先注册的记录抢走；由 dedupe_clones 打 +xxN 标记区分。
                if claimed and is_clone_group(conn, serial, mac, device_id):
                    claimed = None
                if claimed:
                    old_id = claimed["device_id"]
                    if conn.execute("SELECT 1 FROM devices WHERE device_id=? AND device_id!=?", (device_id, old_id)).fetchone():
                        raise RequestError(HTTPStatus.CONFLICT, "device_id already exists")
                    # 子表与主表互相引用（ON UPDATE NO ACTION），延迟到事务提交时统一校验外键
                    conn.execute("PRAGMA defer_foreign_keys=ON")
                    # 先迁移子表再更新主行
                    conn.execute("DELETE FROM unbound_devices WHERE device_id=?", (device_id,))
                    conn.execute("UPDATE unbound_devices SET device_id=? WHERE device_id=?", (device_id, old_id))
                    conn.execute("UPDATE commands SET device_id=? WHERE device_id=?", (device_id, old_id))
                    conn.execute("UPDATE device_notifications SET device_id=? WHERE device_id=?", (device_id, old_id))
                    conn.execute("DELETE FROM device_claims WHERE device_id=?", (old_id,))
                    conn.execute(
                        "UPDATE devices SET device_id=?,pair_token_hash=?,local_token_hash='',serial=?,mac=?,model=?,arch=?,version=?,firmware_version=?,agent_version=?,hardware_id=?,updated_at=? WHERE device_id=?",
                        (device_id, token_hash, serial, mac, model, arch, version, firmware_version, agent_version, hardware_id, timestamp, old_id),
                    )
                    existing = conn.execute("SELECT * FROM devices WHERE device_id=?", (device_id,)).fetchone()
                else:
                    claimed_unbound = conn.execute(
                        "SELECT * FROM unbound_devices WHERE hardware_id=? AND device_id!=? ORDER BY updated_at DESC LIMIT 1",
                        (hardware_id, device_id),
                    ).fetchone()
                    if claimed_unbound and is_clone_group(conn, serial, mac, device_id):
                        claimed_unbound = None
                    if claimed_unbound:
                        old_id = claimed_unbound["device_id"]
                        conn.execute("DELETE FROM unbound_devices WHERE device_id=?", (device_id,))
                        conn.execute(
                            "UPDATE unbound_devices SET device_id=?,pair_token_hash=?,hardware_id=? WHERE device_id=?",
                            (device_id, token_hash, hardware_id, old_id),
                        )
                        existing_unbound = conn.execute("SELECT * FROM unbound_devices WHERE device_id=?", (device_id,)).fetchone()
            if existing and existing["pair_token_hash"] != token_hash:
                raise RequestError(HTTPStatus.UNAUTHORIZED, "device token does not match")
            if existing:
                if claim_token:
                    conn.execute(
                        "INSERT INTO device_claims(device_id,pair_token_hash,claim_token_hash,claim_expires_at,serial,mac,model,arch,version,firmware_version,agent_version,hardware_id,updated_at) "
                        "VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(device_id) DO UPDATE SET pair_token_hash=excluded.pair_token_hash,claim_token_hash=excluded.claim_token_hash,claim_expires_at=excluded.claim_expires_at,serial=excluded.serial,mac=excluded.mac,model=excluded.model,arch=excluded.arch,version=excluded.version,firmware_version=excluded.firmware_version,agent_version=excluded.agent_version,hardware_id=excluded.hardware_id,updated_at=excluded.updated_at",
                        (device_id, token_hash, hash_token(claim_token), timestamp + CLAIM_TTL, serial, mac, model, arch, version, firmware_version, agent_version, hardware_id, timestamp),
                    )
                conn.execute(
                    "UPDATE devices SET serial=?,mac=?,model=?,arch=?,version=?,firmware_version=?,agent_version=?,hardware_id=?,updated_at=? WHERE device_id=?",
                    (serial, mac, model, arch, version, firmware_version, agent_version, hardware_id or existing["hardware_id"], timestamp, device_id),
                )
                local_command_id = None
                if existing["bound"] and not existing["local_token_hash"]:
                    local_command_id = self.queue_internal_command(conn, device_id, existing["owner_id"], "agent.issue_local_token")
                bound = bool(existing["bound"])
            else:
                if existing_unbound is None:
                    existing_unbound = conn.execute("SELECT * FROM unbound_devices WHERE device_id=?", (device_id,)).fetchone()
                if existing_unbound and existing_unbound["pair_token_hash"] != token_hash:
                    raise RequestError(HTTPStatus.UNAUTHORIZED, "device token does not match")
                claim = conn.execute("SELECT * FROM device_claims WHERE device_id=?", (device_id,)).fetchone()
                if claim and claim["pair_token_hash"] != token_hash:
                    raise RequestError(HTTPStatus.CONFLICT, "device identity is already pending")
                if claim_token:
                    conn.execute(
                        "INSERT INTO device_claims(device_id,pair_token_hash,claim_token_hash,claim_expires_at,serial,mac,model,arch,version,firmware_version,agent_version,hardware_id,updated_at) "
                        "VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(device_id) DO UPDATE SET pair_token_hash=excluded.pair_token_hash,claim_token_hash=excluded.claim_token_hash,claim_expires_at=excluded.claim_expires_at,serial=excluded.serial,mac=excluded.mac,model=excluded.model,arch=excluded.arch,version=excluded.version,firmware_version=excluded.firmware_version,agent_version=excluded.agent_version,hardware_id=excluded.hardware_id,updated_at=excluded.updated_at",
                        (device_id, token_hash, hash_token(claim_token), timestamp + CLAIM_TTL, serial, mac, model, arch, version, firmware_version, agent_version, hardware_id, timestamp),
                    )
                elif not claim:
                    conn.execute(
                        "INSERT INTO device_claims(device_id,pair_token_hash,claim_token_hash,claim_expires_at,serial,mac,model,arch,version,firmware_version,agent_version,hardware_id,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",
                        (device_id, token_hash, "", 0, serial, mac, model, arch, version, firmware_version, agent_version, hardware_id, timestamp),
                    )
                # 未绑定设备进入目录：admin 全站可见（仅状态，绑定后移入 devices）
                if existing_unbound:
                    conn.execute(
                        "UPDATE unbound_devices SET serial=?,mac=?,model=?,arch=?,version=?,firmware_version=?,agent_version=?,hardware_id=?,updated_at=? WHERE device_id=?",
                        (serial, mac, model, arch, version, firmware_version, agent_version, hardware_id, timestamp, device_id),
                    )
                else:
                    conn.execute(
                        "INSERT INTO unbound_devices(device_id,pair_token_hash,serial,mac,model,arch,version,firmware_version,agent_version,hardware_id,created_at,updated_at) "
                        "VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
                        (device_id, token_hash, serial, mac, model, arch, version, firmware_version, agent_version, hardware_id, timestamp, timestamp),
                    )
                bound = False
                local_command_id = None
        # 克隆镜像去重：同 S/N+MAC 的设备按发现台数统一追加 +xxN 标记（幂等）
        dedupe_clones(conn, device_id, serial, mac, hardware_id)
        self.send_json({"ok": True, "registered": True, "bound": bound, "local_token_command_id": local_command_id})

    def finish_login(self, user):
        raw_token = secrets.token_urlsafe(32)
        with db() as conn:
            conn.execute(
                "INSERT INTO sessions(token_hash,user_id,expires_at) VALUES(?,?,?)",
                (hash_token(raw_token), user["id"], now() + SESSION_TTL),
            )
        cookie = "gwrt_session=%s; Path=/; HttpOnly; SameSite=Lax" % raw_token
        if os.environ.get("GWRT_COOKIE_SECURE", "0") == "1":
            cookie += "; Secure"
        self.send_json(
            {"ok": True, "user": {"id": user["id"], "username": user["username"], "is_admin": bool(user["is_admin"])}, "csrf": csrf_token(raw_token)},
            extra={"Set-Cookie": cookie},
        )

    def login(self, payload):
        username = clean_username(payload.get("username"))
        password = payload.get("password")
        if not isinstance(password, str) or not password:
            raise RequestError(HTTPStatus.BAD_REQUEST, "password is required")
        if not captcha_consume(
            clean_text(payload.get("captcha_id"), "captcha_id", 64, True),
            clean_text(payload.get("captcha"), "captcha", 8, True),
        ):
            raise RequestError(HTTPStatus.BAD_REQUEST, "验证码错误，请重试")
        remote_addr = self.client_address[0] if self.client_address else "unknown"
        rate_limit("login-ip", remote_addr, 12, 60)
        rate_limit("login-user", username.lower(), 8, 60)
        with db() as conn:
            user = conn.execute("SELECT * FROM users WHERE username=?", (username,)).fetchone()
            if user is None or not password_matches(password, user["password_hash"]):
                raise RequestError(HTTPStatus.UNAUTHORIZED, "invalid credentials")
        self.finish_login(user)

    def app_login(self, payload):
        code = clean_app_login_code(payload.get("code"))
        remote_addr = self.client_address[0] if self.client_address else "unknown"
        rate_limit("app-login-ip", remote_addr, 12, 60)
        timestamp = now()
        with db() as conn:
            row = conn.execute(
                "SELECT user_id FROM app_login_codes WHERE code_hash=? AND expires_at>=? AND used_at IS NULL",
                (hash_token(code), timestamp),
            ).fetchone()
            if row is None:
                raise RequestError(HTTPStatus.UNAUTHORIZED, "动态登录码无效或已过期")
            consumed = conn.execute(
                "UPDATE app_login_codes SET used_at=? WHERE code_hash=? AND expires_at>=? AND used_at IS NULL",
                (timestamp, hash_token(code), timestamp),
            ).rowcount
            if not consumed:
                raise RequestError(HTTPStatus.UNAUTHORIZED, "动态登录码无效或已使用")
            user = conn.execute("SELECT * FROM users WHERE id=?", (row["user_id"],)).fetchone()
        if user is None:
            raise RequestError(HTTPStatus.UNAUTHORIZED, "账户不存在")
        self.finish_login(user)

    def change_password(self, session_row, payload):
        old_password = payload.get("old_password")
        new_password = clean_password(payload.get("new_password"))
        if not isinstance(old_password, str) or not old_password:
            raise RequestError(HTTPStatus.BAD_REQUEST, "old password is required")
        with db() as conn:
            user = conn.execute("SELECT * FROM users WHERE id=?", (session_row["user_id"],)).fetchone()
            if user is None or not password_matches(old_password, user["password_hash"]):
                raise RequestError(HTTPStatus.UNAUTHORIZED, "原密码错误")
            conn.execute("UPDATE users SET password_hash=? WHERE id=?", (password_hash(new_password), session_row["user_id"]))
        self.send_json({"ok": True})

    def issue_app_login_code(self, session_row):
        rate_limit("app-code-user", str(session_row["user_id"]), 4, 300)
        code = app_login_code()
        timestamp = now()
        with db() as conn:
            conn.execute("DELETE FROM app_login_codes WHERE user_id=? OR expires_at<?", (session_row["user_id"], timestamp))
            conn.execute(
                "INSERT INTO app_login_codes(code_hash,user_id,expires_at,created_at) VALUES(?,?,?,?)",
                (hash_token(code), session_row["user_id"], timestamp + APP_LOGIN_CODE_TTL, timestamp),
            )
        self.send_json({"ok": True, "code": code, "expires_in": APP_LOGIN_CODE_TTL})

    def register(self, payload):
        username = clean_username(payload.get("username"))
        password = clean_password(payload.get("password"))
        if not captcha_consume(
            clean_text(payload.get("captcha_id"), "captcha_id", 64, True),
            clean_text(payload.get("captcha"), "captcha", 8, True),
        ):
            raise RequestError(HTTPStatus.BAD_REQUEST, "验证码错误，请重试")
        remote_addr = self.client_address[0] if self.client_address else "unknown"
        rate_limit("register-ip", remote_addr, 6, 300)
        try:
            with db() as conn:
                if conn.execute("SELECT 1 FROM users WHERE username=?", (username,)).fetchone():
                    raise RequestError(HTTPStatus.CONFLICT, "username already exists")
                cursor = conn.execute(
                    "INSERT INTO users(username,password_hash,is_admin,created_at) VALUES(?,?,?,?)",
                    (username, password_hash(password), 0, now()),
                )
                user = conn.execute("SELECT * FROM users WHERE id=?", (cursor.lastrowid,)).fetchone()
        except sqlite3.IntegrityError:
            raise RequestError(HTTPStatus.CONFLICT, "username already exists")
        self.finish_login(user)

    def set_device_notify(self, owner_id, device_id, payload):
        enabled = clean_int(payload.get("enabled"), "enabled", 0, 1)
        self.get_device(owner_id, device_id)
        timestamp = now()
        with db() as conn:
            conn.execute(
                "INSERT INTO device_notifications(device_id,owner_id,enabled,created_at) VALUES(?,?,?,?) "
                "ON CONFLICT(device_id) DO UPDATE SET enabled=excluded.enabled",
                (device_id, owner_id, enabled, timestamp),
            )
        self.send_json({"ok": True, "device_id": device_id, "enabled": bool(enabled)})

    def save_client_label(self, owner_id, device_id, payload):
        """终端人工标注（名称/品牌/类型）→ collected_labels，与 agent 上报共用同一张表。"""
        row = self.get_device(owner_id, device_id)
        mac = clean_mac(payload.get("mac"), True)
        name = clean_text(payload.get("name"), "name", 64)
        brand = clean_text(payload.get("brand"), "brand", 64).lower()
        devtype = clean_text(payload.get("type"), "type", 32).lower()
        oui = "".join(c for c in mac if c in "0123456789abcdef")[:6]
        if any(ord(char) < 32 or ord(char) == 127 for char in name):
            raise RequestError(HTTPStatus.BAD_REQUEST, "control characters are not allowed")
        timestamp = now()
        with db() as conn:
            if not (name or brand or devtype):
                conn.execute("DELETE FROM collected_labels WHERE mac=? AND device_id=?", (mac, row["device_id"]))
            else:
                conn.execute(
                    "INSERT INTO collected_labels(mac,device_id,oui,brand,type,name,auto,ts,updated_at) "
                    "VALUES(?,?,?,?,?,?,'{}',?,?) ON CONFLICT(mac) DO UPDATE SET "
                    "device_id=excluded.device_id,oui=excluded.oui,brand=excluded.brand,type=excluded.type,"
                    "name=excluded.name,ts=excluded.ts,updated_at=excluded.updated_at",
                    (mac, row["device_id"], oui, brand, devtype, name, timestamp, timestamp),
                )
        self.send_json({"ok": True, "client_labels": _client_labels_for(row["device_id"])})

    def rename_device(self, owner_id, device_id, payload):
        name = clean_text(payload.get("name", payload.get("display_name", "")), "name", 64)
        if any(ord(char) < 32 or ord(char) == 127 for char in name):
            raise RequestError(HTTPStatus.BAD_REQUEST, "control characters are not allowed")
        row = self.get_device(owner_id, device_id)
        with db() as conn:
            conn.execute("UPDATE devices SET display_name=?,updated_at=? WHERE device_id=?", (name, now(), row["device_id"]))
            row = conn.execute("SELECT * FROM devices WHERE device_id=?", (row["device_id"],)).fetchone()
        self.send_json({"ok": True, "device": device_json(row)})

    def unbind_device(self, owner_id, device_id):
        row = self.get_device(owner_id, device_id)
        with db() as conn:
            conn.execute("DELETE FROM commands WHERE device_id=?", (row["device_id"],))
            conn.execute(
                "UPDATE devices SET bound=0,display_name='',local_token_hash='',updated_at=? WHERE device_id=?",
                (now(), row["device_id"]),
            )
            self.queue_internal_command(conn, row["device_id"], row["owner_id"], "agent.rotate_local_token")
            conn.execute("DELETE FROM device_claims WHERE device_id=?", (row["device_id"],))
        self.send_json({"ok": True, "device_id": row["device_id"]})

    def confirm_command(self, owner_id, command_id):
        with db() as conn:
            row = conn.execute(
                "SELECT * FROM commands WHERE id=? AND owner_id=?",
                (command_id, owner_id),
            ).fetchone()
            if row is None:
                raise RequestError(HTTPStatus.NOT_FOUND, "command not found")
            if row["status"] != "success":
                raise RequestError(HTTPStatus.CONFLICT, "command is not ready to confirm")
            conn.execute("UPDATE commands SET confirmed_at=? WHERE id=?", (now(), command_id))
        self.send_json({"ok": True, "command_id": command_id})

    def claim_device(self, owner_id, payload):
        device_id = clean_device_id(payload.get("device_id"))
        claim_token = clean_text(payload.get("claim_token"), "claim_token", 256)
        pair_token = clean_text(payload.get("pair_token"), "pair_token", 256)
        serial = clean_text(payload.get("serial"), "serial", 128)
        mac = clean_mac(payload.get("mac"))
        model = clean_text(payload.get("model"), "model", 128)
        arch = clean_text(payload.get("arch"), "arch", 64)
        version = clean_text(payload.get("version"), "version", 128)
        firmware_version = clean_text(payload.get("firmware_version", version), "firmware_version", 128) or version
        agent_version = clean_int(payload.get("agent_version", 0), "agent_version", 0, 999999)
        timestamp = now()
        with db() as conn:
            existing = conn.execute("SELECT * FROM devices WHERE device_id=?", (device_id,)).fetchone()
            if existing is not None and existing["bound"] and existing["owner_id"] != owner_id:
                raise RequestError(HTTPStatus.CONFLICT, "device is already bound")
            pair_hash = ""
            claim = None
            if claim_token:
                claim = conn.execute(
                    "SELECT * FROM device_claims WHERE device_id=? AND claim_token_hash=? AND claim_expires_at>=?",
                    (device_id, hash_token(claim_token), timestamp),
                ).fetchone()
                if claim is None:
                    raise RequestError(HTTPStatus.GONE, "绑定码已失效，请重新发现设备")
                pair_hash = claim["pair_token_hash"]
                # 硬件指纹防抢：同一硬件已绑定到其他账号时，任何新凭证都无法再绑定
                if claim["hardware_id"]:
                    same = conn.execute(
                        "SELECT * FROM devices WHERE hardware_id=? AND bound=1 AND device_id!=?",
                        (claim["hardware_id"], device_id),
                    ).fetchone()
                    if same is not None:
                        if same["owner_id"] != owner_id:
                            raise RequestError(HTTPStatus.CONFLICT, "设备已绑定到其他账号")
                        raise RequestError(HTTPStatus.CONFLICT, "设备已绑定到当前账号")
            elif pair_token:
                if existing is None or existing["bound"] == 0 or existing["owner_id"] != owner_id:
                    raise RequestError(HTTPStatus.GONE, "旧版绑定码不能创建新设备，请先更新 Agent")
                pair_hash = hash_token(pair_token)
            else:
                raise RequestError(HTTPStatus.BAD_REQUEST, "claim_token is required")

            if existing is not None:
                if existing["bound"] and existing["owner_id"] != owner_id:
                    raise RequestError(HTTPStatus.CONFLICT, "device is already bound")
                if not hmac.compare_digest(existing["pair_token_hash"], pair_hash):
                    raise RequestError(HTTPStatus.FORBIDDEN, "device token does not match")
                conn.execute(
                    "UPDATE devices SET owner_id=?,bound=1,pair_token_hash=?,local_token_hash='',serial=?,mac=?,model=?,arch=?,version=?,firmware_version=?,agent_version=?,hardware_id=?,updated_at=? WHERE device_id=?",
                    (owner_id, pair_hash, serial or (claim["serial"] if claim else existing["serial"]), mac or (claim["mac"] if claim else existing["mac"]), model or (claim["model"] if claim else existing["model"]), arch or (claim["arch"] if claim else existing["arch"]), version or (claim["version"] if claim else existing["version"]), firmware_version or (claim["firmware_version"] if claim else existing["firmware_version"]), agent_version or (claim["agent_version"] if claim else existing["agent_version"]), claim["hardware_id"] if claim and claim["hardware_id"] else existing["hardware_id"], timestamp, device_id),
                )
            else:
                # 同硬件存在已解绑历史行（bound=0）→ 复用该行重新绑定（更新为新 device_id，保留硬件唯一性）
                if claim and claim["hardware_id"]:
                    old_unbound = conn.execute(
                        "SELECT * FROM devices WHERE hardware_id=? AND bound=0 AND device_id!=?",
                        (claim["hardware_id"], device_id),
                    ).fetchone()
                    if old_unbound:
                        old_id = old_unbound["device_id"]
                        if conn.execute("SELECT 1 FROM devices WHERE device_id=? AND device_id!=?", (device_id, old_id)).fetchone():
                            raise RequestError(HTTPStatus.CONFLICT, "device_id already exists")
                        conn.execute("PRAGMA defer_foreign_keys=ON")
                        conn.execute("DELETE FROM unbound_devices WHERE device_id=?", (device_id,))
                        conn.execute("UPDATE unbound_devices SET device_id=? WHERE device_id=?", (device_id, old_id))
                        conn.execute("UPDATE commands SET device_id=? WHERE device_id=?", (device_id, old_id))
                        conn.execute("UPDATE device_notifications SET device_id=? WHERE device_id=?", (device_id, old_id))
                        conn.execute("DELETE FROM device_claims WHERE device_id=?", (old_id,))
                        conn.execute(
                            "UPDATE devices SET device_id=?,owner_id=?,bound=1,pair_token_hash=?,local_token_hash='',serial=?,mac=?,model=?,arch=?,version=?,firmware_version=?,agent_version=?,hardware_id=?,updated_at=? WHERE device_id=?",
                            (device_id, owner_id, pair_hash, serial or (claim["serial"] if claim else ""), mac or (claim["mac"] if claim else ""), model or (claim["model"] if claim else ""), arch or (claim["arch"] if claim else ""), version or (claim["version"] if claim else ""), firmware_version or (claim["firmware_version"] if claim else ""), agent_version or (claim["agent_version"] if claim else 0), claim["hardware_id"], timestamp, old_id),
                        )
                        existing = conn.execute("SELECT * FROM devices WHERE device_id=?", (device_id,)).fetchone()
                if existing is None:
                    metadata = claim
                    conn.execute(
                        "INSERT INTO devices(device_id,owner_id,pair_token_hash,local_token_hash,bound,serial,mac,model,arch,version,firmware_version,agent_version,hardware_id,created_at,updated_at) "
                        "VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                        (
                            device_id,
                            owner_id,
                            pair_hash,
                            "",
                            1,
                            serial or (metadata["serial"] if metadata else ""),
                            mac or (metadata["mac"] if metadata else ""),
                            model or (metadata["model"] if metadata else ""),
                            arch or (metadata["arch"] if metadata else ""),
                            version or (metadata["version"] if metadata else ""),
                            firmware_version or (metadata["firmware_version"] if metadata else ""),
                            agent_version or (metadata["agent_version"] if metadata else 0),
                            metadata["hardware_id"] if metadata else "",
                            timestamp,
                            timestamp,
                        ),
                    )
            conn.execute("DELETE FROM device_claims WHERE device_id=?", (device_id,))
            conn.execute("DELETE FROM unbound_devices WHERE device_id=?", (device_id,))
            row = conn.execute("SELECT * FROM devices WHERE device_id=?", (device_id,)).fetchone()
            local_token_command_id = self.queue_internal_command(conn, device_id, owner_id, "agent.issue_local_token")
        result = {"ok": True, "device": device_json(row), "local_token_command_id": local_token_command_id}
        self.send_json(result)

    def agent_heartbeat(self, payload):
        """轻量心跳（16.5）：仅 device_id / 在线状态 / agent 版本 / 时间戳，约 1KB，
        用于在线判定（DEVICE_ONLINE_TTL=90 秒无心跳即离线），不携带 packages/containers 等重数据。
        未绑定注册设备也接受心跳（记录 IP/地域，供管理员全站视图）。"""
        device_id = clean_device_id(payload.get("device_id"))
        rate_limit("heartbeat", device_id, 6, 60)
        # 兼容旧 agent（≤16.4/1603 把完整上报 POST 到 /api/agent/heartbeat）
        if any(key in payload for key in ("telemetry", "packages", "containers", "clients", "topology")):
            self.agent_report(payload)
            return
        row, bound = self.agent_identity(payload)
        agent_version = clean_int(payload.get("agent_version", 0), "agent_version", 0, 999999)
        online = payload.get("online", True)
        if not isinstance(online, bool):
            raise RequestError(HTTPStatus.BAD_REQUEST, "invalid online")
        timestamp = now()
        public_ip = client_ip(self)
        region = geo.region_name(public_ip)
        if not region and "region" in row.keys():
            region = row["region"] or ""
        with db() as conn:
            if bound:
                conn.execute(
                    "UPDATE devices SET agent_version=?,last_seen=?,last_ip=?,region=?,updated_at=? WHERE device_id=?",
                    (agent_version or row["agent_version"], timestamp, public_ip, region, timestamp, row["device_id"]),
                )
            else:
                conn.execute(
                    "UPDATE unbound_devices SET agent_version=?,last_seen=?,last_ip=?,region=?,updated_at=? WHERE device_id=?",
                    (agent_version or row["agent_version"], timestamp, public_ip, region, timestamp, row["device_id"]),
                )
        self.send_json({"ok": True, "server_time": timestamp, "public_ip": public_ip, "report_interval": report_interval_for_agent()})

    def agent_report(self, payload):
        """完整遥测上报（16.5 起走 /api/agent/report）：10 分钟低频；App 实时查看时 5 秒一次。
        未绑定注册设备也接受（存 telemetry，供管理员只读视图）。"""
        device_id = clean_device_id(payload.get("device_id"))
        rate_limit("report", device_id, 24, 60)
        row, bound = self.agent_identity(payload)
        serial = clean_text(payload.get("serial"), "serial", 128)
        mac = clean_mac(payload.get("mac"))
        model = clean_text(payload.get("model"), "model", 128)
        arch = clean_text(payload.get("arch"), "arch", 64)
        version = clean_text(payload.get("version"), "version", 128)
        firmware_version = clean_text(payload.get("firmware_version", version), "firmware_version", 128) or version
        agent_version = clean_int(payload.get("agent_version", 0), "agent_version", 0, 999999)
        hardware_id = clean_text(payload.get("hardware_id"), "hardware_id", 80)
        telemetry = payload.get("telemetry", {})
        clients = payload.get("clients", [])
        packages = payload.get("packages", {})
        containers = payload.get("containers", {})
        oaf = payload.get("oaf", {})
        topology = payload.get("topology", {})
        if not isinstance(telemetry, dict) or not isinstance(clients, list) or len(clients) > MAX_CLIENTS:
            raise RequestError(HTTPStatus.BAD_REQUEST, "invalid telemetry")
        for value, name in ((packages, "packages"), (containers, "containers"), (oaf, "oaf")):
            if not isinstance(value, dict):
                raise RequestError(HTTPStatus.BAD_REQUEST, "invalid %s" % name)
        if not isinstance(topology, dict):
            raise RequestError(HTTPStatus.BAD_REQUEST, "invalid topology")
        # agent 稳定数据（packages/containers）是周期上报的；缺省时保留旧值避免闪空
        with db() as conn:
            current_row = conn.execute(
                "SELECT packages, containers FROM devices WHERE device_id=?",
                (row["device_id"],),
            ).fetchone()
        if "packages" not in payload:
            packages = parse_json_text(current_row["packages"] if current_row else "{}", {})
        if "containers" not in payload:
            containers = parse_json_text(current_row["containers"] if current_row else "{}", {})
        mesh = payload.get("gwrt_mesh", payload.get("mesh", {}))
        if not isinstance(mesh, dict):
            raise RequestError(HTTPStatus.BAD_REQUEST, "invalid mesh")
        if "mesh" not in payload and "gwrt_mesh" not in payload:
            with db() as conn2:
                r2 = conn2.execute("SELECT mesh FROM devices WHERE device_id=?", (row["device_id"],)).fetchone()
            mesh = parse_json_text(r2["mesh"] if r2 else "{}", {})
        topology_clients = topology.get("clients", [])
        topology_ports = topology.get("ports", [])
        if not isinstance(topology_clients, list) or len(topology_clients) > MAX_CLIENTS or not isinstance(topology_ports, list) or len(topology_ports) > 64:
            raise RequestError(HTTPStatus.BAD_REQUEST, "invalid topology")
        telemetry_json = bounded_json(telemetry, "telemetry", MAX_TELEMETRY_BYTES)
        clients_json = bounded_json(clients, "clients", MAX_TELEMETRY_BYTES)
        packages_json = bounded_json(packages, "packages", MAX_TELEMETRY_BYTES)
        containers_json = bounded_json(containers, "containers", MAX_TELEMETRY_BYTES)
        oaf_json = bounded_json(oaf, "oaf", MAX_TELEMETRY_BYTES)
        topology_json = bounded_json(topology, "topology", MAX_TELEMETRY_BYTES)
        timestamp = now()
        with db() as conn:
            if bound:
                conn.execute(
                    "UPDATE devices SET serial=?,mac=?,model=?,arch=?,version=?,firmware_version=?,agent_version=?,hardware_id=?,last_seen=?,telemetry=?,clients=?,packages=?,containers=?,oaf=?,topology=?,mesh=?,updated_at=? WHERE device_id=?",
                    (
                        serial,
                        mac,
                        model,
                        arch,
                        version,
                        firmware_version,
                        agent_version,
                        hardware_id or row["hardware_id"],
                        timestamp,
                        telemetry_json,
                        clients_json,
                        packages_json,
                        containers_json,
                        oaf_json,
                        topology_json,
                        bounded_json(mesh, "mesh", MAX_TELEMETRY_BYTES),
                        timestamp,
                        row["device_id"],
                    ),
                )
            else:
                conn.execute(
                    "UPDATE unbound_devices SET serial=?,mac=?,model=?,arch=?,version=?,firmware_version=?,agent_version=?,hardware_id=?,last_seen=?,telemetry=?,updated_at=? WHERE device_id=?",
                    (
                        serial,
                        mac,
                        model,
                        arch,
                        version,
                        firmware_version,
                        agent_version,
                        hardware_id or row["hardware_id"],
                        timestamp,
                        telemetry_json,
                        timestamp,
                        row["device_id"],
                    ),
                )
        # 采集：人工标注的设备识别（client_labels）+ 未知 eMMC（emmc_unknown）
        # 只写入 agent 明确上报的条目；正常识别到的设备不会出现在这里
        labels = payload.get("client_labels", [])
        if not isinstance(labels, list) or len(labels) > MAX_CLIENTS:
            raise RequestError(HTTPStatus.BAD_REQUEST, "invalid client_labels")
        emmc_unknown = payload.get("emmc_unknown")
        if emmc_unknown is not None and not isinstance(emmc_unknown, dict):
            raise RequestError(HTTPStatus.BAD_REQUEST, "invalid emmc_unknown")
        with db() as conn:
            for item in labels:
                if not isinstance(item, dict):
                    continue
                manual = item.get("manual") if isinstance(item.get("manual"), dict) else {}
                mac = clean_mac(item.get("mac"))
                brand = clean_text(manual.get("brand"), "brand", 64)
                devtype = clean_text(manual.get("type"), "type", 32)
                if not mac or not (brand or devtype):
                    continue
                conn.execute(
                    "INSERT INTO collected_labels(mac,device_id,oui,brand,type,name,auto,ts,updated_at) "
                    "VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(mac) DO UPDATE SET "
                    "device_id=excluded.device_id,oui=excluded.oui,brand=excluded.brand,type=excluded.type,"
                    "name=excluded.name,auto=excluded.auto,ts=excluded.ts,updated_at=excluded.updated_at",
                    (
                        mac,
                        row["device_id"],
                        clean_text(item.get("oui"), "oui", 16),
                        brand,
                        devtype,
                        clean_text(manual.get("name"), "name", 128),
                        bounded_json(item.get("auto") if isinstance(item.get("auto"), dict) else {}, "auto", 2048),
                        clean_int(item.get("ts", 0), "ts", 0, 4102444800),
                        timestamp,
                    ),
                )
            if emmc_unknown:
                cid = clean_text(emmc_unknown.get("cid"), "cid", 160)
                if cid:
                    conn.execute(
                        "INSERT INTO collected_emmc(cid,device_id,manfid,oemid,product,mdt,manufacturer,model,ts,updated_at) "
                        "VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(cid) DO UPDATE SET "
                        "device_id=excluded.device_id,manfid=excluded.manfid,oemid=excluded.oemid,"
                        "product=excluded.product,mdt=excluded.mdt,manufacturer=excluded.manufacturer,"
                        "model=excluded.model,ts=excluded.ts,updated_at=excluded.updated_at",
                        (
                            cid,
                            row["device_id"],
                            clean_text(emmc_unknown.get("manfid"), "manfid", 32),
                            clean_text(emmc_unknown.get("oemid"), "oemid", 32),
                            clean_text(emmc_unknown.get("product"), "product", 160),
                            clean_text(emmc_unknown.get("mdt"), "mdt", 64),
                            clean_text(emmc_unknown.get("manufacturer"), "manufacturer", 160),
                            clean_text(emmc_unknown.get("model"), "model", 160),
                            clean_int(emmc_unknown.get("ts", timestamp), "ts", 0, 4102444800),
                            timestamp,
                        ),
                    )
        self.send_json({"ok": True, "server_time": timestamp, "public_ip": client_ip(self), "report_interval": report_interval_for_agent()})

    def agent_pull(self, payload):
        row, _ = self.agent_identity(payload)
        cutoff = now() - 60
        with db() as conn:
            commands = conn.execute(
                "SELECT * FROM commands WHERE device_id=? AND status IN ('queued','delivered') "
                "AND (delivered_at IS NULL OR delivered_at<?) ORDER BY created_at LIMIT 16",
                (row["device_id"], cutoff),
            ).fetchall()
            timestamp = now()
            for command in commands:
                conn.execute(
                    "UPDATE commands SET status='delivered',delivered_at=? WHERE id=?",
                    (timestamp, command["id"]),
                )
        self.send_json(
            {
                "ok": True,
                "report_interval": report_interval_for_agent(),
                "commands": [
                    {
                        "id": command["id"],
                        "kind": command["kind"],
                        "payload": parse_json_text(command["payload"], {}),
                    }
                    for command in commands
                ],
            }
        )

    def agent_ack(self, payload):
        row, _ = self.agent_identity(payload)
        command_id = clean_text(payload.get("command_id"), "command_id", 128, True)
        status = clean_text(payload.get("status"), "status", 16, True)
        if status not in ("success", "failed", "rejected"):
            raise RequestError(HTTPStatus.BAD_REQUEST, "invalid command status")
        result = payload.get("result", {})
        if not isinstance(result, (dict, list, str, int, float, bool, type(None))):
            raise RequestError(HTTPStatus.BAD_REQUEST, "invalid command result")
        with db() as conn:
            command = conn.execute("SELECT kind FROM commands WHERE id=? AND device_id=?", (command_id, row["device_id"])).fetchone()
            updated = conn.execute(
                "UPDATE commands SET status=?,finished_at=?,result=? WHERE id=? AND device_id=?",
                (status, now(), json_text(result), command_id, row["device_id"]),
            ).rowcount
        if not updated:
            raise RequestError(HTTPStatus.NOT_FOUND, "command not found")
        if status == "success" and command and command["kind"] in {"agent.issue_local_token", "agent.rotate_local_token"} and isinstance(result, str):
            with db() as conn:
                conn.execute("UPDATE devices SET local_token_hash=? WHERE device_id=?", (hash_token(result), row["device_id"]))
        self.send_json({"ok": True})

    def create_command(self, owner_id, device_id, payload):
        row = self.get_device(owner_id, device_id)
        kind = clean_text(payload.get("kind"), "kind", 64, True)
        normalized = validate_command(kind, payload.get("payload", {}))
        if kind == "mesh.pair":
            mesh = parse_json_text(row["mesh"], {})
            if not mesh.get("available") or mesh.get("role") != "cap":
                raise RequestError(HTTPStatus.CONFLICT, "当前设备未启用 GWRT 主 AP 发现")
            if now() - int(row["last_seen"] or 0) > 60:
                raise RequestError(HTTPStatus.CONFLICT, "发现信息已过期，请等待设备刷新后重试")
            candidates = mesh.get("discovered_devices", mesh.get("discover", []))
            candidates = candidates if isinstance(candidates, list) else []
            found = False
            for item in candidates[:MAX_CLIENTS]:
                value = item.get("mac", "") if isinstance(item, dict) else item
                if isinstance(item, dict) and item.get("pairable") is False:
                    continue
                if isinstance(value, str) and re.fullmatch(r"[0-9a-fA-F:-]{12,17}", value):
                    if value.replace(":", "").replace("-", "").lower() == normalized["mac"].replace(":", ""):
                        found = True
                        break
            if not found:
                raise RequestError(HTTPStatus.CONFLICT, "该 AP 已不在发现列表，请刷新后重试")
        mark_active()
        command_id = secrets.token_urlsafe(16)
        with db() as conn:
            pending = conn.execute(
                "SELECT COUNT(*) FROM commands WHERE device_id=? AND status IN ('queued','delivered')",
                (row["device_id"],),
            ).fetchone()[0]
            if pending >= MAX_PENDING_COMMANDS:
                raise RequestError(HTTPStatus.TOO_MANY_REQUESTS, "该设备待执行命令过多，请稍后再试")
            conn.execute(
                "INSERT INTO commands(id,device_id,owner_id,kind,payload,created_at) VALUES(?,?,?,?,?,?)",
                (command_id, row["device_id"], row["owner_id"], kind, json_text(normalized), now()),
            )
        self.send_json({"ok": True, "command_id": command_id, "status": "queued"}, HTTPStatus.ACCEPTED)

    def serve_static(self, path):
        if path in ("", "/"):
            path = "/index.html"
        candidate = (STATIC / unquote(path.lstrip("/"))).resolve()
        if STATIC not in candidate.parents or not candidate.is_file():
            raise RequestError(HTTPStatus.NOT_FOUND, "not found")
        body = candidate.read_bytes()
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", mimetypes.guess_type(str(candidate))[0] or "application/octet-stream")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-cache")
        self.send_security_headers()
        self.end_headers()
        self.wfile.write(body)


def main():
    init_db()
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print("gwrt-control listening on %s:%d" % (HOST, PORT), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
