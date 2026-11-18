import AppIntents
import EdgeControlState
import SwiftUI
import WidgetKit

/// Edge in Control Center: one control to start and stop, one to open everything else.
///
/// Two controls rather than one with a "›" beside it, because that split tile is something
/// only Apple's own modules can draw. Set Edge to medium and Options to small, side by side,
/// and the pair reads the way Wi-Fi does.
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

    /// No file means the app has never run, or is not running to have written one: off.
    func currentValue() async throws -> ControlState {
        ControlState.read() ?? ControlState(phase: .stopped)
    }
}

@available(macOS 26.0, *)
struct PowerControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: ControlState.powerKind,
                                   provider: StateProvider()) { state in
            ControlWidgetButton("Edge", action: OpenURLIntent(state.tapURL)) { _ in
                Label(state.subtitle, systemImage: state.symbol)
            }
            .tint(state.isOn ? .blue : nil)
        }
        .displayName("Edge")
        .description("Start or stop sharing one keyboard and mouse between your Macs.")
    }
}

@available(macOS 26.0, *)
struct OptionsControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: ControlState.optionsKind) {
            ControlWidgetButton("Edge Options",
                                action: OpenURLIntent(ControlState.optionsURL)) { _ in
                Label("Options", systemImage: "chevron.right")
            }
        }
        .displayName("Edge Options")
        .description("Everything in Edge's menu, including Quit.")
    }
}
