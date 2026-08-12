#!/usr/bin/env python3
"""
Godot .pck extractor (pack format v4, as produced by Godot 4.7).

Format v4 differs from the widely documented v2/v3 layout: the header carries an
extra uint64 that points at the *file index*, which now lives at the end of the
archive instead of right after the header. Off-the-shelf extractors that assume
v2 read `file_count == 0` and silently produce nothing, which is exactly what
happened on the first attempt here.

    offset  size  field
    0x00    4     magic "GDPC"
    0x04    4     pack format version (4)
    0x08    12    engine version major/minor/patch
    0x14    4     pack flags (bit0 encrypted, bit1 relative file base)
    0x18    8     file_base   - all entry offsets are relative to this
    0x20    8     index_offset - absolute offset of the file index
    0x28    ...   reserved
    index:  4     file_count
            per entry: uint32 path_len, path, uint64 offset, uint64 size,
                       16-byte md5, uint32 flags

Usage:
    python3 extract_pck.py index.pck -o outdir           # everything
    python3 extract_pck.py index.pck -o outdir --only .gdc
"""
import argparse
import os
import struct


def read_index(data):
    if data[:4] != b"GDPC":
        raise ValueError("not a Godot pack file")
    version = struct.unpack_from("<I", data, 4)[0]
    major, minor, patch = struct.unpack_from("<III", data, 8)
    flags = struct.unpack_from("<I", data, 0x14)[0]
    file_base = struct.unpack_from("<Q", data, 0x18)[0]
    index_offset = struct.unpack_from("<Q", data, 0x20)[0]
    if version < 4:
        # v2/v3 keep the index immediately after the 64-byte reserved block.
        index_offset = 0x68
    p = index_offset
    count = struct.unpack_from("<I", data, p)[0]
    p += 4
    entries = []
    for _ in range(count):
        plen = struct.unpack_from("<I", data, p)[0]
        p += 4
        path = data[p:p + plen].rstrip(b"\0").decode("utf-8")
        p += plen
        offset, size = struct.unpack_from("<QQ", data, p)
        p += 16
        p += 16                                              # md5
        entry_flags = struct.unpack_from("<I", data, p)[0]
        p += 4
        entries.append({"path": path, "offset": file_base + offset,
                        "size": size, "flags": entry_flags})
    meta = {"version": version, "engine": "%d.%d.%d" % (major, minor, patch),
            "flags": flags, "file_base": file_base, "index_offset": index_offset}
    return meta, entries


def main():
    ap = argparse.ArgumentParser(description="Extract a Godot 4 .pck archive")
    ap.add_argument("pck")
    ap.add_argument("-o", "--outdir", default="pck_out")
    ap.add_argument("--only", action="append", default=[],
                    help="only extract paths containing this substring (repeatable)")
    ap.add_argument("-l", "--list", action="store_true", help="list contents and exit")
    args = ap.parse_args()

    data = open(args.pck, "rb").read()
    meta, entries = read_index(data)
    print("pack v%d, engine %s, flags 0x%x, %d files"
          % (meta["version"], meta["engine"], meta["flags"], len(entries)))
    if meta["flags"] & 1:
        raise SystemExit("archive is encrypted; a key is required")

    for e in entries:
        if args.only and not any(s in e["path"] for s in args.only):
            continue
        if args.list:
            print("%10d  %s" % (e["size"], e["path"]))
            continue
        rel = e["path"].replace("res://", "")
        dst = os.path.join(args.outdir, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with open(dst, "wb") as f:
            f.write(data[e["offset"]:e["offset"] + e["size"]])
        print("wrote %s (%d bytes)" % (dst, e["size"]))


if __name__ == "__main__":
    main()
