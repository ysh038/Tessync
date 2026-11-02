import CoreGraphics
import CoreVideo
import Foundation

/// 테슬라 화면에서 누른 위치로 아이폰 포인터를 옮겨 클릭한다(ESP32 BLE 마우스 + AssistiveTouch).
///
/// 이동량만으로는 위치가 일정하지 않아서(iOS 포인터 가속), 방송 프레임에서 포인터를 찾아 차이만큼 다시 보내는
/// 폐루프로 맞춘다. 맥 프로토타입(tools/touch-seek.py)을 옮긴 것이다. 실측값은 docs/design/02-touch-control.md.
///
/// 위치는 0~1 비율로 다룬다. 전송이 밀리면 화질 단계가 바뀌어 프레임 크기가 도중에 달라지기 때문이다(차에서 겪음).
/// 확인할 수 없으면 추측해서 움직이지 않고 그 터치를 포기한다. 엉뚱한 곳을 누르는 것보다 안 누르는 게 낫다.
final class TouchController {
    /// 아래 픽셀 값은 590px 너비 프레임 기준 실측값이다. 다른 크기 프레임에서는 너비에 비례시킨다.
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
    private static let settleTimeout: TimeInterval = 1.5
    /// 터치 한 번에 쓰는 최대 시간. 넘으면 포기한다.
    private static let tapBudget: TimeInterval = 12

    private let link: TouchLink
    private let log: DiagnosticsLog
    private let queue = DispatchQueue(label: "tessync.touch")

    private let frameLock = NSLock()
    private var latest: FrameSnapshot?
    private var latestAt: TimeInterval = 0

    private let tapLock = NSLock()
    private var pendingTap: CGPoint?
    private var working = false

    // queue 전용
    /// 마지막으로 확인한 포인터 위치(0~1). 모서리 원점 직후 이동은 크게 빗나가므로 가능하면 여기서 출발한다.
    private var lastKnown: CGPoint?
    /// 화면 방향(ReplayKit orientation)별로, 마우스 +x 이동이 프레임에서 향하는 방향(단위 벡터).
    /// 프레임은 항상 세로 원본 그대로라, 가로 화면에서는 마우스 축과 프레임 축이 다르다.
    /// 세로 화면을 회전하지 않는 앱도 있어서 orientation만으로는 알 수 없다. 처음 한 번 움직여 보고 정한다.
    private var mouseXAxis: [UInt8: CGPoint] = [1: CGPoint(x: 1, y: 0)]
    private var deadline: TimeInterval = 0

    init(link: TouchLink, log: DiagnosticsLog) {
        self.link = link
        self.log = log
    }

