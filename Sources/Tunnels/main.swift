import Foundation

signal(SIGPIPE, SIG_IGN)

let cliArgs = Array(CommandLine.arguments.dropFirst())
if let first = cliArgs.first, CLI.commands.contains(first) {
    exit(CLI.run(cliArgs))
}

// 已有实例在运行时不再起第二个
if ControlClient.send(ControlRequest(cmd: "ping"), timeout: 1) != nil {
    exit(0)
}

TunnelsApp.main()
