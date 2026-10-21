"""Bound raster allocation estimates using metadata, without decoding pixels."""

MAX_METADATA_BYTES = 64 * 1024
MAX_DECODED_BYTES = 64 * 1024 * 1024
BYTES_PER_PIXEL = 8
JPEG_FRAME_MARKERS = {0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7,
                      0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF}
BMP_HEADER_BYTES = {12, 40, 52, 56, 108, 124}


class Metadata:
    def __init__(self, data):
        self.data = data
        self.remaining_bytes = MAX_METADATA_BYTES

    def read(self, offset, size):
        if size < 0 or offset < 0 or offset + size > len(self.data) or size > self.remaining_bytes:
            raise ValueError("Raster metadata exceeds its bounds")
        self.remaining_bytes -= size
        return self.data[offset:offset + size]

    def integer(self, offset, size, byte_order="little", signed=False):
        return int.from_bytes(self.read(offset, size), byte_order, signed=signed)


def png_dimensions(metadata):
    header = metadata.read(0, 33)
    if header[:16] != b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR":
        return None
    return int.from_bytes(header[16:20], "big"), int.from_bytes(header[20:24], "big")


def gif_subblocks(metadata, offset):
    while True:
        size = metadata.integer(offset, 1)
        offset += 1
        if size == 0:
            return offset
        offset += size
        if offset > len(metadata.data):
            raise ValueError("Truncated GIF block")


def gif_dimensions(metadata):
    header = metadata.read(0, 13)
    if header[:6] not in (b"GIF87a", b"GIF89a"):
        return None
    width = int.from_bytes(header[6:8], "little")
    height = int.from_bytes(header[8:10], "little")
    offset = 13 + (3 * (1 << ((header[10] & 7) + 1)) if header[10] & 0x80 else 0)
    frames = 0
    while offset < len(metadata.data):
        marker = metadata.integer(offset, 1)
        offset += 1
        if marker == 0x3B:
            return (width, height) if frames else None
        if marker == 0x21:
            metadata.read(offset, 1)
            offset = gif_subblocks(metadata, offset + 1)
            continue
        if marker != 0x2C:
            return None
        frame = metadata.read(offset, 9)
        left, top, frame_width, frame_height = (
            int.from_bytes(frame[index:index + 2], "little") for index in (0, 2, 4, 6))
        if (frame_width == 0 or frame_height == 0
                or left + frame_width > width or top + frame_height > height):
            return None
        offset += 9 + (3 * (1 << ((frame[8] & 7) + 1)) if frame[8] & 0x80 else 0)
        metadata.read(offset, 1)
        offset = gif_subblocks(metadata, offset + 1)
        frames += 1
    return None


def bmp_dimensions(metadata):
    header = metadata.read(0, 26)
    if header[:2] != b"BM":
        return None
    header_bytes = int.from_bytes(header[14:18], "little")
    if header_bytes not in BMP_HEADER_BYTES:
        return None
    metadata.read(14, header_bytes)
    if header_bytes == 12:
        return int.from_bytes(header[18:20], "little"), int.from_bytes(header[20:22], "little")
    width = int.from_bytes(header[18:22], "little", signed=True)
    height = int.from_bytes(header[22:26], "little", signed=True)
    return width, abs(height)


def jpeg_dimensions(metadata):
    if metadata.read(0, 2) != b"\xff\xd8":
        return None
    offset = 2
    while offset < len(metadata.data):
        if metadata.integer(offset, 1) != 0xFF:
            return None
        marker = 0xFF
        while marker == 0xFF:
            offset += 1
            marker = metadata.integer(offset, 1)
        offset += 1
        if marker in (0, 0xD8, 0xD9, 0xDA):
            return None
        if marker == 1 or 0xD0 <= marker <= 0xD7:
            continue
        segment_bytes = metadata.integer(offset, 2, "big")
        if segment_bytes < 2 or offset + segment_bytes > len(metadata.data):
            return None
        if marker in JPEG_FRAME_MARKERS:
            if segment_bytes < 8:
                return None
            frame = metadata.read(offset, 8)
            if frame[7] == 0 or segment_bytes != 8 + frame[7] * 3:
                return None
            return int.from_bytes(frame[5:7], "big"), int.from_bytes(frame[3:5], "big")
        offset += segment_bytes
    return None


