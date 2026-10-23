import CoreGraphics
import Foundation

enum SwitcherWindowDiscovery {
    /// A WindowServer entry can outlive its AX window (for example, an Electron
    /// popup). Revalidate cached references before they can bypass server filtering.
    static func candidates<Reference>(current: [UInt32: Reference], cached: inout [UInt32: Reference],
                                      server: [[String: Any]], isValid: (UInt32, Reference) -> Bool,
                                      hasSpace: (UInt32) -> Bool,
                                      isOnVisibleSpace: (UInt32) -> Bool = { _ in false },
                                      requestedClosures: Set<UInt32> = [],
                                      allowsServerOnlyWindows: Bool = true) -> Set<UInt32> {
        // A retained NSWindow can keep its named server surface and AX reference
        // after closing. Only suppress a requested close once it leaves AXWindows
        // and all Spaces; save confirmations/cancellation keep the window listed.
        let closed = Set(requestedClosures.filter { current[$0] == nil && !hasSpace($0) })
        // Panels absent from AXWindows must not survive solely through the cache.
        // Currently exposed AX dialogs are added below regardless of their layer.
        let cacheableServerIDs = Set(server.compactMap { entry -> UInt32? in
            guard (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 else { return nil }
            return (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        })
        cached = cached.filter { !closed.contains($0.key) && cacheableServerIDs.contains($0.key) && isValid($0.key, $0.value) }
        for (id, reference) in current where isValid(id, reference) { cached[id] = reference }
        var result = Set(cached.keys)
        // Accessory apps can retain named, layer-zero backing surfaces while
        // exposing no actual windows (for example, CodexBar's menu-bar popover).
        // Require a current or validated cached AX reference for these apps;
        // their real settings windows and dialogs still remain discoverable.
        guard allowsServerOnlyWindows else { return result }
        for entry in server {
            guard (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let id = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  !closed.contains(id),
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds), frame.width > 1, frame.height > 1 else { continue }
            // Untitled server-only surfaces on a visible Space can be hidden
            // browser popups (for example, Chrome's address-bar suggestions).
            // Only apply this when AXWindows was read successfully; current and
            // valid cached AX windows already remain in result, including dialogs
            // and minimized windows. Other Spaces still need the server fallback.
            if (entry[kCGWindowName as String] as? String ?? "").isEmpty,
               isOnVisibleSpace(id) { continue }
            if !(entry[kCGWindowName as String] as? String ?? "").isEmpty
                || (frame.width >= 80 && frame.height >= 60 && hasSpace(id)) { result.insert(id) }
        }
        return result
    }
}
