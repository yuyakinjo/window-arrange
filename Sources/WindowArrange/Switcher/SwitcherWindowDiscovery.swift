import CoreGraphics
import Foundation

enum SwitcherWindowDiscovery {
    /// A WindowServer entry can outlive its AX window (for example, an Electron
    /// popup). Revalidate cached references before they can bypass server filtering.
    static func candidates<Reference>(current: [UInt32: Reference], cached: inout [UInt32: Reference],
                                      server: [[String: Any]], isValid: (UInt32, Reference) -> Bool,
                                      hasSpace: (UInt32) -> Bool) -> Set<UInt32> {
        // Panels absent from AXWindows must not survive solely through the cache.
        // Currently exposed AX dialogs are added below regardless of their layer.
        let cacheableServerIDs = Set(server.compactMap { entry -> UInt32? in
            guard (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 else { return nil }
            return (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        })
        cached = cached.filter { cacheableServerIDs.contains($0.key) && isValid($0.key, $0.value) }
        for (id, reference) in current where isValid(id, reference) { cached[id] = reference }
        var result = Set(cached.keys)
        for entry in server {
            guard (entry[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let id = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds), frame.width > 1, frame.height > 1 else { continue }
            // Preserve ordinary windows on other Spaces even without an AX reference.
            // A missing thumbnail or title alone does not make a window invalid.
            if !(entry[kCGWindowName as String] as? String ?? "").isEmpty
                || (frame.width >= 80 && frame.height >= 60 && hasSpace(id)) { result.insert(id) }
        }
        return result
    }
}
