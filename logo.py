#!/usr/bin/env python3
"""Extract and replace BMP records in supported Xiaomi LOGO images.

Based on the implementation credited to Hackintosh 5 (2019).
See LICENSES.txt for attribution and licensing information.
"""

from __future__ import annotations

import argparse
import os
import struct
import tempfile
from contextlib import ExitStack
from pathlib import Path
from typing import BinaryIO, Iterable

HEADER = b"LOGO!!!!"
BMP_HEADER = b"BM"
LOGO_HEADER_OFFSET = 0x4000
OFFSET_TABLE_OFFSET = 0x4008
OFFSET_UNIT = 0x1000
MAX_OFFSET_RECORDS = 4096


def check_header(file_obj: BinaryIO) -> None:
    """Verify the Xiaomi LOGO signature at its fixed header offset."""
    file_obj.seek(LOGO_HEADER_OFFSET)
    header = file_obj.read(len(HEADER))
    if header != HEADER:
        raise ValueError(
            "Wrong or truncated Xiaomi LOGO header: expected LOGO!!!! "
            "at offset 0x4000"
        )


def _read_offset_records(file_obj: BinaryIO) -> list[int]:
    """Read image starts using the legacy Xiaomi LOGO table convention.

    The final non-zero table record is a terminator/boundary record, not an
    image start that must be interpreted as an absolute cumulative EOF offset.
    Preserve the original MR MATRIX parser's pairwise offset calculation; the
    previous rewrite incorrectly accumulated every delta and rejected valid
    64 MiB logo.img files when that synthetic final value exceeded EOF.
    """
    file_size = os.fstat(file_obj.fileno()).st_size
    file_obj.seek(OFFSET_TABLE_OFFSET)

    previous_value = 0
    offsets: list[int] = []
    terminated = False

    for _ in range(MAX_OFFSET_RECORDS):
        raw = file_obj.read(4)
        if len(raw) != 4:
            raise ValueError("Truncated Xiaomi LOGO offset table")

        (value,) = struct.unpack("<I", raw)
        if value == 0:
            terminated = True
            break

        offset = (value + previous_value) * OFFSET_UNIT
        previous_value = value
        if not offsets or offset != offsets[-1]:
            offsets.append(offset)

    if not terminated:
        raise ValueError("Offset table has no terminator")
    if len(offsets) < 2:
        raise ValueError("Offset table must contain image records and a final boundary record")

    # Match the original parser: the final non-zero record is not a BMP slot.
    image_starts = offsets[:-1]
    table_end = OFFSET_TABLE_OFFSET + (len(offsets) + 1) * 4
    if not image_starts:
        raise ValueError("No image records found in the LOGO offset table")
    if image_starts[0] < table_end:
        raise ValueError("First image slot overlaps the LOGO offset table")
    if any(a >= b for a, b in zip(image_starts, image_starts[1:])):
        raise ValueError("LOGO image offsets are not strictly increasing")
    if any(offset >= file_size for offset in image_starts):
        raise ValueError("A LOGO image offset points beyond the input image")

    return offsets


def get_offsets(file_obj: BinaryIO) -> list[int]:
    """Return the start offset of each BMP record, excluding the final marker."""
    return _read_offset_records(file_obj)[:-1]


def get_slot_ranges(file_obj: BinaryIO) -> list[tuple[int, int]]:
    """Return each image slot as a half-open (start, end) byte range."""
    starts = get_offsets(file_obj)
    file_size = os.fstat(file_obj.fileno()).st_size
    boundaries = starts[1:] + [file_size]
    return list(zip(starts, boundaries))


