import AppKit

guard CommandLine.arguments.count == 2, let pid = Int32(CommandLine.arguments[1]),
      let app = NSRunningApplication(processIdentifier: pid) else { exit(2) }
guard app.terminate() else { fputs("Normal quit was refused.\n", stderr); exit(1) }
let deadline = Date().addingTimeInterval(10)
while !app.isTerminated && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
guard app.isTerminated else { fputs("The app did not complete its normal quit.\n", stderr); exit(1) }
print("PASS normal app quit completed")
