import CoreGraphics
import Foundation
@testable import RawCullSAM3
import Testing

// MARK: - Helpers

/// Creates an 8-bit RGBA `CGImage` of the given size.
/// `maskRect` (in pixel coords) is filled with white (alpha = 255);
/// the rest is transparent (alpha = 0).
private func makeMaskImage(
    width: Int,
    height: Int,
    maskRect: CGRect? = nil,
) throws -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let ctx = try #require(CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue,
    ))
    ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
    if let rect = maskRect {
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(rect)
    }
    return try #require(ctx.makeImage())
}

// MARK: - Coverage tests

@Suite("SAM3MaskInventoryEntry geometry — coverage")
struct SAM3MaskInventoryCoverageTests {
    @Test
    func `Full mask gives coverage 1.0`() throws {
        let image = try makeMaskImage(
            width: 10, height: 10,
            maskRect: CGRect(x: 0, y: 0, width: 10, height: 10),
        )
        let entry = SAM3MaskInventoryEntry.geometry(
            from: image,
            sourceModificationDate: nil,
            cacheModificationDate: nil,
            confidence: 0.9,
        )
        #expect(abs(entry.coverage - 1.0) < 0.01)
    }

    @Test
    func `Empty mask gives coverage 0.0`() throws {
        let image = try makeMaskImage(width: 10, height: 10)
        let entry = SAM3MaskInventoryEntry.geometry(
            from: image,
            sourceModificationDate: nil,
            cacheModificationDate: nil,
            confidence: 0.0,
        )
        #expect(entry.coverage == 0.0)
    }

    @Test
    func `Half mask gives coverage ~0.5`() throws {
        // Fill top half only
        let image = try makeMaskImage(
            width: 10, height: 10,
            maskRect: CGRect(x: 0, y: 0, width: 10, height: 5),
        )
        let entry = SAM3MaskInventoryEntry.geometry(
            from: image,
            sourceModificationDate: nil,
            cacheModificationDate: nil,
            confidence: 0.5,
        )
        #expect(abs(entry.coverage - 0.5) < 0.02)
    }
}

// MARK: - Bounding box tests

@Suite("SAM3MaskInventoryEntry geometry — bounding box")
struct SAM3MaskInventoryBoundingBoxTests {
    @Test
    func `Empty mask gives zero bounding box`() throws {
        let image = try makeMaskImage(width: 20, height: 20)
        let entry = SAM3MaskInventoryEntry.geometry(
            from: image,
            sourceModificationDate: nil,
            cacheModificationDate: nil,
            confidence: 0,
        )
        #expect(entry.boundingBox == .zero)
    }

    @Test
    func `Full mask gives bounding box (0,0,1,1)`() throws {
        let image = try makeMaskImage(
            width: 20, height: 20,
            maskRect: CGRect(x: 0, y: 0, width: 20, height: 20),
        )
        let entry = SAM3MaskInventoryEntry.geometry(
            from: image,
            sourceModificationDate: nil,
            cacheModificationDate: nil,
            confidence: 0.8,
        )
        #expect(abs(entry.boundingBox.minX) < 0.01)
        #expect(abs(entry.boundingBox.minY) < 0.01)
        #expect(abs(entry.boundingBox.width - 1.0) < 0.01)
        #expect(abs(entry.boundingBox.height - 1.0) < 0.01)
    }

    @Test
    func `Centre patch gives correctly normalised bounding box`() throws {
        // 40×40 image, mask at pixels (10,10)→(29,29) (20×20 centre square)
        let image = try makeMaskImage(
            width: 40, height: 40,
            maskRect: CGRect(x: 10, y: 10, width: 20, height: 20),
        )
        let entry = SAM3MaskInventoryEntry.geometry(
            from: image,
            sourceModificationDate: nil,
            cacheModificationDate: nil,
            confidence: 0.7,
        )
        let bb = entry.boundingBox
        #expect(abs(bb.minX - 0.25) < 0.03)
        #expect(abs(bb.minY - 0.25) < 0.03)
        #expect(abs(bb.width - 0.5) < 0.03)
        #expect(abs(bb.height - 0.5) < 0.03)
    }
}

// MARK: - Centroid tests

@Suite("SAM3MaskInventoryEntry geometry — centroid")
struct SAM3MaskInventoryCentroidTests {
    @Test
    func `Full mask centroid is ~(0.5, 0.5)`() throws {
        let image = try makeMaskImage(
            width: 20, height: 20,
            maskRect: CGRect(x: 0, y: 0, width: 20, height: 20),
        )
        let entry = SAM3MaskInventoryEntry.geometry(
            from: image,
            sourceModificationDate: nil,
            cacheModificationDate: nil,
            confidence: 0.9,
        )
        #expect(abs(entry.centroid.x - 0.5) < 0.05)
        #expect(abs(entry.centroid.y - 0.5) < 0.05)
    }

    @Test
    func `Top-left patch centroid is in the top-left quadrant`() throws {
        // Mask covers top-left quarter
        let image = try makeMaskImage(
            width: 20, height: 20,
            maskRect: CGRect(x: 0, y: 0, width: 10, height: 10),
        )
        let entry = SAM3MaskInventoryEntry.geometry(
            from: image,
            sourceModificationDate: nil,
            cacheModificationDate: nil,
            confidence: 0.6,
        )
        #expect(entry.centroid.x < 0.5)
        #expect(entry.centroid.y < 0.5)
    }
}

// MARK: - Freshness tests

@Suite("SAM3MaskInventoryEntry — freshness")
struct SAM3MaskInventoryFreshnessTests {
    @Test
    func `Cache newer than source is fresh`() throws {
        let image = try makeMaskImage(
            width: 4, height: 4,
            maskRect: CGRect(x: 0, y: 0, width: 4, height: 4),
        )
        let src = Date(timeIntervalSinceNow: -100)
        let cache = Date(timeIntervalSinceNow: -10)
        let entry = SAM3MaskInventoryEntry.geometry(
            from: image,
            sourceModificationDate: src,
            cacheModificationDate: cache,
            confidence: 0.5,
        )
        #expect(entry.isFresh == true)
    }

    @Test
    func `Cache older than source is stale`() throws {
        let image = try makeMaskImage(
            width: 4, height: 4,
            maskRect: CGRect(x: 0, y: 0, width: 4, height: 4),
        )
        let src = Date(timeIntervalSinceNow: -10)
        let cache = Date(timeIntervalSinceNow: -100)
        let entry = SAM3MaskInventoryEntry.geometry(
            from: image,
            sourceModificationDate: src,
            cacheModificationDate: cache,
            confidence: 0.5,
        )
        #expect(entry.isFresh == false)
    }
}

// MARK: - Absent entry

@Suite("SAM3MaskInventoryEntry — absent")
struct SAM3MaskInventoryAbsentTests {
    @Test
    func `Absent entry has hasMask false and zero geometry`() {
        let entry = SAM3MaskInventoryEntry.absent
        #expect(entry.hasMask == false)
        #expect(entry.confidence == 0)
        #expect(entry.coverage == 0)
        #expect(entry.boundingBox == .zero)
    }
}
