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

        // ---- Trials. Same conditions, three shapes of cursor-holding. ----
        //
        // Sampled every millisecond, on its own queue. The previous version of this check
        // sampled every ten and concluded the cursor never moved, when in truth a timer was
        // putting it back between samples. A sampler slower than the thing it is measuring
        // can only ever report success.
        struct Trial {
            let title: String
            let note: String
            let warpInCallback: Bool
            let holdTimer: Bool
        }
        let trials = [
            Trial(title: "2. Delete the movement, nothing else",
                  note: "what the event tap is supposed to achieve on its own",
                  warpInCallback: false, holdTimer: false),
            Trial(title: "3. Delete it, and re-park on a background timer",
                  note: "what this build does",
                  warpInCallback: false, holdTimer: true),
            Trial(title: "4. Delete it, and warp from inside the tap callback",
                  note: "what the previous build did",
                  warpInCallback: true, holdTimer: false),
        ]
        var results: [(trial: Trial, swallowed: Int, drift: Double, samples: Int)] = []

        for trial in trials {
            out(Style.bold(trial.title))
            out(Style.dim("    \(trial.note)"))

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

            LocalPointer.allowEventsDuringWarps()
            park.value = LocalPointer.liveLocation
            LocalPointer.warp(to: park.value)
            let detached = LocalPointer.detachFromHardware()
            let hidden = LocalPointer.hide()
            out("    tap \(tap.location == .cghidEventTap ? "HID" : "session") · detach \(detached ? "ok" : "FAILED") · hide \(hidden ? "ok" : "FAILED") · parked at \(park.value)")

            let queue = DispatchQueue(label: "app.continuous.doctor")
            let parked = park.value

            var holdTimer: DispatchSourceTimer?
            if trial.holdTimer {
                let t = DispatchSource.makeTimerSource(queue: queue)
                t.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(2))
                t.setEventHandler { LocalPointer.hold(at: parked) }
                holdTimer = t
                t.resume()
            }

            let drift = Box<Double>(0)
            let samples = Box<Int>(0)
            let sampler = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "app.continuous.doctor.sample"))
            sampler.schedule(deadline: .now(), repeating: .milliseconds(1), leeway: .microseconds(200))
            sampler.setEventHandler {
                let live = LocalPointer.liveLocation
                let d = abs(live.x - parked.x) + abs(live.y - parked.y)
                samples.mutate { $0 += 1 }
                drift.mutate { if d > $0 { $0 = d } }
            }
            sampler.resume()

            warn("move the mouse in big circles for 5 seconds — watch the screen")
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }

            sampler.cancel()
            holdTimer?.cancel()
            LocalPointer.reattachToHardware()
            if hidden { LocalPointer.show() }
            tap.stop()
            LocalPointer.warp(to: parked)

            out(String(format: "    %d movements deleted · strayed at most %.0fpx · %d samples",
                       swallowed.value, drift.value, samples.value))
            results.append((trial, swallowed.value, drift.value, samples.value))
            out()

            if swallowed.value == 0 {
                bad("no movement reached the tap — was the mouse moving?")
                throw ExitSilently(code: 1)
            }
        }

        // ---- Verdict ----
        out(Style.bold("Verdict"))
        let deleteOnly = results[0]
        let withTimer = results[1]
        let withWarp = results[2]
        let quiet = 8.0

        out(String(format: "    delete only          %5.0f px", deleteOnly.drift))
        out(String(format: "    delete + timer       %5.0f px   ← this build", withTimer.drift))
        out(String(format: "    delete + warp inside %5.0f px   ← previous build", withWarp.drift))
        out()

        if withTimer.drift < quiet {
            ok("this build holds the cursor still")
            if deleteOnly.drift >= quiet {
                info("deleting the event alone is not enough on this Mac — the timer is doing")
                info("the work, which is why it is on by default.")
            } else {
                info("deleting the event is enough on its own here; the timer is spare capacity.")
            }
            if withWarp.drift >= quiet {
                info("and warping from inside the callback does break it, as suspected.")
            }
        } else {
            bad("the cursor strayed \(Int(withTimer.drift))px even as this build holds it")
            out()
            out("    Every mechanism available has now been measured and none of them hold")
            out("    the cursor on this Mac. That rules out the approach, not the details.")
            out("    Please send this whole output — the next step is to stop trying to hold")
            out("    the cursor and take the input device away from the window server instead.")
            throw ExitSilently(code: 1)
        }
    }
}