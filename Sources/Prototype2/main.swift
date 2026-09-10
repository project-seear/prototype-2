import AppKit
import Foundation

// Line-buffer stdout so per-trial log lines appear immediately when piped.
setvbuf(stdout, nil, _IOLBF, 0)

let app = NSApplication.shared
let controller = Controller()
app.delegate = controller
app.setActivationPolicy(.regular)
app.run()
