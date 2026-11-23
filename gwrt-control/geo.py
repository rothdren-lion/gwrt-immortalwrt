"""IP 地域解析：ip2region 离线库（纯标准库，无外部依赖）。

数据文件 server/geo/ip2region_v4.xdb（MIT，https://github.com/lionsoul2014/ip2region），
xdb 3.0 格式：内存加载 + vector index 定位 + 段二分查找 + LRU 缓存，线程安全。
"""

from __future__ import annotations

import ipaddress
import os
import threading

_HEADER_SIZE = 256
_VECTOR_COLS = 256
_VECTOR_BLOCK = 8  # [s_ptr u32, e_ptr u32]
_INDEX_V4 = 14     # [s_ip 4][e_ip 4][d_len 2][d_ptr 4] little-endian
_INDEX_V6 = 38
_CACHE_MAX = 8192

_lock = threading.Lock()
_xdb = None
_cache: dict[int, str] = {}


class _Xdb:
    def __init__(self, path: str):
        with open(path, "rb") as handle:
            self.buffer = handle.read()
        buf = self.buffer
        if len(buf) < _HEADER_SIZE:
            raise RuntimeError("ip2region xdb too small: %d bytes" % len(buf))
        self.ip_version = int.from_bytes(buf[16:18], "little")
        self.index_size = _INDEX_V4 if self.ip_version == 4 else _INDEX_V6

    def search(self, ip_int: int) -> str:
        """按整数 IP 查找，返回 '国家|区域|省份|城市|ISP'；未命中返回 ''。"""
        if ip_int <= 0 or ip_int > 0xFFFFFFFF:
            return ""
        buf = self.buffer
        il0 = (ip_int >> 24) & 0xFF
        il1 = (ip_int >> 16) & 0xFF
        offset = _HEADER_SIZE + (il0 * _VECTOR_COLS + il1) * _VECTOR_BLOCK
        s_ptr = int.from_bytes(buf[offset:offset + 4], "little")
        e_ptr = int.from_bytes(buf[offset + 4:offset + 8], "little")
        if s_ptr == 0 or e_ptr == 0 or e_ptr < s_ptr:
            return ""
        low, high = 0, (e_ptr - s_ptr) // self.index_size
        while low <= high:
            mid = (low + high) >> 1
            p = s_ptr + mid * self.index_size
            seg_start = int.from_bytes(buf[p:p + 4], "little")
            if ip_int < seg_start:
                high = mid - 1
                continue
            seg_end = int.from_bytes(buf[p + 4:p + 8], "little")
            if ip_int > seg_end:
                low = mid + 1
                continue
            data_len = int.from_bytes(buf[p + 8:p + 10], "little")
            data_ptr = int.from_bytes(buf[p + 10:p + 14], "little")
            return buf[data_ptr:data_ptr + data_len].decode("utf-8", "replace")
        return ""


def _load() -> _Xdb:
    global _xdb
    if _xdb is not None:
        return _xdb
    with _lock:
        if _xdb is None:
            path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "geo", "ip2region_v4.xdb")
            _xdb = _Xdb(path)
    return _xdb


def lookup(ip: str) -> str:
    """原始查询：返回 '国家|区域|省份|城市|ISP'；内网/保留地址或失败返回 ''。"""
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return ""
    if addr.is_private or addr.is_loopback or addr.is_link_local or addr.is_multicast or addr.is_unspecified or addr.is_reserved:
        return ""
    ip_int = int(addr)
    hit = _cache.get(ip_int)
    if hit is not None:
        return hit
    try:
        result = _load().search(ip_int)
    except Exception:
        result = ""
    if len(_cache) < _CACHE_MAX:
        _cache[ip_int] = result
    return result


def region_name(ip: str) -> str:
    """展示用地域名：中国返回 '广东 · 深圳'，国外返回国家名，无法解析返回 ''。"""
    raw = lookup(ip)
    parts = [part.strip() for part in raw.split("|")] if raw else []
    if not parts or not parts[0] or parts[0] in ("0", "内网IP", "本机地址", "局域网"):
        return ""
    country = parts[0]
    if country == "中国":
        province = parts[1] if len(parts) > 1 and parts[1] not in ("0", "") else ""
        city = parts[2] if len(parts) > 2 and parts[2] not in ("0", "") else ""
        return " · ".join(part for part in (province, city) if part) or country
    return country
