#!/usr/bin/env python3
"""GDPC 재패커 — `unpack.py`의 역연산.

Godot 4.7의 pack_format_version=4 레이아웃을 그대로 재현한다.

    헤더 96B → 16B 정렬 패딩 → 파일 데이터(각 16B 정렬) → 디렉터리(EOF까지)
    엔트리 오프셋은 flags&2(REL_FILEBASE)이므로 `file_base`(112) 기준 상대값이다.
    경로 길이 필드는 4바이트 배수로 올린 값이고 남는 자리는 NUL이다.

정확성 근거: 원본 pck를 그대로 재패킹하면 **바이트 단위로 동일**하다(`--verify`).
이 성질이 깨지면 아래 상수나 정렬 규칙이 틀린 것이므로 출력물을 믿지 말아야 한다.

용도: `scripts/*.gdc` + `*.gd.remap` 쌍을 **평문 `.gd`** 로 교체한다. Godot의
GDScript 로더는 확장자로 소스/바이너리 토큰을 구분하므로(`.gd`는 파서, `.gdc`는
토큰 버퍼), remap을 지우고 같은 경로에 평문을 넣으면 그대로 컴파일된다.
`.godot/global_script_class_cache.cfg`가 class_name을 `res://scripts/<n>.gd`에
묶어 두므로 **경로를 바꾸지 말 것** — 다른 경로에 같은 class_name을 두면
"hides a global script class"로 파싱이 실패한다.

사용법:
    python3 tools/pack.py --verify                        # 왕복 동일성 검사만
    python3 tools/pack.py -o out.pck --text scripts/game.gd=patched/game.gd ...
"""
import argparse
import hashlib
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SRC_PCK = os.path.join(ROOT, "_dl", "index.pck")
ALIGN = 16


def parse(pck: bytes):
    if pck[:4] != b"GDPC":
        sys.exit("GDPC 매직이 아니다")
    ver, vmaj, vmin, vpat = struct.unpack_from("<4I", pck, 4)
    flags, = struct.unpack_from("<I", pck, 20)
    file_base, = struct.unpack_from("<Q", pck, 24)
    reserved = struct.unpack_from("<16I", pck, 32)
    dir_off = reserved[0] | (reserved[1] << 32)

    pos = dir_off
    count, = struct.unpack_from("<I", pck, pos)
    pos += 4
    entries = []
    for _ in range(count):
        plen, = struct.unpack_from("<I", pck, pos)
        pos += 4
        raw_path = pck[pos:pos + plen]
        pos += plen
        off, size = struct.unpack_from("<QQ", pck, pos)
        pos += 16
        md5 = pck[pos:pos + 16]
        pos += 16
        eflags, = struct.unpack_from("<I", pck, pos)
        pos += 4
        base = file_base if flags & 2 else 0
        entries.append({
            "path": raw_path.rstrip(b"\0").decode("utf-8"),
            "data": pck[off + base:off + base + size],
            "md5": md5,
            "flags": eflags,
            "off": off,          # 원본 데이터 배치 순서 — 디렉터리 순서와 다르다
        })
    head = {"ver": ver, "vmaj": vmaj, "vmin": vmin, "vpat": vpat,
            "flags": flags, "file_base": file_base}
    return head, entries


def build(head, entries) -> bytes:
    file_base = head["file_base"]
    out = bytearray()
    out += b"GDPC"
    out += struct.pack("<4I", head["ver"], head["vmaj"], head["vmin"], head["vpat"])
    out += struct.pack("<I", head["flags"])
    out += struct.pack("<Q", file_base)
    reserved_at = len(out)
    out += b"\0" * 64
    assert len(out) == 96, len(out)
    out += b"\0" * (file_base - len(out))          # 헤더 뒤 정렬 패딩

    # 데이터는 원본 오프셋 순서로, 디렉터리는 원본 엔트리 순서로 쓴다 — 둘은 다르다
    placed = {}
    for e in sorted(entries, key=lambda x: x.get("off", 1 << 62)):
        if len(out) % ALIGN:
            out += b"\0" * (ALIGN - len(out) % ALIGN)
        placed[id(e)] = (len(out) - file_base, len(e["data"]))
        out += e["data"]

    if len(out) % ALIGN:
        out += b"\0" * (ALIGN - len(out) % ALIGN)
    dir_off = len(out)
    out += struct.pack("<I", len(entries))
    for e in entries:
        off, size = placed[id(e)]
        p = e["path"].encode("utf-8")
        pad = (-len(p)) % 4
        out += struct.pack("<I", len(p) + pad) + p + b"\0" * pad
        out += struct.pack("<QQ", off, size)
        out += hashlib.md5(e["data"]).digest()
        out += struct.pack("<I", e["flags"])

    struct.pack_into("<II", out, reserved_at, dir_off & 0xFFFFFFFF, dir_off >> 32)
    return bytes(out)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("-i", "--input", default=SRC_PCK)
    ap.add_argument("-o", "--output")
    ap.add_argument("--verify", action="store_true",
                    help="원본을 그대로 재패킹해 바이트 동일성만 검사한다")
    ap.add_argument("--text", action="append", default=[],
                    metavar="RESPATH=FILE",
                    help="`scripts/game.gd=patch/game.gd` 형태. 해당 평문을 그 경로에 "
                         "넣고 `<n>.gdc`와 `<n>.gd.remap` 엔트리를 제거한다")
    args = ap.parse_args()

    src = open(args.input, "rb").read()
    head, entries = parse(src)

    if args.verify:
        rebuilt = build(head, entries)
        same = rebuilt == src
        print(f"엔트리 {len(entries)}개, 재패킹 {len(rebuilt)}B / 원본 {len(src)}B — "
              f"{'바이트 동일 ✓' if same else '불일치 ✗'}")
        sys.exit(0 if same else 1)

    if not args.output:
        sys.exit("--output 이 필요하다")

    by_path = {e["path"]: e for e in entries}
    drop = set()
    for spec in args.text:
        res_rel, disk = spec.split("=", 1)
        # pack_format_version 4는 경로를 `res://` 없이 저장한다
        res_path = res_rel[len("res://"):] if res_rel.startswith("res://") else res_rel
        stem = res_path[:-3] if res_path.endswith(".gd") else res_path
        gdc, remap = stem + ".gdc", res_path + ".remap"
        if gdc not in by_path:
            sys.exit(f"{gdc} 엔트리가 없다 — 경로를 확인하라")
        drop.add(gdc)
        drop.add(remap)
        data = open(disk, "rb").read()
        # .gdc 자리에 평문 엔트리를 끼워 넣어 파일 순서를 원본과 비슷하게 유지한다
        by_path[res_path] = {"path": res_path, "data": data, "md5": b"", "flags": 0}
        print(f"  {res_path} <- {disk} ({len(data)}B, {gdc} {len(by_path[gdc]['data'])}B 대체)")

    new_entries = []
    for e in entries:
        if e["path"] in drop:
            if e["path"].endswith(".gdc"):
                new_entries.append(by_path[e["path"][:-4] + ".gd"])
            continue
        new_entries.append(e)

    out = build(head, new_entries)
    open(args.output, "wb").write(out)
    print(f"{args.output}: 엔트리 {len(new_entries)}개, {len(out)}B "
          f"(원본 {len(src)}B, {len(out) - len(src):+d}B)")


if __name__ == "__main__":
    main()
