"""Gera icones PNG simples (sem dependencias externas) para o PWA Deposito de Agua."""
import struct
import zlib


def png_chunk(tag, data):
    return (
        struct.pack(">I", len(data))
        + tag
        + data
        + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    )


def make_icon(path, size):
    bg = (244, 247, 251)     # #f4f7fb
    accent = (14, 165, 196)  # #0ea5c4
    white = (255, 255, 255)

    cx = cy = size / 2
    r_outer = size * 0.40
    r_inner = size * 0.16

    raw = bytearray()
    for y in range(size):
        raw.append(0)  # filter type 0
        for x in range(size):
            dx, dy = x - cx, y - cy
            dist = (dx * dx + dy * dy) ** 0.5
            if dist <= r_inner:
                pixel = white
            elif dist <= r_outer:
                pixel = accent
            else:
                pixel = bg
            raw.extend(pixel)

    ihdr = struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)
    png = (
        b"\x89PNG\r\n\x1a\n"
        + png_chunk(b"IHDR", ihdr)
        + png_chunk(b"IDAT", zlib.compress(bytes(raw), 9))
        + png_chunk(b"IEND", b"")
    )
    with open(path, "wb") as f:
        f.write(png)


make_icon("icon-192.png", 192)
make_icon("icon-512.png", 512)
print("Icones gerados: icon-192.png, icon-512.png")
