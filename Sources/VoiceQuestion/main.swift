import AppKit
import VQCore

// One binary: the menu-bar app when started without arguments, a command-line tool otherwise.
let arguments = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("-psn_") }

if let first = arguments.first, first != "app" {
    CLI.run(arguments)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
