import Foundation
import AppKit
import CoreGraphics
import ContinuousCore

extension Commands {

    /// Reproduces exactly what happens while the pointer is on the other Mac, on one machine,
    /// and reports numbers.
    ///
    /// This exists because the second-cursor bug survived three fixes built on plausible
    /// theories. Each one was reasoned from the documentation and each one was wrong in a way
    /// that only live hardware movement could show. So rather than guess a fourth time: hold
    /// the cursor the way a real session does, move a real mouse, and measure.
    static func cursorDoctor(_ args: Args) throws {
        let ax = Permissions.accessibility(prompt: true)
        let im = Permissions.inputMonitoring()
        out(Style.bold("Permissions"))
        if ax.isGranted { ok("Accessibility: granted") } else { bad("Accessibility: \(ax)") }
        if im.isGranted { ok("Input Monitoring: granted") } else { bad("Input Monitoring: \(im)") }
        guard ax.isGranted, im.isGranted else {
            explainCapturePermissions()
            throw ExitSilently(code: 1)
        }
        if Permissions.isRunningInsideAppBundle {
            info("running from \(Bundle.main.bundlePath)")
        } else {
            warn("running the bare binary — permissions belong to whatever launched it")
        }
        out()

        guard isatty(STDIN_FILENO) == 1 else {
            bad("this check needs you at the keyboard: it measures real mouse movement")
            throw ExitSilently(code: 1)
        }

        let screenHeight = CGDisplayBounds(CGMainDisplayID()).height
        /// AppKit's reading, flipped into the same space CoreGraphics uses.
        func appKitLocation() -> ScreenPoint {
            let p = NSEvent.mouseLocation
            return ScreenPoint(x: Double(p.x), y: Double(screenHeight - p.y))
        }

        // ---- Phase 1: no tap. Establishes that both readings follow the mouse. ----
        out(Style.bold("1. Baseline — nothing is interfering"))
        warn("move the mouse in small circles for 3 seconds…")
        var baselineCG = Set<String>()
        var baselineNS = Set<String>()
        var deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            baselineCG.insert("\(LocalPointer.location)")
            baselineNS.insert("\(appKitLocation())")
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        out("    CoreGraphics saw \(baselineCG.count) distinct positions")
        out("    AppKit saw      \(baselineNS.count) distinct positions")
        guard baselineCG.count > 3 || baselineNS.count > 3 else {
            bad("the cursor barely moved — run this again and keep the mouse moving")
            throw ExitSilently(code: 1)
        }
        ok("both readings follow the mouse when nothing is in the way")
        out()

        // ---- Phases 2 and 3: the same conditions, two shapes of callback. ----
        //
        // The only difference between them is whether the tap callback calls back into the
        // window server while it is holding one of the window server's events. That is the
        // thing under suspicion, so it is the only variable.
        struct Trial {
            let title: String
            let warpInCallback: Bool
        }
        var results: [(Trial, swallowed: Int, drift: Double, positions: Int)] = []

        for trial in [Trial(title: "2. Deleting the movement, and nothing else",
                            warpInCallback: false),
                      Trial(title: "3. Deleting it, and warping the cursor from inside the callback",
                            warpInCallback: true)] {
            out(Style.bold(trial.title))

            let park = Box(LocalPointer.liveLocation)
            let swallowed = Box<Int>(0)
            let tap = EventTap { type, event in
                switch type {
                case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
                    swallowed.mutate { $0 += 1 }
                    if trial.warpInCallback { LocalPointer.hold(at: park.value) }
                    return nil
                default:
                    return event
                }
            }
            do { try tap.start() } catch {
                bad(error.localizedDescription); explainCapturePermissions(); throw ExitSilently(code: 1)
            }
            out("    tap level: \(tap.location == .cghidEventTap ? "HID" : "session")")

            LocalPointer.allowEventsDuringWarps()
            park.value = LocalPointer.liveLocation
            LocalPointer.warp(to: park.value)
            let detached = LocalPointer.detachFromHardware()
            let hidden = LocalPointer.hide()
            out("    detach \(detached ? "ok" : "FAILED") · hide \(hidden ? "ok" : "FAILED") · parked at \(park.value)")

            warn("move the mouse in big circles for 5 seconds — watch the screen")
            var seen = Set<String>()
            var maxDrift = 0.0
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                let live = LocalPointer.liveLocation
                seen.insert("\(live)")
                maxDrift = max(maxDrift, abs(live.x - park.value.x) + abs(live.y - park.value.y))
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }

            LocalPointer.reattachToHardware()
            if hidden { LocalPointer.show() }
            tap.stop()

            out(String(format: "    %d movements deleted · cursor strayed at most %.0fpx · %d distinct positions",
                       swallowed.value, maxDrift, seen.count))
            results.append((trial, swallowed.value, maxDrift, seen.count))
            out()

            if swallowed.value == 0 {
                bad("no movement reached the tap — was the mouse moving?")
                throw ExitSilently(code: 1)
            }
        }

        // ---- Verdict ----
        out(Style.bold("Verdict"))
        let plain = results[0]
        let warping = results[1]

        if plain.drift < 6 && warping.drift >= 6 {
            ok("deleting the movement holds the cursor; warping from inside the callback breaks it")
            out()
            out("    Cursor strayed \(Int(plain.drift))px when the callback only deleted the event,")
            out("    and \(Int(warping.drift))px when it also warped the cursor. Calling back into the")
            out("    window server while holding one of its events lets events through.")
            out()
            info("this build already does the first of those. You should see one pointer.")
        } else if plain.drift < 6 && warping.drift < 6 {
            ok("the cursor was held still both ways (\(Int(plain.drift))px and \(Int(warping.drift))px)")
            out()
            out("    So the host side holds its cursor under both shapes of callback, and the")
            out("    pointer you are seeing is not this Mac's own cursor being moved by your")
            out("    mouse. Worth checking next: whether the other Mac's cursor is showing on")
            out("    the shared monitor because the monitor is switched to it.")
        } else {
            bad("the cursor strayed even with a callback that does nothing but delete the event")
            out()
            out("    \(Int(plain.drift))px over \(plain.positions) positions, \(plain.swallowed) movements deleted,")
            out("    at the \(results[0].0.warpInCallback ? "?" : "HID") level. That contradicts the measurement this")
            out("    build is based on, so please send this output — it changes the diagnosis.")
            throw ExitSilently(code: 1)
        }
    }
}