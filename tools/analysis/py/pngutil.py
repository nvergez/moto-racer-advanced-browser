"""Minimal PNG read/write helpers (stdlib only: zlib + struct).

read_png() supports 8-bit RGB/RGBA/grayscale/palette PNGs with any filter type,
which covers the harness screenshots and most tool output.
"""
import struct
import zlib


def write_png(path, width, height, rgb):
    """rgb: bytes/bytearray of width*height*3."""
    raw = bytearray()
    stride = width * 3
    for y in range(height):
        raw.append(0)
        raw += rgb[y * stride:(y + 1) * stride]

    def chunk(t, data):
        c = struct.pack(">I", len(data)) + t + data
        return c + struct.pack(">I", zlib.crc32(t + data) & 0xFFFFFFFF)

    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)))
        f.write(chunk(b"IDAT", zlib.compress(bytes(raw), 6)))
        f.write(chunk(b"IEND", b""))


def _paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    return b if pb <= pc else c


def read_png(path):
    """Return (width, height, rgb bytearray)."""
    with open(path, "rb") as f:
        data = f.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG: %s" % path)
    pos = 8
    idat = bytearray()
    palette = None
    while pos < len(data):
        (length,) = struct.unpack(">I", data[pos:pos + 4])
        t = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if t == b"IHDR":
            w, h, depth, ctype, _, _, interlace = struct.unpack(">IIBBBBB", body)
            if depth != 8 or interlace:
                raise ValueError("only 8-bit non-interlaced PNGs supported")
        elif t == b"PLTE":
            palette = body
        elif t == b"IDAT":
            idat += body
        elif t == b"IEND":
            break
    bpp = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[ctype]
    raw = zlib.decompress(bytes(idat))
    stride = w * bpp
    out = bytearray(h * stride)
    prev = bytearray(stride)
    i = 0
    for y in range(h):
        ft = raw[i]
        i += 1
        line = bytearray(raw[i:i + stride])
        i += stride
        for x in range(stride):
            a = line[x - bpp] if x >= bpp else 0
            b = prev[x]
            c = prev[x - bpp] if x >= bpp else 0
            if ft == 1:
                line[x] = (line[x] + a) & 0xFF
            elif ft == 2:
                line[x] = (line[x] + b) & 0xFF
            elif ft == 3:
                line[x] = (line[x] + ((a + b) >> 1)) & 0xFF
            elif ft == 4:
                line[x] = (line[x] + _paeth(a, b, c)) & 0xFF
        out[y * stride:(y + 1) * stride] = line
        prev = line
    rgb = bytearray(w * h * 3)
    for p in range(w * h):
        if ctype == 2:
            rgb[p * 3:p * 3 + 3] = out[p * 3:p * 3 + 3]
        elif ctype == 6:
            rgb[p * 3:p * 3 + 3] = out[p * 4:p * 4 + 3]
        elif ctype == 0:
            rgb[p * 3:p * 3 + 3] = bytes([out[p]] * 3)
        elif ctype == 4:
            rgb[p * 3:p * 3 + 3] = bytes([out[p * 2]] * 3)
        elif ctype == 3:
            k = out[p] * 3
            rgb[p * 3:p * 3 + 3] = palette[k:k + 3]
    return w, h, rgb
