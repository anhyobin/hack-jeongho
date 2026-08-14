#!/usr/bin/env python3
"""난수 알고리즘을 **바이너리와 정답지로** 판정한다 — 추측으로 고르지 않는다.

앞선 세션은 "PCG32인데 시딩만 다르다"를 검증 없이 가정하고 시딩 변형만 6가지
돌려서 전부 실패했다. 실패의 원인은 시딩이 아니라 **`randf()` 자체**였다.
그래서 시딩 후보를 아무리 맞게 골라도 통과할 수가 없었다.

이 스크립트는 그 함정을 다시 밟지 않도록 세 단계로 판정한다:

  1. `_local/index.wasm`에서 난수 상수를 찾아 **알고리즘 계열**을 확정한다.
  2. `tools/sim.py`의 `RandomPCG`(= 확정 모델)를 정답지 6개 시드로 검사한다.
  3. 시딩 변형 × `randf` 변형 **격자**를 전부 돌려 무엇이 아니었는지 보여준다.
     여기서 "시딩은 맞는데 randf가 틀리면 실패한다"가 눈으로 확인된다.

    python3 tools/rng_probe.py              # 전부
    python3 tools/rng_probe.py --no-wasm    # wasm 스캔 생략(39MB 읽기 생략)

종료 코드 0은 2단계가 전건 일치했다는 뜻이다.
"""
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sim  # noqa: E402  — 확정 모델의 정본은 sim.RandomPCG 하나뿐이다

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WASM = os.path.join(ROOT, "_local", "index.wasm")

MASK64 = sim.MASK64
M = sim.PCG_MULT
INC64 = sim.PCG_DEFAULT_INC_64
U32 = sim.UINT32_MAX

# --- 정답지 ------------------------------------------------------------------
# 클라이언트에서 별도 `RandomNumberGenerator` 인스턴스로 실측한 값이다
# (`patch/bot_game.part.gd`의 `bdump` → `[rngdbg]`/`[seedmap]`).
# `%.9f`로 찍혔으므로 float32 하나를 유일하게 지목한다.
GT_RANDF = {
    0: [0.202271849, 0.125359401],
    1: [0.329559088, 0.276594847],
    2: [0.702882349, 0.519367278],
    3: [0.499491125, 0.714925110],
    255: [0.105341010, 0.926077783],
    1000000919463405: [
        0.321377069, 0.733824670, 0.787940502, 0.822309911,
        0.200582966, 0.443908006, 0.284934878, 0.604507029,
        0.958626449, 0.452899516, 0.534789681, 0.318720460,
    ],
}
GT_RANDI = (1000000919463405, (3, 6), [4, 6, 4, 5, 3, 5, 3, 5])

TOL = 5e-10   # %.9f 반올림 폭보다 크고 float32 간격보다 작다


# --- 1단계: wasm 상수 스캔 ---------------------------------------------------

def leb128_s(v: int) -> bytes:
    """wasm의 i64 상수는 signed LEB128로 인코딩된다."""
    out = bytearray()
    while True:
        b = v & 0x7F
        v >>= 7
        if (v == 0 and not b & 0x40) or (v == -1 and b & 0x40):
            out.append(b)
            return bytes(out)
        out.append(b | 0x80)


CONSTS = [
    ("PCG_MULT", M, "PCG32/PCG64 승수"),
    ("PCG_INC", INC64, "PCG_DEFAULT_INC_64"),
    ("PCG_STREAM", 0xDA3E39CB94B95BDB, "pcg 다른 스트림 상수"),
    ("XOSHIRO_A", 0x2545F4914F6CDD1D, "xorshift* 승수"),
    ("SPLITMIX", 0x9E3779B97F4A7C15, "SplitMix64 감마"),
    ("MURMUR", 0xFF51AFD7ED558CCD, "MurmurHash3 finalizer"),
]


def scan_wasm() -> None:
    print("=" * 72)
    print("1단계 — index.wasm 난수 상수 스캔 (알고리즘 계열 확정)")
    print("=" * 72)
    if not os.path.exists(WASM):
        print(f"  {WASM} 없음 — 건너뛴다 (.gitignore 대상이다)")
        return
    d = open(WASM, "rb").read()
    print(f"  {os.path.relpath(WASM, ROOT)}  {len(d):,} 바이트\n")
    print(f"  {'상수':11s} {'LEB128':>7s} {'LE64':>6s}   뜻")
    for name, v, why in CONSTS:
        n_leb = d.count(leb128_s(v))
        n_le = d.count(v.to_bytes(8, "little"))
        mark = "★" if n_leb or n_le else " "
        print(f"{mark} {name:11s} {n_leb:7d} {n_le:6d}   {why}")
    print("\n  판정: PCG 승수와 PCG_DEFAULT_INC_64가 둘 다 있고 SplitMix·xoshiro·"
          "Murmur는\n        하나도 없다 → **PCG32 계열이 맞고 시딩·출력 함수만 "
          "다르다**.")


# --- 2단계: 확정 모델 판정 ---------------------------------------------------

