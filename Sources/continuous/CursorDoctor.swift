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

        // ---- Phase 2: the live conditions. ----
        out(Style.bold("2. The real thing — movement swallowed, cursor held"))
        let swallowed = Box<Int>(0)
        let tap = EventTap { type, event in
            switch type {
            case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
                swallowed.mutate { $0 += 1 }
                return nil
            default:
                return event
            }
        }
        do { try tap.start() } catch {
            bad(error.localizedDescription); explainCapturePermissions(); throw ExitSilently(code: 1)
        }
        defer { tap.stop() }
        out("    tap level: \(tap.location == .cghidEventTap ? "HID" : "session")")

        LocalPointer.allowEventsDuringWarps()
        let park = LocalPointer.location
        LocalPointer.warp(to: park)
        let detached = LocalPointer.detachFromHardware()
        let hidden = LocalPointer.hide()
        out("    detach reported \(detached ? "success" : "FAILURE")")
        out("    hide reported   \(hidden ? "success" : "FAILURE")")
        out("    parked at \(park)")

        // The same 8 ms hold the live session uses.
        let holdQueue = DispatchQueue(label: "app.continuous.doctor-hold")
        let timer = DispatchSource.makeTimerSource(queue: holdQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(2))
        timer.setEventHandler { LocalPointer.hold(at: park) }
        timer.resume()
        defer { timer.cancel() }

        out()
        warn("move the mouse in big circles for 5 seconds — watch the screen")
        var cgSeen = Set<String>()
        var nsSeen = Set<String>()
        var maxCGDrift = 0.0
        var maxNSDrift = 0.0
        deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let cg = LocalPointer.location
            let ns = appKitLocation()
            cgSeen.insert("\(cg)")
            nsSeen.insert("\(ns)")
            maxCGDrift = max(maxCGDrift, abs(cg.x - park.x) + abs(cg.y - park.y))
            maxNSDrift = max(maxNSDrift, abs(ns.x - park.x) + abs(ns.y - park.y))
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        timer.cancel()
        LocalPointer.reattachToHardware()
        if hidden { LocalPointer.show() }
        tap.stop()

        out()
        out(Style.bold("Results"))
        out("    movement events swallowed   \(swallowed.value)")
        out(String(format: "    CoreGraphics drift (max)    %.0f px   across %d positions", maxCGDrift, cgSeen.count))
        out(String(format: "    AppKit drift (max)          %.0f px   across %d positions", maxNSDrift, nsSeen.count))
        out()

        guard swallowed.value > 0 else {
            bad("no movement reached the tap at all — did the mouse move?")
            throw ExitSilently(code: 1)
        }

        // AppKit is the reading to trust: CoreGraphics' copy only advances when a movement
        // event is delivered to this process, and we are deleting all of those.
        if maxNSDrift < 6 {
            ok("the cursor was held within \(Int(maxNSDrift))px of where it was parked")
            info("if you still SAW it moving, say so — that would mean neither reading is")
            info("telling the truth, and the next step is a different approach entirely.")
        } else {
            bad("the cursor moved up to \(Int(maxNSDrift))px away despite being held every 8ms")
            out()
            out("    This is the bug. What it tells us:")
            if maxCGDrift < 6 && maxNSDrift >= 6 {
                out("      · CoreGraphics reported the cursor as stationary while AppKit saw it move,")
                out("        so any correction that checks before acting is blind here.")
            }
            out("      · \(swallowed.value) movements were deleted at the \(tap.location == .cghidEventTap ? "HID" : "session") level and the cursor moved anyway.")
            out("      · detach \(detached ? "succeeded" : "failed"), hide \(hidden ? "succeeded" : "failed"), and \(Int(5 / 0.008)) warps were issued.")
            out()
            out("    Please send this whole output.")
            throw ExitSilently(code: 1)
        }
    }
}
