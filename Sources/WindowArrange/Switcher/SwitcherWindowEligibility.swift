import ApplicationServices
import CoreGraphics

/// Discovery rules follow AltTab's WindowAdmissionResolver. Keep this independent
/// of AX calls so the same verdict covers fresh, cached and other-Space windows.
enum SwitcherWindowEligibility {
    static func includes(frame: CGRect, level: Int, title: String, role: String?, subrole: String?,
                         main: Bool, fullscreen: Bool, focused: Bool) -> Bool {
        guard frame.width > 1, frame.height > 1, level >= 0 else { return false }
        if subrole == kAXFloatingWindowSubrole || subrole == "AXSystemDialog" { return false }
        guard level == 0 || main || fullscreen else { return false }
        // Focus fills missing semantics, but cannot override a non-window role
        // unless ordinary discovery already admits the window (for example Emacs).
        if focused && (role == nil || role == kAXWindowRole) { return true }
        if role == kAXWindowRole && main { return true }
        if subrole == kAXStandardWindowSubrole { return true }
        if subrole == kAXDialogSubrole { return !title.isEmpty }
        return role == kAXWindowRole && !title.isEmpty && frame.width >= 100 && frame.height >= 50
    }
}
