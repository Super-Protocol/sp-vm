#!/usr/bin/env python3
"""Append a deterministic fixed-VHD footer to a raw disk image.

Azure imports disks only as fixed VHDs: the raw image followed by a 512-byte
footer. The footer is built with a fixed timestamp and UUID, so the same image
always produces the same VHD and its hash can be published and compared.
"""

import argparse
import os
import struct
import sys

SECTOR = 512
MIB = 1024 * 1024
# Fixed identity: a VHD built from the same image is byte-for-byte the same.
FIXED_TIMESTAMP = 0  # 2000-01-01T00:00:00Z in VHD epoch
FIXED_UUID = bytes.fromhex("5350564d494d4147450000000000dead")
CREATOR_APP = b"spvm"
CREATOR_HOST_OS = b"Wi2k"  # what every other tool writes; some readers check it


# CHS cannot address the whole disk exactly, so the geometry is pinned to its
# maximum and the real size is taken from the size fields. This is what
# `qemu-img convert -o subformat=fixed,force_size` writes, and what the images
# Azure already accepted were built with.
MAX_GEOMETRY = (65535, 16, 255)


def build_footer(size: int) -> bytes:
    cylinders, heads, sectors_per_track = MAX_GEOMETRY
    footer = bytearray(SECTOR)
    struct.pack_into(
        ">8sIIQI4sI4sQQHBBI",
        footer, 0,
        b"conectix",          # cookie
        0x00000002,           # features: reserved bit
        0x00010000,           # file format version 1.0
        0xFFFFFFFFFFFFFFFF,   # data offset: none for fixed disks
        FIXED_TIMESTAMP,
        CREATOR_APP,
        0x00010000,           # creator version
        CREATOR_HOST_OS,
        size,                 # original size
        size,                 # current size
        cylinders, heads, sectors_per_track,
        2,                    # disk type: fixed
    )
    footer[64:68] = b"\x00\x00\x00\x00"  # checksum is computed over a zeroed field
    footer[68:84] = FIXED_UUID
    footer[84] = 0  # not in saved state
    struct.pack_into(">I", footer, 64, (~sum(footer)) & 0xFFFFFFFF)
    return bytes(footer)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("image", help="raw image to turn into a fixed VHD, extended in place")
    parser.add_argument("--expected-size", type=int, help="fail unless the raw image has this size")
    args = parser.parse_args()

    size = os.path.getsize(args.image)
    if args.expected_size is not None and size != args.expected_size:
        sys.exit(f"{args.image}: expected {args.expected_size} bytes, got {size}")
    if size == 0 or size % MIB:
        sys.exit(f"{args.image}: size must be a non-zero multiple of 1 MiB, got {size}")

    with open(args.image, "ab") as f:
        f.write(build_footer(size))


if __name__ == "__main__":
    main()
