import CoreGraphics
import CoreVideo
import Foundation

/// 방송 축소 프레임(YUV 4:2:0 biplanar)의 밝기, 색 평면 복사본.
struct FrameSnapshot {
    let width: Int
    let height: Int
    let orientation: UInt8
    let fullRange: Bool
    var luma: [UInt8]
    /// (width/2) x (height/2) 크기의 Cb, Cr 교차 배열
    var chroma: [UInt8]

    /// 같은 크기의 이전 복사본이 있으면 그 배열을 넘겨받아 재사용한다(매 프레임 할당하지 않게).
    /// 다른 곳에서 아직 들고 있는 복사본이면 Swift 배열의 copy-on-write로 새로 할당되므로 안전하다.
    init?(pixelBuffer: CVPixelBuffer, orientation: UInt8, reusing old: inout FrameSnapshot?) {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            CVPixelBufferGetPlaneCount(pixelBuffer) == 2 else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        self.width = width
        self.height = height
        self.orientation = orientation
        fullRange = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange

        if let previous = old, previous.width == width, previous.height == height {
            luma = previous.luma
            chroma = previous.chroma
        } else {
            luma = [UInt8](repeating: 0, count: width * height)
            chroma = [UInt8](repeating: 0, count: (width / 2) * (height / 2) * 2)
        }
        old = nil

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        Self.copyPlane(pixelBuffer, plane: 0, rowBytes: width, rows: height, into: &luma)
        Self.copyPlane(pixelBuffer, plane: 1, rowBytes: (width / 2) * 2, rows: height / 2, into: &chroma)
    }

    private static func copyPlane(_ buffer: CVPixelBuffer, plane: Int, rowBytes: Int, rows: Int, into target: inout [UInt8]) {
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { return }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
        target.withUnsafeMutableBytes { destination in
            for row in 0..<rows {
                memcpy(destination.baseAddress! + row * rowBytes, base + row * stride, rowBytes)
            }
        }
    }
}

/// AssistiveTouch 포인터(회색 원)를 프레임에서 찾는다. 좌표는 프레임 픽셀.
///
/// 실측(590x1280 프레임): 포인터는 RGB 약 (148,149,151), 지름 약 27px. 크기는 프레임 너비에 비례시킨다.
enum PointerFinder {
    static func diameter(frameWidth: Int) -> Int {
        max(8, Int((27.0 * Double(frameWidth) / 590.0).rounded()))
    }

    /// 밝은 배경 위의 포인터를 색과 크기로 찾는다. 글자, 아이콘 위에 겹치면 못 찾는다.
    /// 비슷한 회색 원(AssistiveTouch 버튼 등)도 걸리므로 near가 있으면 그에 가장 가까운 후보를 고른다.
    static func findByColor(in frame: FrameSnapshot, near: CGPoint?) -> CGPoint? {
        let width = frame.width, height = frame.height
        let pointerY = frame.fullRange ? 149 : 144
        var mask = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            let chromaRow = (y / 2) * (width / 2) * 2
            for x in 0..<width {
                let luma = Int(frame.luma[y * width + x])
                guard abs(luma - pointerY) <= 12 else { continue }
                let c = chromaRow + (x / 2) * 2
                if abs(Int(frame.chroma[c]) - 128) <= 6, abs(Int(frame.chroma[c + 1]) - 128) <= 6 {
                    mask[y * width + x] = 1
                }
            }
        }
        let integral = Integral(values: mask, width: width, height: height)