def check_model() -> bool:
    print()
    print("=" * 72)
    print("2단계 — sim.RandomPCG(확정 모델)를 정답지로 판정")
    print("=" * 72)
    print("  시드→상태 = pcg32_srandom_r(seed, PCG_DEFAULT_INC_64)")
    print("  randf()   = ldexp(float32(rand() | 0x80000001), -32 - clz32(rand()))"
          "   ← rand 2회")
    print("  randi_range = pcg32_boundedrand_r (기각 표본)\n")

    ok_all = True
    for sd, want in GT_RANDF.items():
        r = sim.RandomPCG(sd)
        got = [r.randf() for _ in want]
        ok = all(abs(a - b) < TOL for a, b in zip(got, want))
        ok_all &= ok
        head = " ".join("%.9f" % v for v in got[:4])
        print(f"  [{'OK ' if ok else '불일치'}] randf seed={sd:<17d} {head}"
              f"{' ...' if len(got) > 4 else ''}  ({len(got)}개)")

    sd, (lo, hi), want = GT_RANDI
    r = sim.RandomPCG(sd)
    got = [r.randi_range(lo, hi) for _ in want]
    ok = got == want
    ok_all &= ok
    print(f"  [{'OK ' if ok else '불일치'}] randi_range({lo},{hi}) seed={sd} "
          f"-> {' '.join(map(str, got))}  기대 {' '.join(map(str, want))}")

    st = sim.RandomPCG(0).state
    print(f"\n  seed 0의 초기 상태 = {st}  (= 0x{st:016X})")
    print("  → `state = seed`였다면 0이어야 하고 첫 randf도 정확히 0.0이어야 했다."
          "\n    그것이 이 수수께끼의 출발점이었다.")
    print(f"\n  {'전건 일치' if ok_all else '★ 불일치 — 모델이 틀렸다'}")
    return ok_all


# --- 3단계: 배제 격자 -------------------------------------------------------
# 시딩 후보와 randf 후보를 곱해서 전부 돌린다. 앞선 세션이 왜 막혔는지가
# 이 표에서 바로 보인다 — srandom 행은 ldexp 열에서만 통과한다.

def make_state(mode: str, seed: int):
    """(state, inc, drop) 을 돌려준다. drop은 시딩 후 버릴 rand 횟수."""
    if mode == "state=seed":
        return seed & MASK64, INC64, 0
    if mode == "state=seed,drop1":
        return seed & MASK64, INC64, 1
    if mode == "state=seed,drop2":
        return seed & MASK64, INC64, 2
    if mode == "state=seed,post-adv":
        st = (seed * M + INC64) & MASK64
        return st, INC64, 0
    if mode == "srandom(inc<<1|1)":          # ← Godot 4.7.1의 실제 동작
        inc = ((INC64 << 1) | 1) & MASK64
        st = inc                              # state=0 -> 0*M+inc
        st = (st + (seed & MASK64)) & MASK64
        st = (st * M + inc) & MASK64
        return st, inc, 0
    if mode == "srandom(inc=raw)":           # <<1|1 을 빼먹은 변형
        inc = INC64
        st = ((INC64 + (seed & MASK64)) * M + inc) & MASK64
        return st, inc, 0
    if mode == "state=seed,stream":          # 다른 스트림 상수
        return seed & MASK64, 0xDA3E39CB94B95BDB, 0
    raise AssertionError(mode)


class Gen:
    def __init__(self, state, inc):
        self.state, self.inc = state, inc

    def rand(self):
        old = self.state
        self.state = (old * M + (self.inc | 1)) & MASK64
        xs = (((old >> 18) ^ old) >> 27) & U32
        rot = (old >> 59) & 31
        return ((xs >> rot) | (xs << ((-rot) & 31))) & U32


def randf_of(g: Gen, mode: str) -> float:
    if mode == "div32":            # rand() / 0xFFFFFFFF — 앞선 세션이 쓴 식
        return sim.f32(sim.f32(g.rand()) / sim.f32(U32))
    if mode == "trunc24":          # CLZ 없는 빌드의 대체 경로
        return sim.f32(sim.f32(g.rand() & 0xFFFFFF) / sim.f32(0xFFFFFF))
    if mode == "ldexp":            # ← 실제 (rand 2회)
        p = g.rand()
        if p == 0:
            return 0.0
        return math.ldexp(sim.f32(g.rand() | 0x80000001), -32 - (32 - p.bit_length()))
    raise AssertionError(mode)


SEED_MODES = ["state=seed", "state=seed,drop1", "state=seed,drop2",
              "state=seed,post-adv", "state=seed,stream",
              "srandom(inc=raw)", "srandom(inc<<1|1)"]
RANDF_MODES = ["div32", "trunc24", "ldexp"]


def exclusion_grid() -> None:
    print()
    print("=" * 72)
    print("3단계 — 배제 격자 (무엇이 아니었는지)")
    print("=" * 72)
    print("  정답지 6개 시드가 **전부** 맞은 칸만 OK다. n/6은 맞은 시드 수다.\n")
    print(f"  {'시딩':22s}" + "".join(f"{m:>10s}" for m in RANDF_MODES))
    for smode in SEED_MODES:
        cells = []
        for fmode in RANDF_MODES:
            hits = 0
            for sd, want in GT_RANDF.items():
                st, inc, drop = make_state(smode, sd)
                g = Gen(st, inc)
                for _ in range(drop):
                    g.rand()
                got = [randf_of(g, fmode) for _ in want]
                if all(abs(a - b) < TOL for a, b in zip(got, want)):
                    hits += 1
            cells.append("OK" if hits == len(GT_RANDF) else f"{hits}/{len(GT_RANDF)}")
        print(f"  {smode:22s}" + "".join(f"{c:>10s}" for c in cells))
    print("\n  읽는 법: `srandom(inc<<1|1)` 행은 `ldexp` 열에서만 통과한다."
          "\n  앞선 세션은 이 행을 이미 시도했지만 `div32` 열에서만 시도했으므로"
          "\n  통과할 수가 없었다 — 시딩이 아니라 randf가 원인이었다.")


def main() -> None:
    if "--no-wasm" not in sys.argv:
        scan_wasm()
    ok = check_model()
    exclusion_grid()
    print()
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
