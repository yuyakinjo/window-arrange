import CoreGraphics
import Foundation

enum SwitcherWindowDiscovery {
    /// Server surfaces alone are not switch destinations. All references, including
    /// cached ones, must pass the same AX and placement eligibility checks.
    static func candidates<Reference>(current: [UInt32: Reference], cached: inout [UInt32: Reference],
                                      server: [[String: Any]], isValid: (UInt32, Reference) -> Bool,
                                      hasSpace: (UInt32) -> Bool,
                                      requestedClosures: Set<UInt32> = []) -> Set<UInt32> {
        // A retained NSWindow can keep its named server surface and AX reference
        // after closing. Only suppress a requested close once it leaves AXWindows
        // and all Spaces; save confirmations/cancellation keep the window listed.
        let closed = Set(requestedClosures.filter { current[$0] == nil && !hasSpace($0) })
        let serverIDs = Set(server.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
        cached = cached.filter {
            current[$0.key] == nil && !closed.contains($0.key) && serverIDs.contains($0.key) && isValid($0.key, $0.value)
        }
        for (id, reference) in current where !closed.contains(id) {
            if isValid(id, reference) { cached[id] = reference }
            else { cached.removeValue(forKey: id) }
        }
        return Set(cached.keys)
    }
}
