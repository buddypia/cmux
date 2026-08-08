import Foundation

/// `cmux pilot` — inspect Pilot Mode, and turn it off.
///
/// Parsing and formatting live in `PilotModeCLI` so they are testable; this file
/// is only the socket call and the `CMUX_SURFACE_ID` read. See
/// ``PilotModeCLI/enableRefusal`` for why there is no `on`.
extension CMUXCLI {
    func runPilot(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool
    ) throws {
        let command: PilotModeCLICommand
        switch PilotModeCLI.parse(commandArgs) {
        case .failure(let message):
            throw CLIError(message: message)
        case .command(let parsed):
            command = parsed
        }

        var params: [String: Any] = [:]
        switch command.scope {
        case .global:
            break
        case .surface(let surface):
            params["surface"] = surface
        case .thisTab:
            // The same variable the agent hooks read, so this names the tab the
            // command was typed in.
            let current = ProcessInfo.processInfo.environment["CMUX_SURFACE_ID"]?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !current.isEmpty else {
                throw CLIError(
                    message: "--this-tab needs CMUX_SURFACE_ID, which is only set inside a cmux terminal."
                )
            }
            params["surface"] = current
        }

        let response = try client.sendV2(method: command.socketMethod, params: params)
        if jsonOutput {
            print(jsonString(response))
            return
        }
        print(PilotModeCLI.summary(response, didDisable: command.isDisable))
    }
}
