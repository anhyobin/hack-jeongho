import struct, os, sys

d = open('index.pck','rb').read()
assert d[:4] == b'GDPC'
pos = 4
def u32():
    global pos
    v = struct.unpack_from('<I', d, pos)[0]; pos += 4; return v
def u64():
    global pos
    v = struct.unpack_from('<Q', d, pos)[0]; pos += 8; return v

ver = u32(); vmaj = u32(); vmin = u32(); vpat = u32()
flags = u32(); file_base = u64()
reserved = [u32() for _ in range(16)]
print(f"pack_format_version={ver} engine={vmaj}.{vmin}.{vpat} flags={flags} file_base={file_base}")
print("reserved[0:4]=", reserved[:4])

# directory offset stored in reserved[0]/[1] as u64
dir_off = reserved[0] | (reserved[1] << 32)
print("dir_off=", hex(dir_off))
pos = dir_off
count = u32()
print("file_count=", count)

entries = []
for i in range(count):
    plen = u32()
    path = d[pos:pos+plen]; pos += plen
    path = path.rstrip(b'\x00').decode('utf-8')
    off = u64(); size = u64()
    md5 = d[pos:pos+16]; pos += 16
    fflags = u32()
    entries.append((path, off, size, md5.hex(), fflags))

base = file_base if flags & 2 else 0
outdir = 'extracted'
manifest = []
for path, off, size, md5, fflags in entries:
    real = off + base
    data = d[real:real+size]
    rel = path.replace('res://','')
    dest = os.path.join(outdir, rel)
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    open(dest,'wb').write(data)
    manifest.append((path, real, size, fflags, data[:4]))

for m in sorted(manifest):
    print(f"{m[2]:>9}  flags={m[3]}  magic={m[4]!r:12}  {m[0]}")
