/// Plans a Space change as Dock swipes, which move one Space at a time in the order Mission Control shows.
public enum SpaceSwitchPlan {
    /// Signed number of one-Space swipes from `current` to `target` (negative is left),
    /// or nil when either Space is not on the display.
    /// `order` lists the display's Spaces, full-screen ones included, as WindowServer reports them.
    public static func steps(order: [UInt64], current: UInt64, target: UInt64) -> Int? {
        guard let from = order.firstIndex(of: current), let to = order.firstIndex(of: target) else { return nil }
        return to - from
    }
}
