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

    @Test("the switch says which way to go, so a late or repeated tap is harmless")
    func links() {
        #expect(ControlState.startURL != ControlState.stopURL)
        for url in [ControlState.startURL, ControlState.stopURL] {
            #expect(url.scheme == ControlState.scheme)
        }
        #expect(ControlState.startURL.host == "start")
        #expect(ControlState.stopURL.host == "stop")
    }

    @Test("the peer is named only while connected")
    func subtitles() {
        #expect(state(connected: true).subtitle == "On · Work Mac")
        #expect(state(connected: true, away: true).subtitle == "Pointer on Work Mac")
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

    @Test("the control kind and the extension share the app's bundle id prefix")
    func identifiers() {
        #expect(ControlState.extensionBundleID.hasPrefix("app.edge.cli."))
        #expect(ControlState.powerKind.hasPrefix(ControlState.extensionBundleID))
        #expect(ControlState.optionsKind.hasPrefix(ControlState.extensionBundleID))
        #expect(ControlState.powerKind != ControlState.optionsKind)
        #expect(ControlState.optionsURL.scheme == ControlState.scheme)
    }

    @Test("the action metadata template matches the intent it describes")
    func metadataTemplate() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/ControlsMetadata.json")
        let root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url))
                                as? [String: Any])
        let actions = try #require(root["actions"] as? [String: Any])
        let power = try #require(actions["PowerIntent"] as? [String: Any])
        #expect(power["fullyQualifiedTypeName"] as? String == "EdgeControls.PowerIntent")
        #expect(power["mangledTypeName"] as? String == "__POWER_INTENT_TYPE__")
        #expect((power["systemProtocols"] as? [String]) == ["com.apple.link.systemProtocol.SetValue"])
        let parameters = try #require(power["parameters"] as? [[String: Any]])
        #expect(parameters.map { $0["name"] as? String } == ["value"])

        let options = try #require(actions["OptionsIntent"] as? [String: Any])
        #expect(options["fullyQualifiedTypeName"] as? String == "EdgeControls.OptionsIntent")
        #expect(options["mangledTypeName"] as? String == "__OPTIONS_INTENT_TYPE__")
        #expect((options["parameters"] as? [Any])?.isEmpty == true)
    }
}
