import Foundation
import Network

/// ESP32(Tessync Touch)와의 연결. 보드가 핫스팟 게이트웨이(이 iPhone)의 8082 포트로 TCP 연결을 걸어온다.
///
/// 명령과 응답은 줄 단위다. 보드는 1초마다 "hb ble=1"을 보낸다.
/// 명령: m dx dy(이동), g dx dy step(축별 고정 걸음 이동), c(클릭), h(왼쪽 위 모서리로). 응답: ok/error/status로 시작.
/// 설계: docs/design/02-touch-control.md
final class TouchLink {
    static let port: UInt16 = 8082

    private let log: DiagnosticsLog
    private let queue = DispatchQueue(label: "tessync.touchlink")
    private var listener: NWListener?
    private var connection: NWConnection?
    private var buffer = Data()

    // send()는 터치 큐에서 응답을 기다리며 막힌다. 응답은 queue에서 채운다.
    private let lock = NSLock()
    private var waiter: DispatchSemaphore?
    private var reply: String?
    private var _connected = false
    private var _bleReady = false

    init(log: DiagnosticsLog) {
        self.log = log
    }

    /// 보드가 Wi-Fi로 붙어 있고, 아이폰과 블루투스 마우스로도 연결돼 있는지.
    var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _connected && _bleReady
    }

    /// 0: 보드 없음, 1: Wi-Fi만 연결(아이폰 블루투스 미연결), 2: 사용 가능
    var statusCode: Int {
        lock.lock()
        defer { lock.unlock() }
        return _connected ? (_bleReady ? 2 : 1) : 0
    }

    func start() throws {
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: Self.port)!)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                self?.log.write("touch listener failed: \(error)")
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        connection?.cancel()
    }

    /// 명령을 보내고 응답 줄을 기다린다. 응답이 없거나 연결이 없으면 nil. 터치 큐에서만 부른다.
    func send(_ command: String, timeout: TimeInterval = 3) -> String? {
        let semaphore = DispatchSemaphore(value: 0)
        lock.lock()
        guard _connected else {
            lock.unlock()
            return nil
        }
        waiter = semaphore
        reply = nil
        lock.unlock()

        // connection은 queue에서만 다룬다.
        queue.async { [weak self] in
            self?.connection?.send(content: Data((command + "\n").utf8), completion: .contentProcessed { _ in })
        }
        let timedOut = semaphore.wait(timeout: .now() + timeout) == .timedOut

        lock.lock()
        defer { lock.unlock() }
        waiter = nil
        if timedOut {
            log.write("touch command timed out: \(command)")
            return nil
        }
        return reply
    }

    // MARK: - queue

    private func accept(_ newConnection: NWConnection) {
        // 보드가 다시 붙으면(재시작, Wi-Fi 재연결) 새 연결로 바꾼다.
        connection?.cancel()
        connection = newConnection
        buffer.removeAll()
        newConnection.stateUpdateHandler = { [weak self, weak newConnection] state in
            guard let self, let newConnection else { return }
            switch state {
            case .ready:
                log.write("touch device connected from \(newConnection.endpoint)")
                setConnected(true, for: newConnection)
            case .failed, .cancelled:
                if setConnected(false, for: newConnection) {
                    log.write("touch device disconnected")
                }
            default:
                break
            }
        }
        newConnection.start(queue: queue)
        receive(on: newConnection)
    }

    /// 지금 연결에 대한 상태 변화만 반영한다. 반영했으면 true.
    @discardableResult
    private func setConnected(_ value: Bool, for target: NWConnection) -> Bool {
        guard target === connection else { return false }
        lock.lock()
        let changed = _connected != value
        _connected = value
        if !value {
            _bleReady = false
            waiter?.signal()
        }
        lock.unlock()
        if !value { connection = nil }
        return changed
    }

    private func receive(on target: NWConnection) {
        target.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self, weak target] data, _, isComplete, error in
            guard let self, let target else { return }
            if let data {
                buffer.append(data)
                while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    handle(line: line.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
            if isComplete || error != nil {
                target.cancel()
            } else {
                receive(on: target)
            }
        }
    }

    private func handle(line: String) {
        if line.hasPrefix("hb ") || line.hasPrefix("hello ") {
            let ready = line.contains("ble=1")
            lock.lock()
            let changed = _bleReady != ready
            _bleReady = ready
            lock.unlock()
            if changed { log.write("touch device bluetooth \(ready ? "ready" : "not connected")") }
            return
        }
        guard line.hasPrefix("ok") || line.hasPrefix("error") || line.hasPrefix("status") else { return }
        lock.lock()
        if let waiter {
            reply = line
            waiter.signal()
        }
        lock.unlock()
    }
}
