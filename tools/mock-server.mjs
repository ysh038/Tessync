// iPhone 없이 웹 플레이어를 개발/테스트하기 위한 가짜 Tessync 서버.
// 실제 방송 익스텐션과 같은 포트와 프로토콜을 쓴다.
//
//   node tools/mock-server.mjs        (ffmpeg 필요: 테스트 프레임 생성용)
//   브라우저에서 http://localhost:8080 열기
//
// 장애 흉내: 아래 주소를 열면 해당 상황을 만든다.
//   /mock/kill              소켓을 close 없이 끊는다 (Wi-Fi 끊김)
//   /mock/silence?ms=5000   TCP는 살려둔 채 아무것도 보내지 않는다 (멈춘 연결)
//   /mock/bye               방송 종료 메시지를 보내고 닫는다
//   /mock/orientation?o=6   프레임 방향 값을 바꾼다
//   /mock/state             현재 상태(JSON)

import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, readdirSync, readFileSync } from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.dirname(fileURLToPath(import.meta.url));
const webRoot = path.join(root, '..', 'web');
const framesDir = path.join(root, '.frames');
const HTTP_PORT = Number(process.env.HTTP_PORT || 8080);
const WS_PORT = Number(process.env.WS_PORT || 8081);
const FPS = Number(process.env.FPS || 30);

function loadFrames() {
  if (!existsSync(framesDir) || readdirSync(framesDir).length === 0) {
    mkdirSync(framesDir, { recursive: true });
    // 세로 아이폰 화면 비율. 위쪽 1/4은 빨간 띠라서 회전 방향을 눈으로 확인할 수 있다.
    const result = spawnSync('ffmpeg', [
      '-loglevel', 'error', '-f', 'lavfi', '-i', `testsrc=size=590x1280:rate=${FPS}`,
      '-vf', 'drawbox=x=0:y=0:w=iw:h=ih/4:color=red:t=fill', '-frames:v', String(FPS * 2), '-q:v', '6',
      path.join(framesDir, '%03d.jpg'),
    ], { stdio: 'inherit' });
    if (result.status !== 0) throw new Error('ffmpeg로 테스트 프레임을 만들지 못했습니다');
  }
  return readdirSync(framesDir).sort().map((name) => readFileSync(path.join(framesDir, name)));
}

const frames = loadFrames();
const state = { orientation: 1, silentUntil: 0, refuseUntil: 0, connections: 0, clients: new Set(), reports: [] };

// MARK: HTTP

const contentTypes = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8' };

http.createServer((req, res) => {
  const url = new URL(req.url, 'http://localhost');
  if (url.pathname.startsWith('/mock/')) return handleMock(url, res);
  if (req.method === 'POST' && url.pathname === '/report') {
    let body = '';
    req.on('data', (chunk) => { body += chunk; });
    req.on('end', () => { state.reports.push(body); console.log('probe report', body.slice(0, 300)); res.writeHead(204).end(); });
    return;
  }
  if (url.pathname === '/log') {
    res.writeHead(200, { 'Content-Type': 'text/plain; charset=utf-8' });
    return res.end(`mock log\nconnections=${state.connections}\n${state.reports.join('\n')}`);
  }
  const file = { '/': 'index.html', '/index.html': 'index.html', '/player.js': 'player.js', '/probe': 'probe.html', '/probe.html': 'probe.html' }[url.pathname];
  if (!file) return res.writeHead(404).end('not found');
  res.writeHead(200, { 'Content-Type': contentTypes[path.extname(file)], 'Cache-Control': 'no-store' });
  res.end(readFileSync(path.join(webRoot, file)));
}).listen(HTTP_PORT, () => console.log(`player: http://localhost:${HTTP_PORT}`));

function handleMock(url, res) {
  switch (url.pathname) {
    case '/mock/kill':
      for (const socket of state.clients) socket.destroy();
      break;
    case '/mock/silence':
      state.silentUntil = Date.now() + Number(url.searchParams.get('ms') || 5000);
      break;
    case '/mock/bye':
      // 실제로는 방송이 끝나면 서버도 사라진다. 3초 동안 접속을 거부해 그 상황을 흉내 낸다.
      state.refuseUntil = Date.now() + 3000;
      for (const socket of state.clients) { sendFrame(socket, 0x1, Buffer.from(JSON.stringify({ t: 'bye', reason: 'mock' }))); socket.end(); }
      break;
    case '/mock/orientation':
      state.orientation = Number(url.searchParams.get('o') || 1);
      break;
  }
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ orientation: state.orientation, connections: state.connections, clients: state.clients.size, reports: state.reports.length }));
}

// MARK: WebSocket (서버 → 클라이언트 프레임만 필요한 최소 구현)

const wsServer = http.createServer((req, res) => res.writeHead(426).end());
wsServer.on('upgrade', (req, socket) => {
  if (Date.now() < state.refuseUntil) return socket.destroy();
  const key = req.headers['sec-websocket-key'];
  const accept = createHash('sha1').update(key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
  socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
  socket.setNoDelay(true);
  state.connections++;
  state.clients.add(socket);
  console.log(`client connected (#${state.connections})`);
  socket.on('data', (data) => logClientText(data));
  socket.on('close', () => state.clients.delete(socket));
  socket.on('error', () => state.clients.delete(socket));
});
wsServer.listen(WS_PORT, () => console.log(`stream: ws://localhost:${WS_PORT}`));

function sendFrame(socket, opcode, payload) {
  let header;
  if (payload.length < 126) {
    header = Buffer.from([0x80 | opcode, payload.length]);
  } else if (payload.length < 65536) {
    header = Buffer.alloc(4);
    header[0] = 0x80 | opcode; header[1] = 126; header.writeUInt16BE(payload.length, 2);
  } else {
    header = Buffer.alloc(10);
    header[0] = 0x80 | opcode; header[1] = 127; header.writeBigUInt64BE(BigInt(payload.length), 2);
  }
  socket.write(Buffer.concat([header, payload]));
}

// 클라이언트 프레임은 마스킹되어 온다. 짧은 텍스트(hello)만 로그로 남긴다.
function logClientText(data) {
  if (data.length < 6 || (data[0] & 0x0f) !== 0x1) return;
  let length = data[1] & 0x7f;
  let offset = 2;
  if (length === 126) { length = data.readUInt16BE(2); offset = 4; }
  if (length > 4096 || data.length < offset + 4 + length) return;
  const mask = data.subarray(offset, offset + 4);
  const text = Buffer.from(data.subarray(offset + 4, offset + 4 + length).map((byte, i) => byte ^ mask[i % 4]));
  console.log('client says', text.toString());
}

let frameIndex = 0;
setInterval(() => {
  if (Date.now() < state.silentUntil) return;
  const jpeg = frames[frameIndex++ % frames.length];
  const packet = Buffer.concat([Buffer.from([1, state.orientation]), jpeg]);
  for (const socket of state.clients) sendFrame(socket, 0x2, packet);
}, 1000 / FPS);

let seq = 0;
setInterval(() => {
  if (Date.now() < state.silentUntil) return;
  const heartbeat = Buffer.from(JSON.stringify({ t: 'hb', seq: ++seq, lvl: 0, fps: FPS, mem: 20 }));
  for (const socket of state.clients) sendFrame(socket, 0x1, heartbeat);
}, 1000);
