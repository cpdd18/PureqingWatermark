import Foundation
import CoreGraphics

// Offline anime/manga face detector using nagadomi's MIT licensed LBP model.
// The model's source and complete license are embedded in AnimeFaceCascade.json.
enum PWMAnimeFaceDetector {
    struct Weak: Decodable { let feature: Int; let subset: [UInt32]; let leaves: [Double] }
    struct Stage: Decodable { let threshold: Double; let weak: [Weak] }
    struct Model: Decodable { let features: [[Int]]; let stages: [Stage] }
    static let model: Model? = {
        guard let url = Bundle.main.url(forResource: "AnimeFaceCascade", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Model.self, from: data)
    }()

    static func detect(_ image: CGImage, using model: Model? = model) -> [CGRect] {
        guard let model else { return [] }
        let ratio = min(1, 720 / CGFloat(max(image.width, image.height)))
        let width = max(24, Int(CGFloat(image.width) * ratio))
        let height = max(24, Int(CGFloat(image.height) * ratio))
        guard let initial = grayContext(width, height) else { return [] }
        initial.interpolationQuality = .high
        initial.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let bytes = initial.data?.assumingMemoryBound(to: UInt8.self) else { return [] }
        // Histogram equalization improves detection in pale line art and dark illustrations.
        var histogram = [Int](repeating: 0, count: 256)
        for i in 0..<(width * height) { histogram[Int(bytes[i])] += 1 }
        let first = histogram.first(where: { $0 > 0 }) ?? 0
        guard first < width * height else { return [] }
        var sum = 0
        var table = [UInt8](repeating: 0, count: 256)
        for i in 0..<256 {
            sum += histogram[i]
            table[i] = UInt8(min(255, max(0, (sum - first) * 255 / (width * height - first))))
        }
        for i in 0..<(width * height) { bytes[i] = table[Int(bytes[i])] }
        guard let equalized = initial.makeImage() else { return [] }
        var hits: [CGRect] = []
        var scale: CGFloat = 1
        while Int(CGFloat(min(width, height)) / scale) >= 24 {
            if Task.isCancelled { return [] }
            let w = Int(CGFloat(width) / scale), h = Int(CGFloat(height) / scale)
            guard let context = grayContext(w, h) else { break }
            context.interpolationQuality = .high
            context.draw(equalized, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { break }
            let stride = w + 1
            var integral = [Int](repeating: 0, count: stride * (h + 1))
            for y in 0..<h {
                var row = 0
                for x in 0..<w {
                    row += Int(pixels[y * w + x])
                    integral[(y + 1) * stride + x + 1] = integral[y * stride + x + 1] + row
                }
            }
            // Precompute each LBP feature's 4 x 4 integral-image offsets.
            let offsets = model.features.map { f in
                (0..<16).map { n in (f[1] + n / 4 * f[3]) * stride + f[0] + n % 4 * f[2] }
            }
            for y in Swift.stride(from: 0, through: h - 24, by: 2) {
                if Task.isCancelled { return [] }
                for x in Swift.stride(from: 0, through: w - 24, by: 2) {
                    let origin = y * stride + x
                    var accepted = true
                    for stage in model.stages {
                        var score = 0.0
                        for weak in stage.weak {
                            let o = offsets[weak.feature]
                            func cell(_ row: Int, _ col: Int) -> Int {
                                let i = row * 4 + col
                                return integral[origin + o[i]] - integral[origin + o[i + 1]]
                                    - integral[origin + o[i + 4]] + integral[origin + o[i + 5]]
                            }
                            let center = cell(1, 1)
                            var code = 0
                            if cell(0, 0) >= center { code |= 128 }
                            if cell(0, 1) >= center { code |= 64 }
                            if cell(0, 2) >= center { code |= 32 }
                            if cell(1, 2) >= center { code |= 16 }
                            if cell(2, 2) >= center { code |= 8 }
                            if cell(2, 1) >= center { code |= 4 }
                            if cell(2, 0) >= center { code |= 2 }
                            if cell(1, 0) >= center { code |= 1 }
                            let left = (weak.subset[code >> 5] & (UInt32(1) << (code & 31))) != 0
                            score += weak.leaves[left ? 0 : 1]
                        }
                        if score < stage.threshold - 0.00001 { accepted = false; break }
                    }
                    if accepted {
                        hits.append(CGRect(x: CGFloat(x) * scale / CGFloat(width),
                                           y: CGFloat(y) * scale / CGFloat(height),
                                           width: 24 * scale / CGFloat(width),
                                           height: 24 * scale / CGFloat(height)))
                    }
                }
            }
            scale *= 1.12
        }
        return group(hits)
    }

    static func grayContext(_ width: Int, _ height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                  bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                  bitmapInfo: CGImageAlphaInfo.none.rawValue)
    }

    static func group(_ hits: [CGRect]) -> [CGRect] {
        var parent = Array(hits.indices)
        func root(_ i: Int) -> Int { var r = i; while parent[r] != r { r = parent[r] }; return r }
        for i in hits.indices {
            if Task.isCancelled { return [] }
            for j in hits.indices where j < i {
                let a = hits[i], b = hits[j]
                if abs(a.minX-b.minX) < 0.2 * min(a.width,b.width),
                   abs(a.minY-b.minY) < 0.2 * min(a.height,b.height),
                   abs(a.maxX-b.maxX) < 0.2 * min(a.width,b.width),
                   abs(a.maxY-b.maxY) < 0.2 * min(a.height,b.height) {
                    parent[root(i)] = root(j)
                }
            }
        }
        var clusters: [Int: [CGRect]] = [:]
        for i in hits.indices { clusters[root(i), default: []].append(hits[i]) }
        let boxes = clusters.values.filter { $0.count >= 4 }.map { cluster -> CGRect in
            let count = CGFloat(cluster.count)
            return CGRect(x: cluster.reduce(0) { $0+$1.minX } / count,
                          y: cluster.reduce(0) { $0+$1.minY } / count,
                          width: cluster.reduce(0) { $0+$1.width } / count,
                          height: cluster.reduce(0) { $0+$1.height } / count)
        }
        return boxes.filter { box in
            !boxes.contains { other in
                other.width > box.width * 1.2 && other.intersection(box).width * other.intersection(box).height > box.width * box.height * 0.8
            }
        }
    }
}
