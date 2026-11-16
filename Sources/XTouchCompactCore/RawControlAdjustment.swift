/// Accessible raw MIDI controls must reach every valid value, rather than the
/// platform slider's default ten-percent jump. The same bounds apply to pointer input.
public enum RawControlAdjustment {
    public static func next(_ value: UInt8, increment: Bool) -> UInt8 {
        UInt8(min(127, max(0, Int(value) + (increment ? 1 : -1))))
    }
}
