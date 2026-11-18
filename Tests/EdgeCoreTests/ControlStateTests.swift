import Foundation
import Testing
import EdgeControlState

@Suite("Control Center state")
struct ControlStateTests {
    private func state(paired: Bool = true, running: Bool = true, connected: Bool = false,
                       away: Bool = false, primary: Bool = true,
                       peer: String? = "Work Mac") -> ControlState {
        ControlState(paired: paired, running: running, connected: connected,
                     pointerAway: away, isPrimary: primary, peerName: peer)
    }

    @Test("each situation gets the phase the menu would describe")
    func phases() {
        #expect(state(paired: false).phase == .notSetUp)
        #expect(state(running: false).phase == .stopped)
        #expect(state().phase == .connecting)
        #expect(state(primary: false).phase == .ready)
        #expect(state(connected: true).phase == .connected)
        #expect(state(connected: true, away: true).phase == .away)
        // Only the primary has a pointer to send away.
        #expect(state(connected: true, away: true, primary: false).phase == .connected)
    }

    @Test("on means anything but stopped or not set up")
    func isOn() {
        #expect(!state(paired: false).isOn)
        #expect(!state(running: false).isOn)
        #expect(state().isOn)
        #expect(state(primary: false).isOn)
        #expect(state(connected: true).isOn)
    }

    @Test("a tap says which way to go, so a late or repeated one is harmless")
    func tapURLs() {
        #expect(state(running: false).tapURL == ControlState.startURL)
        #expect(state().tapURL == ControlState.stopURL)
        #expect(state(connected: true).tapURL == ControlState.stopURL)
        // Nothing to start yet: open the menu, which offers Set up.
        #expect(state(paired: false).tapURL == ControlState.optionsURL)
        for url in [ControlState.startURL, ControlState.stopURL, ControlState.optionsURL] {
            #expect(url.scheme == ControlState.scheme)
        }
    }

    @Test("the peer is named only while connected")
    func subtitles() {
        #expect(state(connected: true).subtitle == "On · Work Mac")
        #expect(state(connected: true, away: true).subtitle == "On Work Mac")
        #expect(state().subtitle == "Connecting…")
        #expect(state(primary: false).subtitle == "Ready")
        #expect(state(running: false).subtitle == "Off")
        #expect(state(connected: true, peer: nil).subtitle == "On")
    }

    @Test("the file format round-trips between app and extension")
    func codable() throws {
        let original = state(connected: true)
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(ControlState.self, from: data) == original)
    }

    @Test("the file lives where the extension's sandbox exception allows")
    func fileLocation() {
        #expect(ControlState.fileURL.path.hasSuffix("/Library/Application Support/Edge/control.json"))
        #expect(!ControlState.fileURL.path.contains("/Containers/"))
    }

    @Test("control kinds and the extension share the app's bundle id prefix")
    func identifiers() {
        #expect(ControlState.extensionBundleID.hasPrefix("app.edge.cli."))
        #expect(ControlState.powerKind.hasPrefix(ControlState.extensionBundleID))
        #expect(ControlState.optionsKind.hasPrefix(ControlState.extensionBundleID))
        #expect(ControlState.powerKind != ControlState.optionsKind)
    }
}
