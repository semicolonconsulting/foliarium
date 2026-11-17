import Foundation
import ServiceManagement

/// Open at Login, through macOS's login items. Off until the user turns it on.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Turns it on or off and returns whether it's on afterwards. If macOS wants the user's approval first,
    /// opens Login Items in System Settings.
    @discardableResult
    static func set(_ on: Bool) -> Bool {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Foliarium: could not \(on ? "register" : "unregister") the login item: \(error.localizedDescription)")
        }
        if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        return isEnabled
    }
}
