import ArgumentParser
import Foundation
import ZohoBooksClient
import BookkeeperCore

struct CommonOptions: ParsableArguments {
    @Flag(name: .long, help: "Enable verbose output")
    var verbose: Bool = false
}
