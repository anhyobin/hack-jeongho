// 상태: **미완성 (보정 필요)**. 2026-08-14 첫 실측에서 3행에서 차에 치였고,
// 다음 행 판정이 road 363 / grass 11로 쏠렸다 — 읽는 y가 실제 다음 행과 맞지 않는다는 뜻이다.
// 남은 작업:
//   1) 스트립 y 보정: 알려진 화면과 대조해 PLAYER_Y(=408 가정)와 +20 오프셋을 실측으로 맞춘다.
//   2) 게임오버 감지: 중앙에 패널이 뜨면 루프를 멈춘다(현재는 70초간 패널을 두드렸다).
//   3) 차량 속도 추정: 한 프레임만 보면 늦다. 두 프레임을 읽어 속도를 구하고 도착 시점을 예측한다.
//   4) 좌우 이동: 막힌 열에서 옆으로 피하는 수를 넣는다(현재는 전진/대기만).
// 강제 스크롤 상한이 0.62행/초라 초당 1행이면 충분하므로, 판정이 맞으면 속도는 문제가 아니다.
// 고라니 피하기 자동 조종 — 캔버스 프레임버퍼를 직접 읽어 다음 행의 안전 여부를 판정한다.
// 서버가 trace를 시드로 재현해 rows를 검증하므로(docs/leaderboard-api.md §7),
// 점수는 "실제로 넘은 행 수"로만 벌 수 있다. 이 스크립트가 그 행을 번다.
//
// 기하: CELL=64, COLS=9, CAM_ANCHOR=600, cam_row≈max_row-3 이므로 플레이어는 게임 y≈408 고정.
// 캔버스는 640x960을 700x1000에 레터박스 -> scale=1.0417, x오프셋 16.5.
(() => {
  const cv = document.querySelector('canvas');
  const gl = cv.getContext('webgl2') || cv.getContext('webgl');
  const SC = Math.min(cv.width / 640, cv.height / 960);
  const OX = (cv.width - 640 * SC) / 2, OY = (cv.height - 960 * SC) / 2;
  const gx = x => Math.round(OX + x * SC);
  const gy = y => Math.round(cv.height - (OY + y * SC));   // readPixels는 좌하원점
  const PLAYER_Y = 408, CELL = 64;

  const frame = () => new Promise(r => requestAnimationFrame(() => r()));
  function strip(gameY, x0, x1) {                 // 가로 한 줄 픽셀
    const w = Math.max(1, gx(x1) - gx(x0));
    const buf = new Uint8Array(w * 4);
    gl.readPixels(gx(x0), gy(gameY), w, 1, gl.RGBA, gl.UNSIGNED_BYTE, buf);
    const out = [];
    for (let i = 0; i < w; i++) out.push([buf[i * 4], buf[i * 4 + 1], buf[i * 4 + 2]]);
    return out;
  }
  const dark = p => p[0] < 95 && p[1] < 95 && p[2] < 105;            // 아스팔트
  const blue = p => p[2] > p[0] + 25 && p[2] > 90;                   // 강
  const green = p => p[1] > p[0] + 12 && p[1] > p[2] + 12;           // 풀
  const bright = p => (p[0] + p[1] + p[2]) > 420;                    // 차/기차/통나무 하이라이트

  function classify(rowsAhead) {
    const y = PLAYER_Y - rowsAhead * CELL + 20;
    const s = strip(y, 4, 636);
    let d = 0, b = 0, g = 0;
    for (const p of s) { if (dark(p)) d++; else if (blue(p)) b++; else if (green(p)) g++; }
    const n = s.length;
    const kind = d / n > 0.45 ? 'road' : b / n > 0.35 ? 'river' : g / n > 0.4 ? 'grass' : 'other';
    return {kind, strip: s, n};
  }
  // 플레이어 열 주변이 비었는지 (차/기차 회피)
  function laneClear(rowsAhead, halfWidth) {
    const y = PLAYER_Y - rowsAhead * CELL + 20;
    const px = window.__ap.px;
    const s = strip(y, Math.max(4, px - halfWidth), Math.min(636, px + halfWidth));
    let hit = 0;
    for (const p of s) if (bright(p) || (p[0] > 120 && p[1] < 90 && p[2] < 90)) hit++;
    return hit / s.length < 0.06;
  }
  function logUnder(rowsAhead) {                  // 강: 통나무(갈색)가 있는지
    const y = PLAYER_Y - rowsAhead * CELL + 20;
    const px = window.__ap.px;
    const s = strip(y, Math.max(4, px - 26), Math.min(636, px + 26));
    let brown = 0;
    for (const p of s) if (p[0] > 95 && p[0] < 205 && p[1] > 60 && p[1] < 150 && p[2] < 110) brown++;
    return brown / s.length > 0.35;
  }
  const tap = (x, y) => {
    const o = {clientX: x, clientY: y, bubbles: true, cancelable: true,
               button: 0, buttons: 1, pointerId: 1, pointerType: 'mouse', isPrimary: true};
    cv.dispatchEvent(new PointerEvent('pointerdown', o));
    cv.dispatchEvent(new MouseEvent('mousedown', o));
    const u = {...o, buttons: 0};
    cv.dispatchEvent(new PointerEvent('pointerup', u));
    cv.dispatchEvent(new MouseEvent('mouseup', u));
    cv.dispatchEvent(new MouseEvent('click', u));
  };
  const key = k => {
    const o = {key: k, code: k, bubbles: true, cancelable: true};
    window.dispatchEvent(new KeyboardEvent('keydown', o));
    window.dispatchEvent(new KeyboardEvent('keyup', o));
  };
  window.__ap = {px: 320, hops: 0, waits: 0, stop: false, kinds: {}, log: []};

  window.__apRun = async (maxSeconds) => {
    const t0 = Date.now();
    const A = window.__ap;
    while (!A.stop && Date.now() - t0 < maxSeconds * 1000) {
      await frame();
      const c = classify(1);
      A.kinds[c.kind] = (A.kinds[c.kind] || 0) + 1;
      let go = false;
      if (c.kind === 'grass') go = laneClear(1, 22);
      else if (c.kind === 'road') go = laneClear(1, 150);
      else if (c.kind === 'river') go = logUnder(1);
      else go = laneClear(1, 170);
      if (go) { tap(cv.width / 2, cv.height / 2); A.hops++; await new Promise(r => setTimeout(r, 190)); }
      else { A.waits++; await new Promise(r => setTimeout(r, 70)); }
    }
    return {hops: A.hops, waits: A.waits, kinds: A.kinds, seconds: ((Date.now() - t0) / 1000).toFixed(1)};
  };
  return 'autopilot loaded';
})()
