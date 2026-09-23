import AppKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let bundleID = CommandLine.arguments[1]
let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    .filter { !$0.isTerminated }
for application in running {
    guard application.terminate() else { fail("Could not quit \(bundleID). Quit it before rebuilding.") }
}
let deadline = Date().addingTimeInterval(30)
while running.contains(where: { !$0.isTerminated }) && Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
}
guard running.allSatisfy(\.isTerminated) else {
    fail("Quit was cancelled or timed out; the build was not installed.")
}
