import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.regular)
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--smoke-test" {
    do {
        try NativeSmoke.run(at: URL(fileURLWithPath: CommandLine.arguments[2]))
        exit(0)
    } catch {
        fputs("Native smoke failed: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}
let delegate = AppDelegate()
app.delegate = delegate
app.run()
