import CoreGraphics
import CoreVideo
import Foundation

/// 테슬라 화면에서 누른 위치로 아이폰 포인터를 옮겨 클릭한다(ESP32 BLE 마우스 + AssistiveTouch).
///
/// 이동량만으로는 위치가 일정하지 않아서(iOS 포인터 가속), 방송 프레임에서 포인터를 찾아 차이만큼 다시 보내는
/// 폐루프로 맞춘다. 맥 프로토타입(tools/touch-seek.py)을 옮긴 것이다. 실측값은 docs/design/02-touch-control.md.
final class TouchController {
    // 590px 너비 프레임 기준 실측값. 다른 크기 프레임에서는 너비에 비례시킨다.
    private static let referenceWidth = 590.0
    /// 큰 이동은 축별로 같은 크기(60) 걸음으로 보낸다. 1당 약 0.98px로 일정하다.
    private static let coarseStep = 60
    private static let coarsePxPerUnit = 0.98
    private static let coarseMinPx = 40.0
    /// 작은 보정은 한 번에 보낸다. 작을수록 iOS 가속 곡선 때문에 덜 간다.
    private static let smallPxPerUnit: [(limit: Double, value: Double)] = [(10, 0.76), (30, 0.86), (.infinity, 0.95)]
    private static let tolerancePx = 4.0
    private static let maxRounds = 6
    /// 비켜놓기: 같은 걸음으로 갔다가 되돌아오면 제자리로 온다. 120을 20씩 보내면 약 73px.
    private static let wiggleUnits = 120
    private static let wiggleStep = 20
    /// 이동 후 프레임에 반영되기까지 0.3~0.4초 걸린다.
    private static let minSettle: TimeInterval = 0.45
    private static let quietPeriod: TimeInterval = 0.2
    private static let settleTimeout: TimeInterval = 1.2

    private let link: TouchLink
    private let log: DiagnosticsLog
    private let queue = DispatchQueue(label: "tessync.touch")

    private let frameLock = NSLock()
    private var latest: FrameSnapshot?
    private var latestAt: TimeInterval = 0

    // queue 전용
    private var busy = false
    private var pendingTap: CGPoint?
    /// 마지막으로 확인한 포인터 위치(0~1 비율). 모서리 원점 직후 이동은 크게 빗나가므로 가능하면 여기서 출발한다.
    private var lastKnown: CGPoint?
    private var landscapeLogged = false

    init(link: TouchLink, log: DiagnosticsLog) {
        self.link = link
        self.log = log
    }

    /// 인코딩 큐에서 축소 프레임마다 부른다. 보드가 연결돼 있을 때만 복사한다.
    func observe(frame pixelBuffer: CVPixelBuffer, orientation: UInt8) {
        guard link.isReady else { return }
        frameLock.lock()
        var old = latest
        latest = nil
        frameLock.unlock()
        let snapshot = FrameSnapshot(pixelBuffer: pixelBuffer, orientation: orientation, reusing: &old)
        frameLock.lock()
        latest = snapshot
        latestAt = ProcessInfo.processInfo.systemUptime
        frameLock.unlock()
    }

    /// 브라우저에서 누른 위치(방송 프레임 기준 0~1). 처리 중이면 가장 최근 것 하나만 남긴다.
    func tap(u: Double, v: Double) {
        queue.async { [self] in
            pendingTap = CGPoint(x: u, y: v)
            guard !busy else { return }
            busy = true
            while let target = pendingTap {
                pendingTap = nil
                perform(target)
            }
            busy = false
        }
    }

    // MARK: - queue

    private func perform(_ target: CGPoint) {
        guard link.isReady else {
            log.write("tap ignored: touch device not ready")
            return
        }
        guard let frame = snapshot() else {
            log.write("tap ignored: no frame yet")
            return
        }
        // 가로 화면에서는 마우스 축과 프레임 축이 다르다. 아직 실기기로 확인하지 않아 세로만 지원한다.
        guard frame.orientation == 1 else {
            if !landscapeLogged { log.write("tap ignored: landscape not supported yet (orientation \(frame.orientation))") }
            landscapeLogged = true
            return
        }
        let started = ProcessInfo.processInfo.systemUptime
        let scale = Double(frame.width) / Self.referenceWidth
        let goal = CGPoint(x: target.x * Double(frame.width), y: target.y * Double(frame.height))

        guard var position = locateStart(in: frame) else {
            log.write("tap failed: pointer not found")
            return
        }
        for round in 0...Self.maxRounds {
            let dx = goal.x - position.x, dy = goal.y - position.y
            if abs(dx) <= Self.tolerancePx * scale, abs(dy) <= Self.tolerancePx * scale {
                remember(position, in: frame)
                let clicked = link.send("c")?.hasPrefix("ok") == true
                log.write(String(format: "tap %.2f,%.2f %@ rounds=%d %.2fs", target.x, target.y,
                                 clicked ? "clicked" : "click failed", round, ProcessInfo.processInfo.systemUptime - started))
                return
            }
            guard round < Self.maxRounds else { break }
            let sent = ProcessInfo.processInfo.systemUptime
            guard link.send(moveCommand(dx: dx / scale, dy: dy / scale)) != nil else {
                log.write("tap failed: touch device did not answer")
                return
            }
            let expected = CGPoint(x: position.x + dx, y: position.y + dy)
            guard let after = settledFrame(after: sent) else { break }
            // 크게(특히 대각선으로) 움직이면 예상의 75%만 가기도 한다. 이동 거리에 비례해 오차를 허용한다.
            let slack = max(110 * scale, 0.4 * max(abs(dx), abs(dy)))
            if let found = PointerFinder.findByColor(in: after, near: expected),
               abs(found.x - expected.x) <= slack, abs(found.y - expected.y) <= slack {
                position = found
            } else if let found = wiggleLocate(near: expected, window: Int(slack)) {
                position = found
            } else {
                lastKnown = nil
                log.write(String(format: "tap failed: lost pointer near %.0f,%.0f", expected.x, expected.y))
                return
            }
        }
        remember(position, in: frame)
        log.write(String(format: "tap %.2f,%.2f did not converge (%.0f,%.0f vs %.0f,%.0f)", target.x, target.y,
                         position.x, position.y, goal.x, goal.y))
    }

