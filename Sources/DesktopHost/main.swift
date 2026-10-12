import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.regular)
// 本地重建后系统可能仍缓存默认图标，启动时直接加载包内图标用于 Dock。
if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
   let icon = NSImage(contentsOf: iconURL) {
    app.applicationIconImage = icon
}
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
