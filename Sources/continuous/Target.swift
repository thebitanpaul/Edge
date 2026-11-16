import Foundation
import Network
import ContinuousCore

/// Works out *which* Mac to dial and *where* it is.
///
/// These are two separate questions and conflating them was the original mistake: `--label` names
/// a pairing on this Mac, while a Bonjour service name is whatever the other Mac happens to call
/// itself. Typing the label and being told nothing was found is a bad experience, so a target may
/// now be any of: nothing at all, a pairing label, a device id, a Bonjour name, or an address.
enum Target {
    struct Resolved {
        let pairing: Pairing
        let endpoint: NWEndpoint
        /// How the endpoint was arrived at, for an honest log line.
        let via: String
    }

    static func resolve(argument: String?, store: SecretStore, config: Config,
                        explicitPairing: String?) throws -> Resolved {
        guard !store.pairings.isEmpty else { throw ContinuousError.notPaired }

        // 1. An explicit --pair always wins.
        if let needle = explicitPairing {
            let pairing = store.pairings[try store.index(matching: needle)]
            let endpoint = try locate(pairing, argument: argument, config: config)
            return Resolved(pairing: pairing, endpoint: endpoint.0, via: endpoint.1)
        }

        // 2. No argument: unambiguous only when there is exactly one pairing.
        guard let argument, !argument.isEmpty else {
            guard store.pairings.count == 1 else {
                throw ContinuousError.invalidArgument(
                    "this Mac has \(store.pairings.count) pairings — name one:\n    "
                    + store.pairings.map { "continuous connect \"\($0.label)\"" }.joined(separator: "\n    "))
            }
            let pairing = store.pairings[0]
            let endpoint = try locate(pairing, argument: nil, config: config)
            return Resolved(pairing: pairing, endpoint: endpoint.0, via: endpoint.1)
        }

        // 3. The argument names a pairing on this Mac.
        if let index = try? store.index(matching: argument) {
            let pairing = store.pairings[index]
            let endpoint = try locate(pairing, argument: nil, config: config)
            return Resolved(pairing: pairing, endpoint: endpoint.0, via: endpoint.1)
        }

        // 4. Otherwise it is an address or a Bonjour name, and the key is chosen separately.
        guard store.pairings.count == 1 else {
            throw ContinuousError.invalidArgument(
                "'\(argument)' does not match a pairing, and this Mac has \(store.pairings.count) of them.\n"
                + "  Say which key to use:  continuous connect \(argument) --pair <label>")
        }
        let pairing = store.pairings[0]
        let endpoint = try locate(pairing, argument: argument, config: config)
        return Resolved(pairing: pairing, endpoint: endpoint.0, via: endpoint.1)
    }

    /// Finds the address for a pairing, preferring live discovery over remembered state.
    private static func locate(_ pairing: Pairing, argument: String?,
                               config: Config) throws -> (NWEndpoint, String) {
        // An explicit address or Bonjour name in the argument takes precedence.
        if let argument, !argument.isEmpty {
            if looksLikeAddress(argument) {
                return (try LinkConnector.parseEndpoint(argument, defaultPort: config.port), "address you gave")
            }
            info("looking up \"\(argument)\" over Bonjour…")
            if let hit = Discovery.first(matching: { $0.serviceName.lowercased() == argument.lowercased() },
                                         timeout: 4)
                ?? Discovery.first(matching: { $0.serviceName.lowercased().contains(argument.lowercased()) },
                                   timeout: 1) {
                return (hit.endpoint, "Bonjour name \"\(hit.serviceName)\"")
            }
            warn("no Bonjour service named \"\(argument)\" — trying it as a hostname")
            return (try LinkConnector.parseEndpoint(argument, defaultPort: config.port), "hostname")
        }

        // No address given: find the Mac this pairing is pinned to.
        if let deviceID = pairing.peerDeviceID {
            info("looking for \(pairing.peerName ?? pairing.label) [\(deviceID.short)] over Bonjour…")
            if let hit = Discovery.first(matching: { $0.deviceID == deviceID }, timeout: 4) {
                return (hit.endpoint, "Bonjour, matched on device id")
            }
        }

        if let remembered = pairing.lastEndpoint {
            warn("not found over Bonjour — trying the address it was last seen on")
            return (try LinkConnector.parseEndpoint(remembered, defaultPort: config.port),
                    "last known address")
        }

        throw ContinuousError.invalidArgument("""
            could not find '\(pairing.label)' on the network.
              · is `continuous listen` running on the other Mac?
              · Bonjour is often blocked on corporate networks — connect by address instead:
                    continuous connect 192.168.1.8 --pair "\(pairing.label)"
              · `continuous discover` shows what is visible from here
            """)
    }

    /// An IPv4/IPv6 literal, a host:port, or a dotted hostname — as opposed to a friendly name.
    private static func looksLikeAddress(_ text: String) -> Bool {
        if text.hasPrefix("[") { return true }
        if text.contains(":") { return true }
        if text.contains(".") { return true }
        return text.allSatisfy { $0.isNumber }
    }
}
