// Tessync 플레이어. 테슬라 내장 브라우저에서 동작한다.
// 테슬라 브라우저의 Chromium 버전을 아직 모르므로 옵셔널 체이닝 같은 최신 문법은 쓰지 않는다.
(function () {
  'use strict';

  // 앱 번들에 새 플레이어가 들어갔는지 디버그 화면에서 확인하는 용도. 플레이어를 고칠 때마다 올린다.
  var PLAYER_VERSION = '2026-10-28.1';
  var params = new URLSearchParams(location.search);
  var WS_PORT = params.get('wsPort') || '8081';
  var CONNECT_TIMEOUT_MS = 3000;
  // 서버는 1초마다 하트비트를 보낸다. 3초 동안 아무것도 안 오면 죽은 연결로 본다.
  var SILENCE_TIMEOUT_MS = 3000;
  var RECONNECT_DELAYS_MS = [0, 500, 1000];
  var OVERLAY_GRACE_MS = 1000;
  var MAX_CONSECUTIVE_DECODE_ERRORS = 60;

  var canvas = document.getElementById('screen');
  var ctx = canvas.getContext('2d', { alpha: false });
  var overlay = document.getElementById('overlay');
  var statusEl = document.getElementById('status');
  var hintEl = document.getElementById('hint');
  var panelEl = document.getElementById('panel');
  var debugEl = document.getElementById('debug');
  var fullscreenButton = document.getElementById('fullscreen');

  var ws = null;
  var wsStartedAt = 0;
  var reconnectTimer = null;
  var attempts = 0;
  var everConnected = false;
  var live = false;
  var disconnectedSince = Date.now();
  var lastMessageAt = 0;
  var lastTickAt = Date.now();
  var broadcastEnded = false;

  var pending = null;
  var decoding = false;
  var current = null;
  var currentOrientation = 1;
  var hasFrame = false;

  var stats = { frames: 0, framesInSecond: 0, fps: 0, decodeErrors: 0, consecutiveErrors: 0, drops: 0, attempts: 0 };
  var phone = {};

  // MARK: 연결

  function connect() {
    clearTimeout(reconnectTimer);
    reconnectTimer = null;
    var socket;
    try {
      socket = new WebSocket('ws://' + location.hostname + ':' + WS_PORT + '/');
    } catch (e) {
      scheduleReconnect();
      return;
    }
    socket.binaryType = 'arraybuffer';
    ws = socket;
    wsStartedAt = Date.now();

    socket.onopen = function () {
      if (ws !== socket) return;
      attempts = 0;
      everConnected = true;
      broadcastEnded = false;
      lastMessageAt = Date.now();
      socket.send(JSON.stringify({
        t: 'hello', ua: navigator.userAgent, w: window.innerWidth, h: window.innerHeight, dpr: window.devicePixelRatio
      }));
    };
    socket.onmessage = function (event) {
      if (ws !== socket) return;
      lastMessageAt = Date.now();
      // 데이터를 실제로 받기 시작해야 "살아 있는 연결"로 본다. 열리기만 하고 아무것도 안 오다 버려진 연결은 끊김으로 세지 않는다.
      live = true;
      if (typeof event.data === 'string') {
        handleText(event.data);
      } else {
        handleFrame(event.data);
      }
    };
    socket.onclose = function () {
      if (ws !== socket) return;
      ws = null;
      markDisconnected();
      scheduleReconnect();
    };
  }

  // 재접속 실패가 반복될 때마다 시각을 갱신하면 안내 문구가 영영 안 뜬다. 연결이 끊긴 순간만 기록한다.
  function markDisconnected() {
    if (!live) return;
    live = false;
    stats.drops++;
    disconnectedSince = Date.now();
  }

  // 죽은 TCP 연결은 close 핸드셰이크가 오래 걸린다. 기다리지 않고 버린 뒤 바로 새로 연결한다.
  function abandon(socket) {
    socket.onopen = socket.onmessage = socket.onclose = socket.onerror = null;
    try { socket.close(); } catch (e) { /* 이미 닫힘 */ }
    if (ws === socket) {
      ws = null;
      markDisconnected();
    }
    scheduleReconnect();
  }

  function scheduleReconnect() {
    if (reconnectTimer) return;
    var delay = attempts < RECONNECT_DELAYS_MS.length ? RECONNECT_DELAYS_MS[attempts] : 1000;
    attempts++;
    stats.attempts++;
    reconnectTimer = setTimeout(connect, delay);
  }

  function handleText(text) {
    var message;
    try { message = JSON.parse(text); } catch (e) { return; }
    if (message.t === 'hb') {
      phone = message;
    } else if (message.t === 'bye') {
      broadcastEnded = true;
    }
  }

  // MARK: 프레임

  // 패킷: [0]=1(JPEG) [1]=EXIF orientation [2...]=JPEG
  function handleFrame(buffer) {
    if (buffer.byteLength < 3 || new Uint8Array(buffer, 0, 1)[0] !== 1) return;
    // 디코딩 중에 들어온 프레임은 최신 것 하나만 남긴다. 밀린 프레임을 쌓지 않는다.
    pending = buffer;
    if (!decoding) decodeNext();
  }

  function decodeNext() {
    if (!pending) return;
    var buffer = pending;
    pending = null;
    decoding = true;
    var orientation = new Uint8Array(buffer, 1, 1)[0];
    var blob = new Blob([new Uint8Array(buffer, 2)], { type: 'image/jpeg' });
    decodeJPEG(blob).then(function (image) {
      stats.consecutiveErrors = 0;
      show(image, orientation);
    }, function () {
      stats.decodeErrors++;
      stats.consecutiveErrors++;
      if (stats.consecutiveErrors >= MAX_CONSECUTIVE_DECODE_ERRORS) location.reload();
    }).then(function () {
      decoding = false;
      if (pending) decodeNext();
    });
  }

  function decodeJPEG(blob) {
    if (window.createImageBitmap) return createImageBitmap(blob);
    return new Promise(function (resolve, reject) {
      var url = URL.createObjectURL(blob);
      var image = new Image();
      image.onload = function () { URL.revokeObjectURL(url); resolve(image); };
      image.onerror = function () { URL.revokeObjectURL(url); reject(new Error('decode')); };
      image.src = url;
    });
  }

  function show(image, orientation) {
    // 이전 비트맵은 바로 해제한다. 장시간 사용 시 메모리가 쌓이지 않게.
    if (current && current.close) current.close();
    current = image;
    currentOrientation = orientation;
    hasFrame = true;
    stats.frames++;
    stats.framesInSecond++;
    draw();
  }

  // MARK: 그리기

  function resizeCanvas() {
    var ratio = window.devicePixelRatio || 1;
    var width = Math.round(window.innerWidth * ratio);
    var height = Math.round(window.innerHeight * ratio);
    if (canvas.width !== width || canvas.height !== height) {
      canvas.width = width;
      canvas.height = height;
    }
  }

  // ReplayKit orientation 값(CGImagePropertyOrientation): 1=그대로, 3=180도.
  // 6과 8은 EXIF 표시 규칙과 반대로 돌려야 맞게 보인다(실기기 확인): 6=반시계방향 90도, 8=시계방향 90도
  function rotationFor(orientation) {
    switch (orientation) {
      case 3: case 4: return Math.PI;
      case 5: case 6: return -Math.PI / 2;
      case 7: case 8: return Math.PI / 2;
      default: return 0;
    }
  }

  // 화면에 그린 위치(캔버스 픽셀) → 방송 프레임 기준 0~1 좌표. draw()의 변환을 거꾸로 적용한다.
  function frameScale(sourceWidth, sourceHeight, sideways) {
    var shownWidth = sideways ? sourceHeight : sourceWidth;
    var shownHeight = sideways ? sourceWidth : sourceHeight;
    return Math.min(canvas.width / shownWidth, canvas.height / shownHeight);
  }

  function canvasToFrame(clientX, clientY) {
    if (!current) return null;
    var rect = canvas.getBoundingClientRect();
    var px = (clientX - rect.left) * (canvas.width / rect.width) - canvas.width / 2;
    var py = (clientY - rect.top) * (canvas.height / rect.height) - canvas.height / 2;
    var angle = rotationFor(currentOrientation);
    var scale = frameScale(current.width, current.height, angle !== 0 && angle !== Math.PI);
    var x = (px * Math.cos(angle) + py * Math.sin(angle)) / scale + current.width / 2;
    var y = (-px * Math.sin(angle) + py * Math.cos(angle)) / scale + current.height / 2;
    var u = x / current.width;
    var v = y / current.height;
    if (u < 0 || u > 1 || v < 0 || v > 1) return null;
    return { u: u, v: v };
  }

  function draw() {
    resizeCanvas();
    ctx.fillStyle = '#000';
    ctx.fillRect(0, 0, canvas.width, canvas.height);
    if (!current) return;
    var angle = rotationFor(currentOrientation);
    var sideways = angle !== 0 && angle !== Math.PI;
    var sourceWidth = current.width;
    var sourceHeight = current.height;
    var scale = frameScale(sourceWidth, sourceHeight, sideways);
    ctx.save();
    ctx.translate(canvas.width / 2, canvas.height / 2);
    ctx.rotate(angle);
    ctx.scale(scale, scale);
    ctx.drawImage(current, -sourceWidth / 2, -sourceHeight / 2);
    ctx.restore();
  }

  // MARK: 상태 감시

  // waiting=true면 스피너를 돌린다. 사용자가 뭔가 해야 하는 상태(방송 종료)는 멈춘 화면으로 보여준다.
  function setOverlay(title, hint, waiting) {
    if (title) {
      statusEl.textContent = title;
      hintEl.textContent = hint || '';
      panelEl.classList.toggle('still', waiting === false);
      overlay.classList.remove('hidden');
    } else {
      overlay.classList.add('hidden');
    }
  }

  function tick() {
    var now = Date.now();
    // 화면이 꺼지거나 탭이 뒤로 가면 브라우저가 페이지를 멈춘다. 깨어난 직후에는 밀린 메시지가 아직
    // 처리되지 않아 "무응답"처럼 보이므로, 이번 한 번은 끊김으로 판단하지 않고 시간을 다시 잰다.
    if (now - lastTickAt > 1500) {
      lastMessageAt = now;
      wsStartedAt = now;
    }
    lastTickAt = now;
    var open = ws && ws.readyState === WebSocket.OPEN;

    if (ws && ws.readyState === WebSocket.CONNECTING && now - wsStartedAt > CONNECT_TIMEOUT_MS) {
      abandon(ws);
    } else if (open && now - lastMessageAt > SILENCE_TIMEOUT_MS) {
      abandon(ws);
    }

    open = ws && ws.readyState === WebSocket.OPEN;
    if (open && hasFrame) {
      setOverlay(null);
    } else if (open) {
      setOverlay('화면을 불러오고 있어요', '', true);
    } else if (now - disconnectedSince < OVERLAY_GRACE_MS && hasFrame) {
      // 짧은 재연결은 마지막 화면을 유지한 채 조용히 넘어간다.
      setOverlay(null);
    } else if (broadcastEnded) {
      setOverlay('iPhone 화면 방송이 종료됐어요', 'iPhone 화면이 잠기면 방송이 꺼져요. 자동 잠금을 "안 함"으로 두고, Tessync 방송을 다시 시작하면 자동으로 연결돼요.', false);
    } else if (everConnected) {
      setOverlay('다시 연결하고 있어요', 'iPhone 화면이 잠겼거나 핫스팟 연결이 끊겼을 수 있어요.', true);
    } else {
      setOverlay('iPhone을 기다리고 있어요', 'iPhone 핫스팟에 연결하고 Tessync 화면 방송을 시작하세요.', true);
    }
  }

  function updateDebug() {
    stats.fps = stats.framesInSecond;
    stats.framesInSecond = 0;
    if (!debugEl.classList.contains('on')) return;
    var age = lastMessageAt ? ((Date.now() - lastMessageAt) / 1000).toFixed(1) + 's' : '-';
    debugEl.textContent = [
      '플레이어  ' + PLAYER_VERSION,
      '수신 fps  ' + stats.fps,
      '프레임    ' + (current ? current.width + 'x' + current.height + ' o' + currentOrientation : '-'),
      '마지막    ' + age,
      '끊김      ' + stats.drops,
      '접속시도  ' + stats.attempts,
      '디코딩오류 ' + stats.decodeErrors,
      '폰 단계   ' + (phone.lvl !== undefined ? phone.lvl : '-'),
      '폰 fps    ' + (phone.fps !== undefined ? phone.fps : '-'),
      '폰 메모리 ' + (phone.mem !== undefined ? phone.mem + 'MB' : '-'),
      '터치 장치 ' + (phone.touch === 2 ? '준비됨' : phone.touch === 1 ? '블루투스 대기' : '없음')
    ].join('\n');
  }

  // MARK: 시작

  document.getElementById('debugToggle').addEventListener('click', function () {
    debugEl.classList.toggle('on');
    updateDebug();
  });

  var root = document.documentElement;
  var requestFullscreen = root.requestFullscreen || root.webkitRequestFullscreen;
  if (requestFullscreen) {
    fullscreenButton.hidden = false;
    fullscreenButton.addEventListener('click', function () {
      var result = requestFullscreen.call(root);
      if (result && result.catch) result.catch(function () {});
    });
    document.addEventListener('fullscreenchange', function () {
      fullscreenButton.hidden = !!document.fullscreenElement;
    });
  }

  // 터치 조작: 터치 장치(ESP32)가 준비돼 있으면 누른 위치를 iPhone에 보낸다. iPhone이 포인터를 옮겨 클릭한다.
  canvas.addEventListener('click', function (event) {
    if (phone.touch !== 2 || !ws || ws.readyState !== WebSocket.OPEN) return;
    var point = canvasToFrame(event.clientX, event.clientY);
    if (!point) return;
    ws.send(JSON.stringify({ t: 'tap', u: point.u, v: point.v }));
    var ripple = document.createElement('div');
    ripple.className = 'ripple';
    ripple.style.left = event.clientX + 'px';
    ripple.style.top = event.clientY + 'px';
    document.body.appendChild(ripple);
    setTimeout(function () { document.body.removeChild(ripple); }, 600);
  });

  window.addEventListener('resize', draw);
  document.addEventListener('visibilitychange', function () {
    // 테슬라에서 다른 화면을 보고 돌아오면 기다리지 않고 바로 다시 붙는다.
    if (document.visibilityState === 'visible' && !ws) {
      attempts = 0;
      clearTimeout(reconnectTimer);
      reconnectTimer = null;
      connect();
    }
  });

  // 주소 뒤에 ?debug=1 을 붙이면 디버그 정보를 처음부터 보여준다.
  if (params.get('debug')) debugEl.classList.add('on');

  setInterval(tick, 250);
  setInterval(updateDebug, 1000);
  draw();
  connect();
})();
