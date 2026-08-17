import ArgumentParser
import Foundation
import ZohoBooksClient
import BookkeeperCore

@main
struct ZohoBookkeeperCLI: AsyncParsableCommand {
    /// Line-buffer stdout even when piped, so long-polling commands (device-code
    /// login, sync) surface their output immediately.
    static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        await Self.main(nil)
    }

    static let configuration = CommandConfiguration(
        commandName: "zoho-bookkeeper",
        abstract: "AI-powered bookkeeping assistant for categorizing Zoho Books bank transactions",
        version: "1.0.0",
        subcommands: [Clean.self, ListAccounts.self, Audit.self, Gaps.self, Cogs.self, Receipts.self],
        defaultSubcommand: Clean.self
    )
}
