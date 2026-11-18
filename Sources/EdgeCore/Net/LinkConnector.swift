import Foundation
import Network

/// Dials out to a listening Mac. Runs on the Mac that owns the keyboard and mouse.
public enum LinkConnector {
    public static func connect(to endpoint: NWEndpoint,
                               psk: Data,
                               identity: Identity,
                               localRole: Role,
                               capabilities: Capabilities = .baseline,
                               link: LinkPreference = .auto,
                               handshakeTimeout: TimeInterval = 10,
                               queue: DispatchQueue = DispatchQueue(label: "app.edge.connector")) -> SecureLink {
        let params = TLSConfig.parameters(keys: [PSKEntry(psk: psk)], link: link)
        params.includePeerToPeer = true
        let connection = NWConnection(to: endpoint, using: params)
        return SecureLink(connection: connection,
                          role: .initiator,
                          identity: identity,
                          localRole: localRole,
                          capabilities: capabilities,
                          outboundPSK: psk,
                          handshakeTimeout: handshakeTimeout,
                          queue: queue)
    }

    /// Accepts `host`, `host:port`, `[v6]:port`, or a bare Bonjour service name.
    public static func parseEndpoint(_ text: String, defaultPort: UInt16) throws -> NWEndpoint {
        if text.hasPrefix("[") , let close = text.firstIndex(of: "]") {
            let host = String(text[text.index(after: text.startIndex)..<close])
            var port = defaultPort
            let rest = text[text.index(after: close)...]
            if rest.hasPrefix(":"), let p = UInt16(rest.dropFirst()) { port = p }
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                throw EdgeError.invalidArgument("invalid port in '\(text)'")
            }
            return .hostPort(host: NWEndpoint.Host(host), port: nwPort)
        }

        var host = text
        var port = defaultPort
        // Only treat a trailing ":NNNN" as a port when there is exactly one colon,
        // so a bare IPv6 literal is not mangled.
        if text.filter({ $0 == ":" }).count == 1,
           let idx = text.lastIndex(of: ":"),
           let p = UInt16(text[text.index(after: idx)...]) {
            host = String(text[text.startIndex..<idx])
            port = p
        }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw EdgeError.invalidArgument("invalid port in '\(text)'")
        }
        guard !host.isEmpty else {
            throw EdgeError.invalidArgument("missing host in '\(text)'")
        }
        return .hostPort(host: NWEndpoint.Host(host), port: nwPort)
    }
}
