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
                        explicitPairing: String?, localDeviceID: DeviceID? = nil,
                        attempt: Int = 1) throws -> Resolved {
        guard !store.pairings.isEmpty else { throw ContinuousError.notPaired }

        // 1. An explicit --pair always wins.
        if let needle = explicitPairing {
            let pairing = store.pairings[try store.index(matching: needle)]
            let endpoint = try locate(pairing, argument: argument, config: config,
                                      localDeviceID: localDeviceID, attempt: attempt)
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
            let endpoint = try locate(pairing, argument: nil, config: config,
                                      localDeviceID: localDeviceID, attempt: attempt)
            return Resolved(pairing: pairing, endpoint: endpoint.0, via: endpoint.1)
        }

        // 3. The argument names a pairing on this Mac.
        if let index = try? store.index(matching: argument) {
            let pairing = store.pairings[index]
            let endpoint = try locate(pairing, argument: nil, config: config,
                                      localDeviceID: localDeviceID, attempt: attempt)
            return Resolved(pairing: pairing, endpoint: endpoint.0, via: endpoint.1)
        }

        // 4. Otherwise it is an address or a Bonjour name, and the key is chosen separately.
        guard store.pairings.count == 1 else {
            throw ContinuousError.invalidArgument(
                "'\(argument)' does not match a pairing, and this Mac has \(store.pairings.count) of them.\n"
                + "  Say which key to use:  continuous connect \(argument) --pair <label>")
        }
        let pairing = store.pairings[0]
        let endpoint = try locate(pairing, argument: argument, config: config,
                                  localDeviceID: localDeviceID, attempt: attempt)
        return Resolved(pairing: pairing, endpoint: endpoint.0, via: endpoint.1)
    }

    /// Finds the address for a pairing, preferring live discovery over remembered state.
    private static func locate(_ pairing: Pairing, argument: String?, config: Config,
                               localDeviceID: DeviceID?, attempt: Int) throws -> (NWEndpoint, String) {
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

        // An address you typed in comes first — you know something discovery does not.
        //
        // Except every third attempt, so a stale one cannot trap the connection for ever: if
        // the other Mac moved to a new address, discovery gets a turn to find it.
        if let manual = pairing.manualEndpoint, !manual.isEmpty, attempt % 3 != 0 {
            info("trying \(manual), the address set for '\(pairing.label)'")
            return (try LinkConnector.parseEndpoint(manual, defaultPort: config.port),
                    "the address you set")
        }

        // Otherwise look for it on the network.
        //
        // Note what is *not* required here: a peer device id. A pairing that has never
        // connected does not have one — it is learned from the first handshake — so gating
        // discovery on it meant a fresh pairing could never be found, however well Bonjour
        // was working. That is safe to drop because discovery is not a trust boundary: a Mac
        // that does not hold the pairing key cannot finish the TLS handshake.
        if pairing.peerDeviceID != nil {
            info("looking for \(pairing.peerName ?? pairing.label)…")
        } else {
            info("looking for any Mac running Continuous…")
        }
        // Longer than three seconds after the first attempt. A browse started moments after
        // the other Mac's service went away and came back routinely sees nothing, and an
        // empty browse is not harmless here: it drops through to the fallbacks below, which
        // are routed addresses. That is how a session that was on the cable the first time
        // comes back on Wi-Fi, and a 2 ms link becoming a 200 ms one is felt immediately as
        // a pointer that drags.
        let seen = Discovery.scan(duration: attempt == 1 ? 3 : 5)
        if let hit = PeerSelection.choose(from: seen,
                                          boundTo: pairing.peerDeviceID,
                                          excluding: localDeviceID,
                                          attempt: attempt) {
            guard let endpoint = hit.endpoint(preferring: config.link) else {
                throw ContinuousError.invalidArgument(
                    "'\(pairing.label)' is on the network, but not over a cable.\n"
                    + "  Connect a USB-C or Thunderbolt cable between the two Macs, or allow\n"
                    + "  any link:  menu bar ▸ Connect over ▸ Whichever connects, or\n"
                    + "      continuous config set preferredLink auto")
            }
            let how: String
            if let cable = hit.cableAddress, config.link.prefersCable {
                how = "cable, \(cable)"
            } else if pairing.peerDeviceID == nil {
                how = "Bonjour, \"\(hit.serviceName)\""
            } else {
                how = "Bonjour, matched on device id"
            }
            return (endpoint, how)
        }
        if seen.isEmpty {
            Log.debug("nothing advertising — Bonjour is blocked on many managed networks")
        } else {
            Log.debug("\(seen.count) Mac(s) advertising, none matching this pairing")
        }

        // A cable address that worked before, ahead of any name.
        //
        // The order here is the whole point. A hostname resolves over the routed network, so
        // reaching for it first means a cable link silently becomes a Wi-Fi one the moment a
        // browse comes up empty — which it does for a few seconds after either Mac restarts
        // its session. The connection still succeeds, which is why this was never reported as
        // a failure, only as "it feels slower than it did the first time".
        if config.link.prefersCable, let last = pairing.lastEndpoint,
           NetworkAddress.isCableEndpoint(last) {
            info("trying \(last), the cable address it answered on last time")
            return (try LinkConnector.parseEndpoint(last, defaultPort: config.port),
                    "cable, \(last)")
        }

        // Everything below this line is a routed address, so none of it will do when a cable
        // is the only acceptable link. Say so rather than connecting over the wrong one.
        if config.link.requiresCable {
            throw ContinuousError.invalidArgument("""
                '\(pairing.label)' is set to connect over a cable, and no cable was found.
                  · check the USB-C or Thunderbolt cable between the two Macs
                  · or allow any link:  menu bar ▸ Connect over ▸ Whichever connects
                """)
        }

        // mDNS *name* resolution usually survives where browsing does not, because it is an
        // ordinary hostname lookup rather than a service enumeration.
        if let host = pairing.peerHostName ?? pairing.peerName.map(Identity.mdnsName(from:)),
           !host.isEmpty {
            let candidate = host.hasSuffix(".local") ? host : host + ".local"
            info("trying \(candidate)")
            return (try LinkConnector.parseEndpoint(candidate, defaultPort: config.port),
                    "Wi-Fi, \(candidate)")
        }

        if let remembered = pairing.lastEndpoint {
            warn("no name to go on — trying the address it was last seen on")
            return (try LinkConnector.parseEndpoint(remembered, defaultPort: config.port),
                    "last known address")
        }

        // Deliberately no example address here: an invented one reads like a fact, and a
        // reader has no way to tell it apart from something this Mac actually knows.
        throw ContinuousError.invalidArgument("""
            could not find '\(pairing.label)' on the network.
              · is the other Mac started, and set to the opposite role?
              · Bonjour is blocked on many managed networks. Set the other Mac's address:
                    menu bar ▸ Devices ▸ \(pairing.label) ▸ Set address
                    continuous connect <address> --pair "\(pairing.label)"
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
