import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.regular)
var verification: WebVerification?
if let index = CommandLine.arguments.firstIndex(of: "--verify"), CommandLine.arguments.count > index + 1 {
    verification = WebVerification(root: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
    verification?.start()
    app.run()
    exit(0)
}
let delegate = AppDelegate()
app.delegate = delegate
app.run()
