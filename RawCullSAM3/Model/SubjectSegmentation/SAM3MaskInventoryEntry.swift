import CoreGraphics
import Foundation

/// Lightweight geometry and quality metadata for one cached SAM 3 mask.
/// Computed once from the disk cache after catalog open; consumed by badges,
/// filters, sharpness weighting, and export without re-decoding PNG masks.
nonisolated struct SAM3MaskInventoryEntry {
    /// `true` when a valid SAM 3 mask is cached for this file.
    let hasMask: Bool
    /// SAM 3 model confidence score in the range 0–1.
    let confidence: Float
    /// Fraction of image pixels covered by the mask, in the range 0–1.
    let coverage: Float
    /// Axis-aligned bounding box of mask pixels, normalised to 0–1 in (x, y, width, height).
    let boundingBox: CGRect
    /// Weighted centroid of mask pixels, normalised to 0–1.
    let centroid: CGPoint
    /// `true` when the cache entry is newer than the source file's modification date.
    let isFresh: Bool
}

// MARK: - Geometry helpers

extension SAM3MaskInventoryEntry {
    /// Extracts geometry from the alpha channel of `mask`.
    /// Returns `nil` only when the image has no pixels.
    nonisolated static func geometry(
        from mask: CGImage,
        sourceModificationDate: Date?,
        cacheModificationDate: Date?,
        confidence: Float,
    ) -> SAM3MaskInventoryEntry {
        let width = mask.width
        let height = mask.height
        guard width > 0, height > 0 else {
            return SAM3MaskInventoryEntry(
                hasMask: true,
                confidence: confidence,
                coverage: 0,
                boundingBox: .zero,
                centroid: CGPoint(x: 0.5, y: 0.5),
                isFresh: true,
            )
        }

        // Render mask into a 1-channel (alpha-only) buffer using vImage.
        let alphaPlane = extractAlphaPlane(from: mask, width: width, height: height)

        let coverage = computeCoverage(alphaPlane: alphaPlane, width: width, height: height)
        let boundingBox = computeBoundingBox(alphaPlane: alphaPlane, width: width, height: height)
        let centroid = computeCentroid(alphaPlane: alphaPlane, width: width, height: height)

        let isFresh: Bool = if let src = sourceModificationDate, let cache = cacheModificationDate {
            cache >= src
        } else {
            true
        }

        return SAM3MaskInventoryEntry(
            hasMask: true,
            confidence: confidence,
            coverage: coverage,
            boundingBox: boundingBox,
            centroid: centroid,
            isFresh: isFresh,
        )
    }

    /// Returns an entry representing a missing or invalid mask.
    nonisolated static var absent: SAM3MaskInventoryEntry {
        SAM3MaskInventoryEntry(
            hasMask: false,
            confidence: 0,
            coverage: 0,
            boundingBox: .zero,
            centroid: CGPoint(x: 0.5, y: 0.5),
            isFresh: false,
        )
    }
}

// MARK: - Private pixel helpers

private nonisolated func extractAlphaPlane(from image: CGImage, width: Int, height: Int) -> [UInt8] {
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
    ) else {
        return []
    }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    // Extract every 4th byte (alpha channel at index 3).
    var alpha = [UInt8](repeating: 0, count: width * height)
    for i in 0 ..< width * height {
        alpha[i] = pixels[i * 4 + 3]
    }
    return alpha
}

private nonisolated func computeCoverage(alphaPlane: [UInt8], width: Int, height: Int) -> Float {
    guard !alphaPlane.isEmpty else { return 0 }
    let total = width * height
    var nonZero = 0
    for v in alphaPlane where v > 0 {
        nonZero += 1
    }
    return Float(nonZero) / Float(total)
}

private nonisolated func computeBoundingBox(alphaPlane: [UInt8], width: Int, height: Int) -> CGRect {
    guard !alphaPlane.isEmpty else { return .zero }
    var minX = width, maxX = -1, minY = height, maxY = -1
    for row in 0 ..< height {
        for col in 0 ..< width {
            if alphaPlane[row * width + col] > 0 {
                if col < minX { minX = col }
                if col > maxX { maxX = col }
                if row < minY { minY = row }
                if row > maxY { maxY = row }
            }
        }
    }
    guard maxX >= minX, maxY >= minY else { return .zero }
    let fw = CGFloat(width)
    let fh = CGFloat(height)
    return CGRect(
        x: CGFloat(minX) / fw,
        y: CGFloat(minY) / fh,
        width: CGFloat(maxX - minX + 1) / fw,
        height: CGFloat(maxY - minY + 1) / fh,
    )
}

private nonisolated func computeCentroid(alphaPlane: [UInt8], width: Int, height: Int) -> CGPoint {
    guard !alphaPlane.isEmpty else { return CGPoint(x: 0.5, y: 0.5) }
    var sumX: Double = 0, sumY: Double = 0, sumW: Double = 0
    for row in 0 ..< height {
        for col in 0 ..< width {
            let w = Double(alphaPlane[row * width + col])
            if w > 0 {
                sumX += Double(col) * w
                sumY += Double(row) * w
                sumW += w
            }
        }
    }
    guard sumW > 0 else { return CGPoint(x: 0.5, y: 0.5) }
    return CGPoint(
        x: (sumX / sumW) / Double(width),
        y: (sumY / sumW) / Double(height),
    )
}
