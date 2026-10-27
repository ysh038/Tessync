// 웹 플레이어 끊김 복구 테스트. mock-server를 띄운 상태에서 실행한다.
//   node tools/mock-server.mjs &
//   node tools/player-test.mjs
import { createRequire } from 'node:module';

// require는 NODE_PATH를 따르므로 전역 설치된 playwright도 찾는다.
const { chromium } = createRequire(import.meta.url)('playwright');

const BASE = process.env.BASE || 'http://localhost:8080';
const failures = [];

function check(name, condition, detail = '') {
  console.log(`${condition ? 'PASS' : 'FAIL'} ${name}${detail ? ` (${detail})` : ''}`);
  if (!condition) failures.push(name);
}

const mock = async (path) => (await fetch(BASE + path)).json();
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
page.on('pageerror', (error) => failures.push(`page error: ${error.message}`));

const overlayHidden = () => page.evaluate(() => document.getElementById('overlay').classList.contains('hidden'));
const overlayText = () => page.evaluate(() => document.getElementById('status').textContent);
// 캔버스 중앙 픽셀. 테스트 프레임은 계속 바뀌므로 진행 여부 확인에 쓴다.
const frameCount = () => page.evaluate(() => {
  const canvas = document.getElementById('screen');
  return canvas.getContext('2d').getImageData(0, 0, canvas.width, canvas.height).data.reduce((sum, v, i) => (i % 4097 === 0 ? sum + v : sum), 0);
});

async function waitFor(predicate, timeoutMs) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    if (await predicate()) return Date.now() - start;
    await sleep(100);
  }
  return -1;
}

async function framesAdvancing() {
  const a = await frameCount();
  await sleep(300);
  return a !== (await frameCount());
}

await page.goto(BASE);

let ms = await waitFor(overlayHidden, 5000);
check('첫 화면 표시', ms >= 0, `${ms}ms`);
check('프레임 진행', await framesAdvancing());

// 1. 소켓이 close 없이 끊김 (Wi-Fi 끊김)
let before = (await mock('/mock/state')).connections;
await mock('/mock/kill');
ms = await waitFor(async () => (await mock('/mock/state')).connections > before && (await framesAdvancing()), 5000);
check('강제 끊김 후 자동 복구', ms >= 0, `${ms}ms`);

// 2. TCP는 살아 있는데 아무것도 안 옴 (멈춘 연결) → 3초 뒤 버리고 재접속해야 한다
before = (await mock('/mock/state')).connections;
await mock('/mock/silence?ms=8000');
ms = await waitFor(async () => (await mock('/mock/state')).connections > before, 6000);
check('멈춘 연결 감지 후 재접속', ms >= 2500 && ms <= 5000, `${ms}ms`);
ms = await waitFor(framesAdvancing, 8000);
check('멈춤 해제 후 화면 재개', ms >= 0, `${ms}ms`);

// 3. 방송 종료 메시지 → 서버가 3초간 사라졌다가 다시 시작됨
await mock('/mock/bye');
ms = await waitFor(async () => !(await overlayHidden()) && (await overlayText()).includes('종료'), 3000);
check('방송 종료 안내 표시', ms >= 0, `overlay="${await overlayText()}"`);
ms = await waitFor(async () => (await overlayHidden()) && (await framesAdvancing()), 6000);
check('종료 후 다시 연결', ms >= 0, `${ms}ms`);

// 4. 방향: orientation 6(시계방향 90도)이면 세로 프레임이 가로로 그려지고, 위쪽 빨간 띠가 오른쪽으로 간다
await mock('/mock/orientation?o=6');
await sleep(500);
const rotated = await page.evaluate(() => {
  const canvas = document.getElementById('screen');
  const ctx = canvas.getContext('2d');
  const right = ctx.getImageData(canvas.width * 0.9, canvas.height / 2, 1, 1).data;
  const left = ctx.getImageData(canvas.width * 0.1, canvas.height / 2, 1, 1).data;
  return { right: Array.from(right), left: Array.from(left) };
});
const isRed = ([r, g, b]) => r > 180 && g < 80 && b < 80;
check('방향 회전 (빨간 띠가 오른쪽)', isRed(rotated.right) && !isRed(rotated.left), JSON.stringify(rotated));
await mock('/mock/orientation?o=1');

// 5. 장시간 메모리: 40초 동안 JS 힙이 계속 늘지 않아야 한다
const heap = () => page.evaluate(() => (performance.memory ? performance.memory.usedJSHeapSize : 0));
const client = await page.context().newCDPSession(page);
await client.send('HeapProfiler.collectGarbage');
const heapStart = await heap();
await sleep(40000);
await client.send('HeapProfiler.collectGarbage');
const heapEnd = await heap();
check('40초 후 힙 증가 5MB 미만', heapEnd - heapStart < 5 * 1024 * 1024, `${(heapStart / 1e6).toFixed(1)}MB -> ${(heapEnd / 1e6).toFixed(1)}MB`);
check('프레임 계속 진행', await framesAdvancing());

await browser.close();
if (failures.length) {
  console.log(`\n실패 ${failures.length}건: ${failures.join(', ')}`);
  process.exit(1);
}
console.log('\n모든 테스트 통과');