    /// 출발 위치: 색으로 바로 보이면 그것, 아니면 마지막 위치에서 비켜놓기, 그래도 없으면 모서리 원점.
    private func locateStart(in frame: FrameSnapshot) -> CGPoint? {
        let last = lastKnown.map { CGPoint(x: $0.x * Double(frame.width), y: $0.y * Double(frame.height)) }
        if let found = PointerFinder.findByColor(in: frame, near: last) {
            return found
        }
        let scale = Double(frame.width) / Self.referenceWidth
        if let last, let found = wiggleLocate(near: last, window: Int(110 * scale)) {
            return found
        }
        let sent = ProcessInfo.processInfo.systemUptime
        guard link.send("h") != nil, link.send("m 40 40") != nil, let after = settledFrame(after: sent) else { return nil }
        let corner = CGPoint(x: 40 * scale, y: 40 * scale)
        return PointerFinder.findByColor(in: after, near: corner) ?? wiggleLocate(near: corner, window: Int(110 * scale))
    }

    private func wiggleLocate(near point: CGPoint, window: Int) -> CGPoint? {
        guard let before = snapshot() else { return nil }
        // 오른쪽 끝 근처면 왼쪽으로 비켜놓는다(화면 끝에 막히면 비켜지지 않는다).
        let moveRight = point.x < Double(before.width) * 0.75
        let units = moveRight ? Self.wiggleUnits : -Self.wiggleUnits
        var sent = ProcessInfo.processInfo.systemUptime
        guard link.send("g \(units) 0 \(Self.wiggleStep)") != nil, let moved = settledFrame(after: sent) else { return nil }
        sent = ProcessInfo.processInfo.systemUptime
        guard link.send("g \(-units) 0 \(Self.wiggleStep)") != nil else { return nil }
        _ = settledFrame(after: sent)
        return PointerFinder.findByDifference(before: before.luma, after: moved, near: point, window: window, movedRight: moveRight)
    }

    /// 프레임 픽셀을 590px 기준으로 바꾼 이동량을 명령으로 만든다.
    private func moveCommand(dx: Double, dy: Double) -> String {
        if max(abs(dx), abs(dy)) >= Self.coarseMinPx {
            return "g \(Int((dx / Self.coarsePxPerUnit).rounded())) \(Int((dy / Self.coarsePxPerUnit).rounded())) \(Self.coarseStep)"
        }
        func units(_ px: Double) -> Int {
            let scale = Self.smallPxPerUnit.first { abs(px) < $0.limit }!.value
            return Int((px / scale).rounded())
        }
        return "m \(units(dx)) \(units(dy))"
    }

    private func remember(_ position: CGPoint, in frame: FrameSnapshot) {
        lastKnown = CGPoint(x: position.x / Double(frame.width), y: position.y / Double(frame.height))
    }

    private func snapshot() -> FrameSnapshot? {
        frameLock.lock()
        defer { frameLock.unlock() }
        return latest
    }

    /// 명령을 보낸 뒤 화면이 멈출 때까지(새 프레임이 quietPeriod 동안 없을 때까지) 기다린다.
    /// ReplayKit은 화면이 바뀔 때만 프레임을 주므로, 포인터가 멈추면 프레임도 멈춘다.
    private func settledFrame(after sent: TimeInterval) -> FrameSnapshot? {
        let earliest = sent + Self.minSettle
        let deadline = earliest + Self.settleTimeout
        while true {
            let now = ProcessInfo.processInfo.systemUptime
            frameLock.lock()
            let age = now - latestAt
            frameLock.unlock()
            if now >= earliest, age >= Self.quietPeriod || now >= deadline {
                return snapshot()
            }
            Thread.sleep(forTimeInterval: 0.03)
        }
    }
}
