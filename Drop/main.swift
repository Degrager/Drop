import SwiftUI

#if arch(x86_64)
// Drop is built for Apple Silicon only. This Intel slice exists just so an Intel Mac gets a clear
// message from the app instead of macOS's generic refusal; none of the app's own code runs here.
let intelNotice = NSApplication.shared
intelNotice.setActivationPolicy(.regular)
let intelAlert = NSAlert()
intelAlert.alertStyle = .warning
intelAlert.messageText = "Drop isn\u{2019}t supported on Intel Macs"
intelAlert.informativeText = "Drop needs a Mac with Apple Silicon (M1 or later). This Mac has an Intel processor, so Drop can\u{2019}t run on it."
intelAlert.addButton(withTitle: "Quit")
intelNotice.activate(ignoringOtherApps: true)
intelAlert.runModal()
exit(0)
#else
DropApp.main()
#endif
