import struct, glob, os, json, sys
sys.path.insert(0,'.')
from gdc_decompile import decode_variant

def read_ecfg(path):
    d=open(path,'rb').read()
    assert d[:4]==b'ECFG'
    pos=4
    (count,)=struct.unpack_from('<I',d,pos); pos+=4
    out={}
    for _ in range(count):
        (slen,)=struct.unpack_from('<I',d,pos); pos+=4
        key=d[pos:pos+slen].rstrip(b'\x00').decode(); pos+=slen
        (vlen,)=struct.unpack_from('<I',d,pos); pos+=4
        blob=d[pos:pos+vlen]; pos+=vlen
        try:
            v,_=decode_variant(blob,0)
        except NotImplementedError as e:
            (h,)=struct.unpack_from('<I',blob,0)
            v=f"<variant type {h & 0xFF} raw={blob[:32].hex()}>"
        out[key]=v
    return out

print("################ project.binary (ProjectSettings) ################")
for k,v in read_ecfg('extracted/project.binary').items():
    print(f"  {k} = {v}")

print()
print("################ sprite dimensions (.ctex) ################")
rows=[]
for p in sorted(glob.glob('extracted/.godot/imported/*.ctex')):
    d=open(p,'rb').read()
    magic=d[:4]
    ver,w,h,df=struct.unpack_from('<IIII',d,4)
    name=os.path.basename(p).split('.png-')[0]
    # embedded image format detection
    fmt='?'
    if b'\x89PNG' in d[:64]: fmt='PNG'
    elif b'WEBP' in d[:80] or b'RIFF' in d[:80]: fmt='WebP'
    rows.append((name,w,h,df,fmt,len(d)))
for name,w,h,df,fmt,sz in rows:
    print(f"  {name:<16} {w:>3}x{h:<3}  df={df:#010x} embed={fmt} filesize={sz}")

print()
print("################ audio imports ################")
for p in sorted(glob.glob('extracted/assets/audio/*.import')):
    txt=open(p).read()
    name=os.path.basename(p).replace('.wav.import','')
    keys={}
    for line in txt.splitlines():
        if '=' in line and not line.startswith('['):
            k,v=line.split('=',1); keys[k.strip()]=v.strip()
    print(f"  {name:<8} {keys}")

print()
print("################ .sample resource sizes ################")
for p in sorted(glob.glob('extracted/.godot/imported/*.sample')):
    print(f"  {os.path.basename(p).split('.wav-')[0]:<8} {os.path.getsize(p)} bytes")

print()
print("################ font imports ################")
for p in sorted(glob.glob('extracted/assets/fonts/*.import')):
    print(f"  {os.path.basename(p)}: {open(p).read().strip()[:200]!r}")