def webp_bitstream(metadata, kind, offset, size):
    if kind == b"VP8L":
        if size < 5:
            return None
        header = metadata.read(offset, 5)
        bits = int.from_bytes(header[1:5], "little")
        if header[0] != 0x2F or bits >> 29:
            return None
        return (bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1
    if kind == b"VP8 ":
        if size < 10:
            return None
        header = metadata.read(offset, 10)
        if header[0] & 1 or header[3:6] != b"\x9d\x01\x2a":
            return None
        return int.from_bytes(header[6:8], "little") & 0x3FFF, int.from_bytes(header[8:10], "little") & 0x3FFF
    return None


def webp_chunks(metadata, offset, end):
    while offset < end:
        if offset + 8 > end:
            raise ValueError("Truncated WebP chunk")
        header = metadata.read(offset, 8)
        size = int.from_bytes(header[4:8], "little")
        next_offset = offset + 8 + size + (size & 1)
        if next_offset > end:
            raise ValueError("WebP chunk exceeds its container")
        yield header[:4], offset + 8, size
        offset = next_offset


def webp_frame(metadata, offset, size, canvas):
    if size < 16:
        return False
    header = metadata.read(offset, 16)
    left, top = (int.from_bytes(header[index:index + 3], "little") * 2 for index in (0, 3))
    width, height = (int.from_bytes(header[index:index + 3], "little") + 1 for index in (6, 9))
    if left + width > canvas[0] or top + height > canvas[1]:
        return False
    found = False
    for kind, start, length in webp_chunks(metadata, offset + 16, offset + size):
        if kind in (b"VP8 ", b"VP8L"):
            if found or webp_bitstream(metadata, kind, start, length) != (width, height):
                return False
            found = True
    return found


def webp_dimensions(metadata):
    header = metadata.read(0, 12)
    if header[:4] != b"RIFF" or header[8:12] != b"WEBP":
        return None
    file_bytes = int.from_bytes(header[4:8], "little") + 8
    if file_bytes != len(metadata.data):
        return None
    canvas = None
    image_found = False
    animated = False
    for kind, offset, size in webp_chunks(metadata, 12, file_bytes):
        if kind == b"VP8X":
            if canvas is not None or size != 10 or offset != 20:
                return None
            extended = metadata.read(offset, 10)
            animated = bool(extended[0] & 2)
            canvas = (int.from_bytes(extended[4:7], "little") + 1,
                      int.from_bytes(extended[7:10], "little") + 1)
        elif kind in (b"VP8 ", b"VP8L"):
            dimensions = webp_bitstream(metadata, kind, offset, size)
            if dimensions is None or image_found or animated or (canvas is not None and dimensions != canvas):
                return None
            canvas = dimensions
            image_found = True
        elif kind == b"ANMF":
            if not animated or canvas is None or not webp_frame(metadata, offset, size, canvas):
                return None
            image_found = True
    return canvas if image_found else None


def decoded_bytes(data, mime):
    parsers = {"image/png": png_dimensions, "image/gif": gif_dimensions,
               "image/bmp": bmp_dimensions, "image/jpeg": jpeg_dimensions,
               "image/webp": webp_dimensions}
    parser = parsers.get(mime)
    if parser is None:
        return None
    try:
        dimensions = parser(Metadata(data))
    except ValueError:
        return None
    if dimensions is None:
        return None
    width, height = dimensions
    if width <= 0 or height <= 0:
        return None
    allocation = width * height * BYTES_PER_PIXEL
    return allocation if allocation <= MAX_DECODED_BYTES else None