        let d = diameter(frameWidth: width)
        let r = d / 2
        var candidates: [(point: CGPoint, score: Int)] = []
        // 포인터는 모서리(원점)에도 붙어 있으므로 화면 끝까지 본다. 바깥 테두리 영역은 화면 안으로 자른다.
        var cy = r
        while cy + d - r <= height {
            var cx = r
            while cx + d - r <= width {
                let inner = integral.sum(x0: cx - r, y0: cy - r, x1: cx - r + d, y1: cy - r + d)
                // 원은 정사각형의 약 78%를 채운다. 꽉 찬 회색 면(버튼 배경 등)은 거른다.
                if inner >= d * d * 55 / 100, inner <= d * d * 90 / 100 {
                    let ox0 = max(0, cx - d), oy0 = max(0, cy - d)
                    let ox1 = min(width, cx + d), oy1 = min(height, cy + d)
                    let ringArea = (ox1 - ox0) * (oy1 - oy0) - d * d
                    let around = integral.sum(x0: ox0, y0: oy0, x1: ox1, y1: oy1) - inner
                    if around <= ringArea / 10 {
                        candidates.append((CGPoint(x: cx, y: cy), inner))
                    }
                }
                cx += 2
            }
            cy += 2
        }
        // 같은 원에 붙은 후보들 중 점수가 가장 높은 것만 남긴다.
        var picked: [CGPoint] = []
        for candidate in candidates.sorted(by: { $0.score > $1.score }) {
            if picked.allSatisfy({ hypot($0.x - candidate.point.x, $0.y - candidate.point.y) > CGFloat(d) }) {
                picked.append(candidate.point)
            }
        }
        let chosen: CGPoint?
        if let near {
            chosen = picked.min { hypot($0.x - near.x, $0.y - near.y) < hypot($1.x - near.x, $1.y - near.y) }
        } else {
            chosen = picked.first
        }
        guard let chosen else { return nil }
        return centroid(of: mask, width: width, around: chosen, radius: r + 2)
    }

    /// 포인터를 옆으로 비켜놓기 전후 프레임의 밝기 차이에서 원을 찾는다. 글자, 아이콘 위에서도 된다.
    /// 차이에는 원래 위치와 비켜놓은 위치 두 곳에 원이 생긴다. movedRight면 왼쪽 원이 원래 위치다.
    static func findByDifference(before: [UInt8], after: FrameSnapshot, near: CGPoint, window: Int, movedRight: Bool) -> CGPoint? {
        let width = after.width, height = after.height
        guard before.count == width * height else { return nil }
        let x0 = max(0, Int(near.x) - window), x1 = min(width, Int(near.x) + window)
        let y0 = max(0, Int(near.y) - window), y1 = min(height, Int(near.y) + window)
        let w = x1 - x0, h = y1 - y0
        let d = diameter(frameWidth: width)
        guard w > d, h > d else { return nil }

        var diff = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y + y0) * width + (x + x0)
                if abs(Int(before[i]) - Int(after.luma[i])) > 25 { diff[y * w + x] = 1 }
            }
        }
        let integral = Integral(values: diff, width: w, height: h)
        var response = [Int](repeating: 0, count: w * h)
        for y in 0...(h - d) {
            for x in 0...(w - d) {
                response[(y + d / 2) * w + (x + d / 2)] = integral.sum(x0: x, y0: y, x1: x + d, y1: y + d)
            }
        }

        var peaks: [(point: CGPoint, score: Int)] = []
        for _ in 0..<2 {
            guard let best = response.indices.max(by: { response[$0] < response[$1] }), response[best] > 0 else { break }
            let bx = best % w, by = best / w
            peaks.append((CGPoint(x: bx + x0, y: by + y0), response[best]))
            for y in max(0, by - 2 * d)..<min(h, by + 2 * d) {
                for x in max(0, bx - 2 * d)..<min(w, bx + 2 * d) { response[y * w + x] = 0 }
            }
        }
        // 원 하나의 30%도 안 바뀌었으면 포인터가 안 움직인 것이다.
        guard let first = peaks.first, first.score >= d * d * 3 / 10 else { return nil }
        if peaks.count == 2, peaks[1].score * 10 >= first.score * 4 {
            return movedRight ? (peaks[0].point.x < peaks[1].point.x ? peaks[0].point : peaks[1].point)
                              : (peaks[0].point.x > peaks[1].point.x ? peaks[0].point : peaks[1].point)
        }
        return first.point
    }

    private static func centroid(of mask: [UInt8], width: Int, around center: CGPoint, radius: Int) -> CGPoint {
        let height = mask.count / width
        var sumX = 0, sumY = 0, count = 0
        for y in max(0, Int(center.y) - radius)..<min(height, Int(center.y) + radius) {
            for x in max(0, Int(center.x) - radius)..<min(width, Int(center.x) + radius) where mask[y * width + x] != 0 {
                sumX += x
                sumY += y
                count += 1
            }
        }
        guard count > 0 else { return center }
        return CGPoint(x: Double(sumX) / Double(count), y: Double(sumY) / Double(count))
    }
}

/// 0/1 값의 누적합. 사각형 안의 개수를 O(1)로 센다.
private struct Integral {
    private let width: Int
    private var table: [Int32]

    init(values: [UInt8], width: Int, height: Int) {
        self.width = width
        table = [Int32](repeating: 0, count: (width + 1) * (height + 1))
        for y in 0..<height {
            var row: Int32 = 0
            for x in 0..<width {
                row += Int32(values[y * width + x])
                table[(y + 1) * (width + 1) + (x + 1)] = table[y * (width + 1) + (x + 1)] + row
            }
        }
    }

    /// [x0, x1) x [y0, y1)
    func sum(x0: Int, y0: Int, x1: Int, y1: Int) -> Int {
        let stride = width + 1
        return Int(table[y1 * stride + x1] - table[y0 * stride + x1] - table[y1 * stride + x0] + table[y0 * stride + x0])
    }
}