    /// 터치를 처리하는 중이면 true. 그동안은 전송이 밀려도 프레임을 계속 받아야 한다.
    var isWorking: Bool {
        tapLock.lock()
        defer { tapLock.unlock() }
        return working
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

    /// 브라우저에서 누른 위치(방송 프레임 기준 0~1). 처리 중에 여러 번 누르면 가장 마지막 것 하나만 처리한다.
    func tap(u: Double, v: Double) {
        tapLock.lock()
        pendingTap = CGPoint(x: u, y: v)
        let start = !working
        working = true
        tapLock.unlock()
        guard start else { return }
        queue.async { [self] in
            while true {
                tapLock.lock()
                guard let target = pendingTap else {
                    working = false
                    tapLock.unlock()
                    return
                }
                pendingTap = nil
                tapLock.unlock()
                perform(target)
            }
        }
    }

    // MARK: - queue

    private func perform(_ target: CGPoint) {
        guard link.isReady else {
            log.write("tap ignored: touch device not ready")
            return
        }
        guard let first = snapshot() else {
            log.write("tap ignored: no frame yet")
            return
        }
        let started = ProcessInfo.processInfo.systemUptime
        deadline = started + Self.tapBudget
        let orientation = first.orientation

        func fail(_ reason: String) {
            // 어디 있는지 확신할 수 없으니 다음에는 처음부터 찾는다.
            lastKnown = nil
            log.write(String(format: "tap %.2f,%.2f failed: %@ (%.2fs)", target.x, target.y, reason,
                             ProcessInfo.processInfo.systemUptime - started))
        }

        var start: CGPoint?
        if mouseXAxis[orientation] == nil {
            // 이 화면 방향은 처음이다. 움직여 보며 축을 정하고, 그 과정에서 포인터 위치도 얻는다.
            start = calibrateAxis(orientation: orientation)
            if start == nil { return fail("could not learn pointer direction (orientation \(orientation))") }
        }
        guard var position = start ?? locateStart(orientation: orientation) else { return fail("pointer not found") }

        for round in 0...Self.maxRounds {
            guard let frame = snapshot() else { return fail("no frame") }
            let scale = Double(frame.width) / Self.referenceWidth
            // 590px 기준 픽셀로 본 남은 거리
            let dx = (target.x - position.x) * Double(frame.width) / scale
            let dy = (target.y - position.y) * Double(frame.height) / scale
            if abs(dx) <= Self.tolerancePx, abs(dy) <= Self.tolerancePx {
                lastKnown = position
                guard link.send("c")?.hasPrefix("ok") == true else { return fail("click not acknowledged") }
                log.write(String(format: "tap %.2f,%.2f clicked rounds=%d %.2fs", target.x, target.y, round,
                                 ProcessInfo.processInfo.systemUptime - started))
                return
            }
            guard round < Self.maxRounds else { break }
            guard ProcessInfo.processInfo.systemUptime < deadline else { return fail("took too long") }

            let sent = ProcessInfo.processInfo.systemUptime
            guard link.send(moveCommand(dx: dx, dy: dy, orientation: orientation)) != nil else {
                return fail("touch device did not answer")
            }
            let expected = CGPoint(x: target.x, y: target.y)
            guard let after = settledFrame(after: sent) else { return fail("no new frame after move") }
            let afterScale = Double(after.width) / Self.referenceWidth
            let expectedPx = pixel(expected, in: after)
            // 크게(특히 대각선으로) 움직이면 예상의 75%만 가기도 한다. 이동 거리에 비례해 오차를 허용한다.
            let slack = max(110, 0.4 * max(abs(dx), abs(dy))) * afterScale
            if let found = PointerFinder.findByColor(in: after, near: expectedPx),
               abs(found.x - expectedPx.x) <= slack, abs(found.y - expectedPx.y) <= slack {
                position = ratio(found, in: after)
            } else if let found = wiggleLocate(near: expected, window: slack, orientation: orientation) {
                position = found
            } else {
                return fail(String(format: "lost pointer near %.2f,%.2f", expected.x, expected.y))
            }
        }
        lastKnown = position
        log.write(String(format: "tap %.2f,%.2f did not converge (at %.3f,%.3f) %.2fs", target.x, target.y,
                         position.x, position.y, ProcessInfo.processInfo.systemUptime - started))
    }

    /// 출발 위치(0~1): 색으로 바로 보이면 그것, 아니면 마지막 위치에서 비켜놓기, 그래도 없으면 모서리 원점.
    private func locateStart(orientation: UInt8) -> CGPoint? {
        guard let frame = snapshot() else { return nil }
        if let found = PointerFinder.findByColor(in: frame, near: lastKnown.map { pixel($0, in: frame) }) {
            return ratio(found, in: frame)
        }
        let scale = Double(frame.width) / Self.referenceWidth
        if let last = lastKnown, let found = wiggleLocate(near: last, window: 110 * scale, orientation: orientation) {
            return found
        }
        // 모서리 원점: 마우스 좌표로 왼쪽 위(-,-)는 화면 방향에 따라 프레임의 다른 모서리다.
        let sent = ProcessInfo.processInfo.systemUptime
        guard link.send("h") != nil, link.send("m 40 40") != nil, let after = settledFrame(after: sent) else { return nil }
        let corner = frameCorner(orientation: orientation)
        if let found = PointerFinder.findByColor(in: after, near: pixel(corner, in: after)) {
            return ratio(found, in: after)
        }
        return wiggleLocate(near: corner, window: 160 * Double(after.width) / Self.referenceWidth, orientation: orientation)
    }

    /// 마우스 좌표 (-,-) 쪽 모서리에서 조금 들어온 곳(0~1).
    private func frameCorner(orientation: UInt8) -> CGPoint {
        let (xAxis, yAxis) = axes(for: orientation)
        let inset = 0.07
        return CGPoint(x: (xAxis.x + yAxis.x) > 0 ? inset : 1 - inset,
                       y: (xAxis.y + yAxis.y) > 0 ? inset * 0.46 : 1 - inset * 0.46)
    }

    /// 마우스 +x, +y 이동이 프레임에서 향하는 방향. 회전만 있고 뒤집힘은 없으므로 y축은 x축을 90도 돌린 것이다.
    private func axes(for orientation: UInt8) -> (x: CGPoint, y: CGPoint) {
        let x = mouseXAxis[orientation] ?? CGPoint(x: 1, y: 0)
        return (x, CGPoint(x: -x.y, y: x.x))
    }

    /// 마우스를 +x로 두 번 비켜놓으며 프레임 차이를 보고, 마우스 +x가 프레임에서 어느 방향인지 정한다.
    /// 위치 A→B→C: diff(A,B)와 diff(B,C)에 공통인 원이 B이고, A에만 있는 원이 A(원래 위치)다. 방향은 B - A.
    /// 성공하면 원래 위치(0~1)를 돌려준다.
    private func calibrateAxis(orientation: UInt8) -> CGPoint? {
        for sign in [1, -1] {
            guard let a = snapshot() else { return nil }
            let units = sign * Self.wiggleUnits
            var sent = ProcessInfo.processInfo.systemUptime
            guard link.send("g \(units) 0 \(Self.wiggleStep)") != nil, let b = settledFrame(after: sent) else { continue }
            sent = ProcessInfo.processInfo.systemUptime
            guard link.send("g \(units) 0 \(Self.wiggleStep)") != nil, let c = settledFrame(after: sent) else { continue }
            sent = ProcessInfo.processInfo.systemUptime
            _ = link.send("g \(-2 * units) 0 \(Self.wiggleStep)")
            _ = settledFrame(after: sent)
            // 도중에 프레임 크기가 바뀌면 비교할 수 없다.
            guard a.width == b.width, b.width == c.width else { continue }

            let first = PointerFinder.differencePeaks(before: a.luma, after: b, region: nil)
            let second = PointerFinder.differencePeaks(before: b.luma, after: c, region: nil)
            let near = Double(PointerFinder.diameter(frameWidth: a.width))
            for p in first {
                guard let shared = second.first(where: { hypot($0.x - p.x, $0.y - p.y) < near }),
                      let origin = first.first(where: { hypot($0.x - shared.x, $0.y - shared.y) >= near }) else { continue }
                let step = CGPoint(x: shared.x - origin.x, y: shared.y - origin.y)
                // 축 방향 하나로 맞춘다(회전은 90도 단위).
                var axis = abs(step.x) >= abs(step.y) ? CGPoint(x: step.x > 0 ? 1 : -1, y: 0) : CGPoint(x: 0, y: step.y > 0 ? 1 : -1)
                if sign < 0 { axis = CGPoint(x: -axis.x, y: -axis.y) }
                mouseXAxis[orientation] = axis
                log.write(String(format: "touch axis for orientation %d: mouse +x = frame (%.0f,%.0f), step %.0f,%.0f px",
                                 orientation, axis.x, axis.y, step.x, step.y))
                return ratio(origin, in: a)
            }
            // 화면 끝에 막혀 안 움직였을 수 있다. 반대 방향으로 한 번 더 해본다.
        }
        return nil
    }

    /// 비켜놓기로 포인터를 찾는다. near, 결과 모두 0~1. window는 프레임 픽셀.
    private func wiggleLocate(near point: CGPoint, window: Double, orientation: UInt8) -> CGPoint? {
        guard let before = snapshot() else { return nil }
        let axis = axes(for: orientation).x
        let nearPx = pixel(point, in: before)
        // 마우스 +x 방향으로 화면 끝 근처면 반대로 비켜놓는다(화면 끝에 막히면 비켜지지 않는다).
        let room = axis.x != 0
            ? (axis.x > 0 ? Double(before.width) - nearPx.x : nearPx.x)
            : (axis.y > 0 ? Double(before.height) - nearPx.y : nearPx.y)
        let positive = room > 150 * Double(before.width) / Self.referenceWidth
        let units = positive ? Self.wiggleUnits : -Self.wiggleUnits
        var sent = ProcessInfo.processInfo.systemUptime
        guard link.send("g \(units) 0 \(Self.wiggleStep)") != nil, let moved = settledFrame(after: sent) else { return nil }
        sent = ProcessInfo.processInfo.systemUptime
        guard link.send("g \(-units) 0 \(Self.wiggleStep)") != nil else { return nil }
        _ = settledFrame(after: sent)
        guard moved.width == before.width else { return nil }
        let direction = positive ? axis : CGPoint(x: -axis.x, y: -axis.y)
        guard let found = PointerFinder.findByDifference(before: before.luma, after: moved, near: nearPx,
                                                         window: Int(window), direction: direction) else { return nil }
        return ratio(found, in: moved)
    }

    /// 590px 기준 프레임 픽셀 이동량을 마우스 축으로 바꿔 명령으로 만든다.
    private func moveCommand(dx frameDx: Double, dy frameDy: Double, orientation: UInt8) -> String {
        let (xAxis, yAxis) = axes(for: orientation)
        let dx = frameDx * xAxis.x + frameDy * xAxis.y
        let dy = frameDx * yAxis.x + frameDy * yAxis.y
        if max(abs(dx), abs(dy)) >= Self.coarseMinPx {
            return "g \(Int((dx / Self.coarsePxPerUnit).rounded())) \(Int((dy / Self.coarsePxPerUnit).rounded())) \(Self.coarseStep)"
        }
        func units(_ px: Double) -> Int {
            let scale = Self.smallPxPerUnit.first { abs(px) < $0.limit }!.value
            return Int((px / scale).rounded())
        }
        return "m \(units(dx)) \(units(dy))"
    }

    private func pixel(_ point: CGPoint, in frame: FrameSnapshot) -> CGPoint {
        CGPoint(x: point.x * Double(frame.width), y: point.y * Double(frame.height))
    }

    private func ratio(_ point: CGPoint, in frame: FrameSnapshot) -> CGPoint {
        CGPoint(x: point.x / Double(frame.width), y: point.y / Double(frame.height))
    }

    private func snapshot() -> FrameSnapshot? {
        frameLock.lock()
        defer { frameLock.unlock() }
        return latest
    }

    /// 명령을 보낸 뒤 화면이 멈출 때까지(새 프레임이 quietPeriod 동안 없을 때까지) 기다린다.
    /// ReplayKit은 화면이 바뀔 때만 프레임을 주므로, 포인터가 멈추면 프레임도 멈춘다.
    /// 명령 뒤로 새 프레임이 하나도 없으면 nil이다. 예전 화면을 보고 판단하면 엉뚱한 곳으로 계속 움직인다.
    private func settledFrame(after sent: TimeInterval) -> FrameSnapshot? {
        let earliest = sent + Self.minSettle
        let limit = earliest + Self.settleTimeout
        while true {
            let now = ProcessInfo.processInfo.systemUptime
            frameLock.lock()
            let frameAt = latestAt
            frameLock.unlock()
            let fresh = frameAt > sent + 0.05
            if now >= earliest, fresh, now - frameAt >= Self.quietPeriod {
                return snapshot()
            }
            if now >= limit {
                return fresh ? snapshot() : nil
            }
            Thread.sleep(forTimeInterval: 0.03)
        }
    }
}
