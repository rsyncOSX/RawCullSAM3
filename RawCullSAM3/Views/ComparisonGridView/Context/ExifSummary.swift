import Foundation
import RawCullCore

struct ExifSummary: Equatable {
    var exposureParts: [String]
    var gearParts: [String]
    var detailRows: [ExifDetailRow]

    var hasFooterContent: Bool {
        !exposureParts.isEmpty || !gearParts.isEmpty
    }

    static func make(from exif: ExifMetadata?) -> Self {
        guard let exif else {
            return ExifSummary(exposureParts: [], gearParts: [], detailRows: [])
        }

        var exposureParts: [String] = []
        append(exif.shutterSpeed, to: &exposureParts)
        append(exif.aperture, to: &exposureParts)
        append(exif.iso, to: &exposureParts)

        var gearParts: [String] = []
        append(exif.focalLength, to: &gearParts)
        append(exif.lensModel, to: &gearParts)
        append(exif.camera, to: &gearParts)

        var detailRows: [ExifDetailRow] = []
        appendRow("Camera", exif.camera, to: &detailRows)
        appendRow("Lens", exif.lensModel, to: &detailRows)
        appendRow("Focal Length", exif.focalLength, to: &detailRows)
        appendRow("Aperture", exif.aperture, to: &detailRows)
        appendRow("Shutter Speed", exif.shutterSpeed, to: &detailRows)
        appendRow("ISO", exif.iso, to: &detailRows)
        appendRow("RAW Type", exif.rawFileType, to: &detailRows)
        if let w = exif.pixelWidth, let h = exif.pixelHeight {
            let mp = Double(w * h) / 1_000_000
            let sizeClass = exif.rawSizeClass.map { " (\($0))" } ?? ""
            detailRows.append(ExifDetailRow(
                label: "Dimensions",
                value: String(format: "%d x %d  %.1f MP%@", w, h, mp, sizeClass),
            ))
        }

        return ExifSummary(
            exposureParts: exposureParts,
            gearParts: gearParts,
            detailRows: detailRows,
        )
    }

    private static func append(_ value: String?, to parts: inout [String]) {
        guard let value, !value.isEmpty else { return }
        parts.append(value)
    }

    private static func appendRow(
        _ label: String,
        _ value: String?,
        to rows: inout [ExifDetailRow],
    ) {
        guard let value, !value.isEmpty else { return }
        rows.append(ExifDetailRow(label: label, value: value))
    }
}
