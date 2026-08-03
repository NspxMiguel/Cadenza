#!/usr/bin/env python3
"""Writes a full ID3v2.3 tag onto an mp3, with no dependencies.

The point is to produce a file tagged the way a real ripper tags one — composer,
track number out of a total, year, cover — so the app's reader can be tested
against something it did not itself produce.
"""
import struct
import sys
import zlib

src, dst = sys.argv[1], sys.argv[2]
raw = open(src, "rb").read()

# Drop whatever tag is already there; the audio starts after it.
if raw[:3] == b"ID3":
    size = 0
    for byte in raw[6:10]:
        size = (size << 7) | (byte & 0x7F)
    audio = raw[10 + size:]
else:
    audio = raw


def text_frame(frame_id, value):
    # 0x01 = UTF-16 with BOM, the only Unicode encoding ID3v2.3 defines.
    body = b"\x01" + b"\xff\xfe" + value.encode("utf-16-le") + b"\x00\x00"
    return frame_id + struct.pack(">I", len(body)) + b"\x00\x00" + body


def png(width, height, rgb):
    def chunk(kind, data):
        return (struct.pack(">I", len(data)) + kind + data
                + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF))

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    rows = b"".join(b"\x00" + bytes(rgb) * width for _ in range(height))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr)
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


cover = png(60, 60, (180, 30, 40))
# APIC: encoding, mime, picture type (3 = front cover), description, bytes.
apic_body = b"\x00" + b"image/png\x00" + b"\x03" + b"\x00" + cover
apic = b"APIC" + struct.pack(">I", len(apic_body)) + b"\x00\x00" + apic_body

frames = b"".join([
    text_frame(b"TIT2", "Adagio sostenuto"),
    text_frame(b"TPE1", "Wilhelm Kempff"),
    text_frame(b"TALB", "As 32 Sonatas para Piano"),
    text_frame(b"TCOM", "Ludwig van Beethoven"),
    text_frame(b"TCON", "Clássico"),
    text_frame(b"TRCK", "7/12"),
    text_frame(b"TYER", "1965"),
    apic,
])


def syncsafe(n):
    return bytes([(n >> 21) & 0x7F, (n >> 14) & 0x7F, (n >> 7) & 0x7F, n & 0x7F])


header = b"ID3" + b"\x03\x00" + b"\x00" + syncsafe(len(frames))
open(dst, "wb").write(header + frames + audio)
print(f"{dst}: {len(frames)} bytes de etiquetas + {len(audio)} bytes de áudio")