def bmp_info(data: bytes, label: str = "BMP") -> tuple[int, int, int, int]:
    """Validate a Windows BMP header and its complete 24-bit raster."""
    if len(data) < 54 or data[:2] != BMP_HEADER:
        raise ValueError(f"{label}: invalid or truncated BMP")

    size = struct.unpack_from("<I", data, 2)[0]
    pixel_offset = struct.unpack_from("<I", data, 10)[0]
    dib_size = struct.unpack_from("<I", data, 14)[0]
    width = struct.unpack_from("<i", data, 18)[0]
    height = struct.unpack_from("<i", data, 22)[0]
    planes = struct.unpack_from("<H", data, 26)[0]
    bits_per_pixel = struct.unpack_from("<H", data, 28)[0]
    compression = struct.unpack_from("<I", data, 30)[0]
    image_size = struct.unpack_from("<I", data, 34)[0]

    if size != len(data):
        raise ValueError(
            f"{label}: BMP size field ({size}) does not match "
            f"file size ({len(data)})"
        )
    if dib_size < 40 or 14 + dib_size > len(data):
        raise ValueError(f"{label}: unsupported or malformed DIB header")
    if pixel_offset < 14 + dib_size or pixel_offset > len(data):
        raise ValueError(f"{label}: invalid pixel-data offset")
    if width <= 0 or height == 0 or planes != 1:
        raise ValueError(f"{label}: invalid BMP dimensions or plane count")
    if bits_per_pixel != 24 or compression != 0:
        raise ValueError(
            f"{label}: use an uncompressed 24-bit BMP, as required by the original tool"
        )

    row_bytes = ((width * bits_per_pixel + 31) // 32) * 4
    raster_size = row_bytes * abs(height)
    if image_size not in (0, raster_size, raster_size + 2):
        raise ValueError(f"{label}: inconsistent 24-bit BMP raster size")
    if pixel_offset + raster_size > len(data):
        raise ValueError(f"{label}: pixel data is truncated")

    return width, height, bits_per_pixel, compression


def extract(file_obj: BinaryIO) -> Iterable[bytes]:
    """Yield validated BMP records without crossing their LOGO slots."""
    check_header(file_obj)

    for index, (offset, slot_end) in enumerate(get_slot_ranges(file_obj)):
        file_obj.seek(offset)
        header = file_obj.read(6)
        if len(header) != 6 or header[:2] != BMP_HEADER:
            raise ValueError(
                f"Expected a BMP record at offset 0x{offset:X}; "
                "input layout is unsupported"
            )

        size = struct.unpack("<I", header[2:6])[0]
        if size < 54 or offset + size > slot_end:
            raise ValueError(f"Invalid BMP length in image slot {index}")

        file_obj.seek(offset)
        data = file_obj.read(size)
        if len(data) != size:
            raise ValueError(f"Truncated BMP data in image slot {index}")
        bmp_info(data, f"Image {index} at 0x{offset:X}")
        yield data


def _normalize_android_bmp(
    original: bytes,
    edited: bytes,
    original_info: tuple[int, int, int, int],
    edited_info: tuple[int, int, int, int],
    index: int,
) -> tuple[bytes, tuple[int, int, int, int]]:
    """Restore the known two-byte XDA BMP tail when the raster is unchanged."""
    if len(edited) != len(original) - 2 or edited_info != original_info:
        return edited, edited_info

    old_pixel_offset = struct.unpack_from("<I", original, 10)[0]
    new_pixel_offset = struct.unpack_from("<I", edited, 10)[0]
    old_image_size = struct.unpack_from("<I", original, 34)[0]
    new_image_size = struct.unpack_from("<I", edited, 34)[0]
    width, height, bits_per_pixel, _ = edited_info
    row_bytes = ((width * bits_per_pixel + 31) // 32) * 4
    raster_size = row_bytes * abs(height)

    normal_export = (
        old_pixel_offset == new_pixel_offset
        and old_pixel_offset + new_image_size == len(edited)
        and new_image_size == raster_size
        and old_pixel_offset + old_image_size == len(original)
        and old_image_size == new_image_size + 2
        and struct.unpack_from("<I", original, 2)[0] == len(original)
        and struct.unpack_from("<I", edited, 2)[0] == len(edited)
    )
    if not normal_export:
        return edited, edited_info

    normalized = bytearray(edited + original[-2:])
    struct.pack_into("<I", normalized, 2, len(original))
    struct.pack_into("<I", normalized, 34, old_image_size)
    normalized_bytes = bytes(normalized)
    normalized_info = bmp_info(normalized_bytes, f"Normalized image {index}")

    print(
        f"Image {index}: normalized Android BMP export "
        f"({len(edited)} -> {len(normalized_bytes)} bytes; "
        "restored 2-byte XDA tail)."
    )
    return normalized_bytes, normalized_info


def edit(original_file: BinaryIO, new_images: list[bytes]) -> bytes:
    """Replace image records while preserving the source image layout."""
    check_header(original_file)
    slot_ranges = get_slot_ranges(original_file)
    if len(slot_ranges) != len(new_images):
        raise ValueError(
            f"Expected {len(slot_ranges)} BMP files, received {len(new_images)}"
        )

    original_file.seek(0)
    binary = bytearray(original_file.read())
    original_images = list(extract(original_file))
    if len(original_images) != len(new_images):
        raise ValueError("Could not validate every original BMP slot")

    for index, ((offset, slot_end), original, edited) in enumerate(
        zip(slot_ranges, original_images, new_images)
    ):
        original_info = bmp_info(original, f"Original image {index}")
        edited_info = bmp_info(edited, f"Edited image {index}")
        edited, edited_info = _normalize_android_bmp(
            original, edited, original_info, edited_info, index
        )

        if len(edited) != len(original):
            raise ValueError(
                f"Image {index} byte length changed: expected {len(original)}, "
                f"got {len(edited)}. Re-export as uncompressed 24-bit BMP with "
                "the original dimensions; do not resize or change color depth."
            )
        if original_info != edited_info:
            raise ValueError(
                f"Image {index} dimensions/format changed: expected "
                f"{original_info}, got {edited_info}. Keep the original "
                "dimensions and 24-bit uncompressed format."
            )
        if offset + len(edited) > slot_end:
            raise ValueError(f"Image {index} is too large and would overlap the next record")

        binary[offset : offset + len(original)] = edited

    return bytes(binary)


def extract_logo(input_file: BinaryIO, output_dir: str) -> None:
    """Validate all records, then atomically install extracted BMP files."""
    photos = list(extract(input_file))
    if not photos:
        raise ValueError("No BMP images were extracted")

    destination = Path(output_dir)
    destination.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix=".logo-extract-", dir=destination) as temp_dir:
        staged_files: list[tuple[Path, Path]] = []
        for index, photo in enumerate(photos):
            staged = Path(temp_dir) / f"logo-{index}.bmp"
            staged.write_bytes(photo)
            staged_files.append((staged, destination / staged.name))

        for staged, final_path in staged_files:
            os.replace(staged, final_path)

    print(f"Extracted {len(photos)} BMP images to {destination}")


def replace_logo(
    input_file: BinaryIO, image_files: list[BinaryIO], output_path: str
) -> None:
    """Build and atomically replace the requested output image."""
    new_images = [image.read() for image in image_files]
    result = edit(input_file, new_images)

    destination = Path(output_path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    file_descriptor, temporary_path = tempfile.mkstemp(
        prefix=f".{destination.name}.", suffix=".tmp", dir=destination.parent
    )
    try:
        with os.fdopen(file_descriptor, "wb") as output_file:
            output_file.write(result)
            output_file.flush()
            os.fsync(output_file.fileno())
        os.replace(temporary_path, destination)
    except Exception:
        try:
            os.unlink(temporary_path)
        except FileNotFoundError:
            pass
        raise

    print(f"Rebuilt image written to {destination}")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Xiaomi LOGO image extractor/replacer"
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    extract_parser = subparsers.add_parser("extract")
    extract_parser.add_argument(
        "-i", "--input", dest="input", type=argparse.FileType("rb"), required=True
    )
    extract_parser.add_argument("-o", "--output", required=True)

    replace_parser = subparsers.add_parser("replace")
    replace_parser.add_argument(
        "-i", "--input", dest="input", type=argparse.FileType("rb"), required=True
    )
    replace_parser.add_argument(
        "-a", "--image", dest="images", action="append",
        type=argparse.FileType("rb"), required=True
    )
    replace_parser.add_argument("-o", "--output", required=True)

    args = parser.parse_args()
    try:
        with ExitStack() as stack:
            input_file = stack.enter_context(args.input)
            if args.command == "extract":
                extract_logo(input_file, args.output)
            else:
                image_files = [stack.enter_context(image) for image in args.images]
                replace_logo(input_file, image_files, args.output)
    except (OSError, ValueError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
