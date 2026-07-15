import AppKit

// Classic AppKit entry point (Section 2.5): the AppDelegate owns the status
// item and windows; SwiftUI is used only for view content, never the app
// lifecycle. This is a deliberate departure from SwiftUI's `App`/
// `MenuBarExtra` lifecycle, which does not reliably provide the precise
// NSStatusItem/activation-policy control this product needs.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
