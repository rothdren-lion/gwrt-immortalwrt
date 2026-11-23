#!/usr/bin/env python3
"""Exercise the factory/sysupgrade comparison using a real generated SquashFS."""
import contextlib
import importlib.util
import io
from pathlib import Path
import struct
import subprocess
import tempfile

SCRIPT = Path(__file__).resolve().parents[1] / 'gwrt-verify-ipq60xx-image.py'
spec = importlib.util.spec_from_file_location('gwrt_ipq60xx_audit', SCRIPT)
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


def check(factory, root, offset, succeeds, reason):
    with contextlib.redirect_stdout(io.StringIO()):
        try:
            with factory.open('rb') as stream:
                audit.verify_factory_rootfs(stream, root, offset)
        except SystemExit as exc:
            if succeeds or reason not in str(exc):
                raise AssertionError(f'{reason}: unexpected failure: {exc}') from exc
        else:
            if not succeeds:
                raise AssertionError(f'{reason}: expected failure')
    print('PASS', reason)


with tempfile.TemporaryDirectory(prefix='gwrt-rootfs-test-') as directory:
    work = Path(directory)
    (work / 'input').mkdir()
    (work / 'input' / 'content').write_bytes(b'GWRT image audit regression\n' * 100)
    raw = work / 'raw.squashfs'
    subprocess.run(['mksquashfs', str(work / 'input'), str(raw), '-processors', '1',
                    '-nopad', '-noappend', '-quiet'], check=True)
    payload = raw.read_bytes()
    size, = struct.unpack_from('<Q', payload, 40)
    assert len(payload) == size and payload[:4] == b'hsqs'
    offset = 12 * 1024 * 1024
    padding = (-size) % 1024
    root = work / 'root.squashfs'
    root.write_bytes(payload + bytes(padding))
    factory = work / 'factory.bin'
    with factory.open('wb') as out:
        out.seek(offset)
        out.write(payload + b'fwtool metadata')
    check(factory, root, offset, True, 'valid payload with alignment and metadata')
    check(factory, root, 6 * 1024 * 1024, False, 'factory rootfs differs')
    with factory.open('r+b') as out:
        out.seek(offset + size // 2)
        byte = out.read(1)
        out.seek(-1, 1)
        out.write(bytes((byte[0] ^ 1,)))
    check(factory, root, offset, False, 'factory rootfs differs')
    with factory.open('r+b') as out:
        out.seek(offset)
        out.write(payload)
        out.truncate(offset + size - 1)
    check(factory, root, offset, False, 'factory rootfs differs')
    malformed = bytearray(payload)
    struct.pack_into('<Q', malformed, 40, len(payload) + 2048)
    root.write_bytes(malformed + bytes(padding))
    check(factory, root, offset, False, 'invalid SquashFS size')
    root.write_bytes(payload + bytes(padding + 1024))
    check(factory, root, offset, False, 'unexpected sysupgrade rootfs padding')
    if padding:
        root.write_bytes(payload + bytes(padding - 1) + b'\x01')
        with factory.open('r+b') as out:
            out.seek(offset)
            out.write(payload)
        check(factory, root, offset, False, 'sysupgrade rootfs padding is not zero')
