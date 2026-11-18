import AppIntents
import AppKit
import EdgeControlState
import SwiftUI
import WidgetKit

/// Edge in Control Center.
///
/// The switch, on and off like the Dock's auto-hide or Wi-Fi: on opens Edge if it is not
/// running and starts it; off is Quit, leaving nothing running behind. Edge Options, added
/// only by those who want it, opens Edge's whole menu — everything else, without the
/// menu-bar icon.
@available(macOS 26.0, *)
struct EdgeControls: WidgetBundle {
    var body: some Widget {
        PowerControl()
        OptionsControl()
    }
}

@available(macOS 26.0, *)
struct StateProvider: ControlValueProvider {
    var previewValue: ControlState { ControlState(phase: .connected, peerName: "Other Mac") }

    /// No file means the app has not written one yet, or quit and said so: off.
    func currentValue() async throws -> ControlState {
        ControlState.read() ?? ControlState(phase: .stopped)
    }
}

@available(macOS 26.0, *)
struct PowerControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: ControlState.powerKind,
                                   provider: StateProvider()) { state in
            ControlWidgetToggle(isOn: state.isOn, action: PowerIntent()) {
                Label("Edge", systemImage: state.symbol)
            } valueLabel: { isOn in
                // `isOn` flips the moment it is tapped, before Edge has caught up; say what is
                // happening rather than show the old state under the new switch position.
                Label(isOn == state.isOn ? state.subtitle : (isOn ? "Starting…" : "Quitting…"),
                      systemImage: isOn ? "cursorarrow.rays" : "cursorarrow.slash")
            }
            .tint(.blue)
        }
        .displayName("Edge")
        .description("Turn Edge on, or off to quit it.")
    }
}

@available(macOS 26.0, *)
struct OptionsControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: ControlState.optionsKind) {
            ControlWidgetButton("Edge Options", action: OptionsIntent()) { _ in
                Label("Options", systemImage: "chevron.right")
            }
        }
        .displayName("Edge Options")
        .description("Edge's menu: devices, screen arrangement, settings and Quit.")
    }
}

/// Opens Edge's menu where the control was clicked. Described to macOS alongside
/// `PowerIntent`; the same rules about renaming apply.
@available(macOS 26.0, *)
struct OptionsIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Edge options"

    init() {}

    func perform() async throws -> some IntentResult {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try? await NSWorkspace.shared.open(ControlState.optionsURL, configuration: configuration)
        return .result()
    }
}

/// What a tap does. Its shape is described to macOS in Metadata.appintents, which
/// Scripts/build.sh writes from Resources/ControlsMetadata.json — rename this type, its module
/// or its parameter, and that file has to follow, or taps stop doing anything.
@available(macOS 26.0, *)
struct PowerIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Turn Edge on or off"

    @Parameter(title: "Edge is on")
    var value: Bool

    init() {}

    func perform() async throws -> some IntentResult {
        // The extension is sandboxed and cannot reach the app any other way. A link also
        // works when Edge is not running: Launch Services starts it first.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try? await NSWorkspace.shared.open(value ? ControlState.startURL : ControlState.stopURL,
                                               configuration: configuration)

        // Control Center redraws the moment this returns. Waiting for Edge to say it got
        // there keeps the switch from flicking back while the app is still starting.
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            if (ControlState.read()?.isOn ?? false) == value { break }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return .result()
    }
}
