import CoreGraphics

/// Flow layout: packs items of varying widths into rows in order, wrapping when the next item doesn't fit
/// (the Frost Bar icon grid).
///
/// A pure function shared by the SwiftUI `Layout` and the panel size calculation, so both wrap identically.
public enum FlowRows {
    /// Tolerance when comparing widths: when re-laying out with a row's own width as the limit, floating-point
    /// error must not wrap the last item.
    static let tolerance: CGFloat = 0.5

    /// The index range in each row. A single item wider than `maxWidth` gets a row of its own (the caller clips
    /// or scales it).
    public static func pack(_ widths: [CGFloat], maxWidth: CGFloat, spacing: CGFloat) -> [Range<Int>] {
        var rows: [Range<Int>] = []
        var start = 0
        var rowWidth: CGFloat = 0
        for (index, width) in widths.enumerated() {
            if index > start, rowWidth + spacing + width > maxWidth + tolerance {
                rows.append(start..<index)
                start = index
                rowWidth = width
            } else {
                rowWidth += index > start ? spacing + width : width
            }
        }
        if start < widths.count { rows.append(start..<widths.count) }
        return rows
    }

    /// The width of a row (item widths + spacing).
    public static func width(of row: Range<Int>, in widths: [CGFloat], spacing: CGFloat) -> CGFloat {
        guard !row.isEmpty else { return 0 }
        return row.reduce(0) { $0 + widths[$1] } + CGFloat(row.count - 1) * spacing
    }

    /// Total size after layout: the widest row's width, and the stacked (equal) row heights.
    public static func size(_ widths: [CGFloat], maxWidth: CGFloat, spacing: CGFloat,
                            rowHeight: CGFloat, lineSpacing: CGFloat) -> CGSize {
        let rows = pack(widths, maxWidth: maxWidth, spacing: spacing)
        guard !rows.isEmpty else { return .zero }
        let width = rows.map { self.width(of: $0, in: widths, spacing: spacing) }.max() ?? 0
        let height = CGFloat(rows.count) * rowHeight + CGFloat(rows.count - 1) * lineSpacing
        return CGSize(width: width, height: height)
    }
}
