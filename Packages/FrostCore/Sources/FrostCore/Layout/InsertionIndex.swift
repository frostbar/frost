import CoreGraphics

public enum InsertionIndex {
    /// - Parameters:
    ///   - dropX: The x of the drop location (same coordinate space as tileMidXs, horizontal scroll offset
    ///     included).
    ///   - tileMidXs: The midX of every tile currently shown in the section, left to right.
    ///   - draggedIndex: The dragged tile's index in the section; nil when dragged in from another section.
    /// - Returns: The insertion position in the list with the dragged item removed.
    public static func compute(dropX: CGFloat, tileMidXs: [CGFloat], draggedIndex: Int?) -> Int {
        var mids = tileMidXs
        if let draggedIndex, mids.indices.contains(draggedIndex) { mids.remove(at: draggedIndex) }
        return mids.firstIndex { dropX < $0 } ?? mids.count
    }
}
