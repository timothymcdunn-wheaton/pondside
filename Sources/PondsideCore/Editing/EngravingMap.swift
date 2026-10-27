/// Maps between the text that was last engraved and the text being edited.
///
/// Edits land instantly but engraving takes a moment, so for a while the
/// canvas shows music whose point-and-click links refer to an older text.
/// This map lets selection, highlighting and clicks keep working across that
/// gap: the changed span collapses, everything else maps exactly.
public struct EngravingMap: Sendable {
    public let engraved: SourceText
    private let diff: UTF16Replacement?

    public init(engraved: String, current: String) {
        self.engraved = SourceText(engraved)
        diff = TextDiff.minimalReplacement(from: engraved, to: current)
    }

    /// UTF-16 offset in the current text for one in the engraved text.
    public func currentOffset(forEngraved o: Int) -> Int {
        diff?.mapOffset(o) ?? o
    }

    /// UTF-16 offset in the engraved text for one in the current text.
    public func engravedOffset(forCurrent o: Int) -> Int {
        guard let d = diff else { return o }
        let newLength = d.replacement.utf16.count
        if o <= d.location { return o }
        if o >= d.location + newLength { return o - newLength + d.length }
        return d.location
    }

    /// The UTF-16 offset in the engraved text of a point-and-click position.
    public func engravedOffset(of position: SourcePosition) -> Int? {
        engraved.index(of: position).map { engraved.utf16Offset(of: $0) }
    }
}
