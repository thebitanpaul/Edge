import Testing
import Foundation
@testable import ContinuousCore

private func display(_ x: Int32, _ y: Int32, _ w: Int32, _ h: Int32, main: Bool = false) -> Display {
    Display(x: x, y: y, width: w, height: h, isMain: main)
}

/// The sending Mac: a laptop with the switchable monitor attached, work Mac on the right.
private let localScreens = [display(0, 0, 1470, 956, main: true), display(1470, 32, 1920, 1080)]
private let remoteScreens = [display(0, 0, 1512, 982, main: true)]

private func router(edge: ScreenEdge = .right,
                    alignment: ScreenAlignment = .proportional,
                    local: [Display] = localScreens,
                    remote: [Display] = remoteScreens) -> PointerRouter {
    PointerRouter(layout: ScreenLayout(localDisplays: local, remoteDisplays: remote,
                                       edge: edge, alignment: alignment)!)
}

private let push = ScreenPoint(x: 8, y: 0)
private let pull = ScreenPoint(x: -8, y: 0)

/// Leans on the shared edge until the pointer goes through, the way a hand would.
@discardableResult
private func crossOver(_ r: inout PointerRouter,
                       at point: ScreenPoint = ScreenPoint(x: 3389, y: 556)) -> ScreenPoint? {
    for _ in 0..<40 {
        if case let .cross(entry) = r.pointerMoved(localLocation: point, delta: push) {
            return entry
        }
    }
    return nil
}

@Suite("Pointer routing")
struct PointerRouterTests {

    // MARK: the invariant that matters most

    /// Until the other Mac has reported its screens there is nothing to hand the pointer to,
    /// and swallowing input would leave this Mac unusable for no reason at all.
    @Test("with no layout, nothing is ever swallowed")
    func noLayoutNeverSwallows() {
        var r = PointerRouter()
        for _ in 0..<50 {
            let d = r.pointerMoved(localLocation: ScreenPoint(x: 3389, y: 500), delta: push)
            #expect(d == .passThrough)
        }
        #expect(!r.isRemote)
    }

    @Test("ordinary movement in the middle of the screen passes through")
    func middleOfScreenPassesThrough() {
        var r = router()
        #expect(r.pointerMoved(localLocation: ScreenPoint(x: 700, y: 400), delta: push) == .passThrough)
        #expect(r.pointerMoved(localLocation: ScreenPoint(x: 700, y: 400), delta: pull) == .passThrough)
        #expect(!r.isRemote)
    }

    @Test("reaching the edge without pushing further does not hand over")
    func edgeWithoutPushing() {
        var r = router()
        let atEdge = ScreenPoint(x: 3389, y: 500)
        #expect(r.pointerMoved(localLocation: atEdge, delta: ScreenPoint(x: 0, y: 6)) == .passThrough)
        #expect(r.pointerMoved(localLocation: atEdge, delta: pull) == .passThrough)
        #expect(!r.isRemote)
    }

    @Test("the opposite edge never hands over")
    func wrongEdge() {
        var r = router(edge: .right)
        #expect(r.pointerMoved(localLocation: ScreenPoint(x: 0, y: 500), delta: pull) == .passThrough)
        #expect(!r.isRemote)
    }

    // MARK: crossing

    @Test("leaning on the shared edge crosses over")
    func crossing() throws {
        var r = router()
        guard let entry = crossOver(&r) else {
            Issue.record("never crossed over"); return
        }
        #expect(r.isRemote)
        #expect(remoteScreens.contains { $0.rect.contains(entry) },
                "arrived at \(entry), which is on no screen")
        #expect(entry.x > 8 && entry.x < 60,
                "should arrive a comfortable way inside their left edge, got \(entry)")
    }

    // MARK: the bug this pressure logic exists for

    /// The reported symptom: cross to the other Mac, move a little back the way you came, and
    /// the pointer snaps home — leaving one cursor stranded on the far screen and another
    /// moving here. It happened because the pointer arrived two pixels inside the far edge, so
    /// any movement back at all was already "past the edge".
    @Test("a small movement back after crossing does not bounce the pointer home")
    func noBounceBackAfterCrossing() {
        var r = router()
        crossOver(&r)
        #expect(r.isRemote)

        // A few small nudges back the way we came, as a hand naturally does on arrival.
        for step in 1...3 {
            let decision = r.pointerMoved(localLocation: .init(x: 0, y: 0),
                                          delta: ScreenPoint(x: -4, y: 0))
            guard case .forward = decision else {
                Issue.record("nudge \(step) bounced the pointer home: \(decision)"); return
            }
        }
        #expect(r.isRemote, "the pointer should still be on the other Mac")
    }

    @Test("moving freely around the far screen never bounces home")
    func freeMovementStaysRemote() {
        var r = router()
        crossOver(&r)
        // A wander that goes left as often as right, well inside the far screen.
        var x = 0.0
        for step in 0..<400 {
            let dx: Double = (step % 7 < 3) ? -9 : 11
            x += dx
            let decision = r.pointerMoved(localLocation: .init(x: 0, y: 0),
                                          delta: ScreenPoint(x: dx, y: Double((step % 5) - 2)))
            if case .comeBack = decision {
                Issue.record("bounced home at step \(step) after travelling \(x)px"); return
            }
        }
        #expect(r.isRemote)
    }

    @Test("a deliberate push against the far edge does return it")
    func sustainedPushReturns() {
        var r = router()
        crossOver(&r)
        var returned = false
        for _ in 0..<60 where !returned {
            if case .comeBack = r.pointerMoved(localLocation: .init(x: 0, y: 0), delta: pull) {
                returned = true
            }
        }
        #expect(returned, "leaning on the far edge should bring the pointer back")
        #expect(!r.isRemote)
    }

    @Test("grazing the local edge without pushing does not cross")
    func grazingDoesNotCross() {
        var r = router()
        // Alternating in and out at the edge: pressure must not accumulate across reversals.
        for _ in 0..<50 {
            _ = r.pointerMoved(localLocation: ScreenPoint(x: 3389, y: 556), delta: ScreenPoint(x: 6, y: 0))
            _ = r.pointerMoved(localLocation: ScreenPoint(x: 3380, y: 556), delta: ScreenPoint(x: -6, y: 0))
        }
        #expect(!r.isRemote, "a wobble at the edge should not hand the pointer over")
    }

    @Test("while remote, movement is forwarded and stays on a real screen")
    func forwarding() {
        var r = router()
        crossOver(&r)

        for step in 0..<200 {
            let delta = ScreenPoint(x: 7, y: step % 3 == 0 ? 5 : -4)
            let decision = r.pointerMoved(localLocation: .init(x: 0, y: 0), delta: delta)
            guard case let .forward(remote) = decision else {
                Issue.record("step \(step): expected forwarding, got \(decision)"); return
            }
            #expect(remoteScreens.contains { $0.rect.contains(remote) },
                    "step \(step) landed at \(remote), which is on no screen")
        }
        #expect(r.isRemote)
    }

    @Test("pushing back across the edge returns the pointer here")
    func comingBack() {
        var r = router()
        crossOver(&r)
        #expect(r.isRemote)

        var came: ScreenPoint?
        for _ in 0..<80 {
            if case let .comeBack(local) = r.pointerMoved(localLocation: .init(x: 0, y: 0), delta: pull) {
                came = local
                break
            }
        }
        let local = try! #require(came)
        #expect(!r.isRemote)
        #expect(localScreens.contains { $0.rect.contains(local) },
                "came back to \(local), which is on no screen")
        #expect(local.x > 3330, "should reappear near the edge it left from, got \(local)")
    }

    /// Holding the pointer against the far edge must not build up an invisible offset —
    /// otherwise coming back needs that same distance travelled before anything happens.
    @Test("pushing into the far edge does not accumulate an offset")
    func noAccumulationAtTheFarEdge() {
        var r = router()
        crossOver(&r)

        // Shove hard into the right-hand edge of the other Mac for a long time.
        for _ in 0..<500 {
            _ = r.pointerMoved(localLocation: .init(x: 0, y: 0), delta: ScreenPoint(x: 40, y: 0))
        }
        #expect(r.isRemote)

        // One screen's width of travel back must be enough to return.
        var steps = 0
        var returned = false
        while steps < 300 {
            steps += 1
            if case .comeBack = r.pointerMoved(localLocation: .init(x: 0, y: 0),
                                               delta: ScreenPoint(x: -10, y: 0)) {
                returned = true
                break
            }
        }
        #expect(returned, "never came back after \(steps) steps of travel")
        #expect(steps < 220, "took \(steps) steps, which means an offset accumulated")
    }

    // MARK: forced returns

    @Test("forceLocal brings the pointer back from anywhere")
    func forcedReturn() {
        var r = router()
        crossOver(&r)
        #expect(r.isRemote)

        let returned = r.forceLocal()
        let destination = try! #require(returned)
        #expect(!r.isRemote)
        #expect(localScreens.contains { $0.rect.contains(destination) })
    }

    @Test("forceLocal is harmless when the pointer is already here")
    func forcedReturnWhenLocal() {
        var r = router()
        #expect(r.forceLocal() == nil)
        #expect(!r.isRemote)
        // ...and twice in a row, since several safety paths can fire together.
        crossOver(&r)
        #expect(r.forceLocal() != nil)
        #expect(r.forceLocal() == nil)
    }

    @Test("after a forced return, movement is passed through again")
    func afterForcedReturnInputFlowsLocally() {
        var r = router()
        crossOver(&r)
        _ = r.forceLocal()
        #expect(r.pointerMoved(localLocation: ScreenPoint(x: 700, y: 400), delta: push) == .passThrough)
    }

    /// Switching the middle monitor between the two Macs replaces both layouts. The tracked
    /// position refers to screens that may no longer exist, so the pointer comes home first.
    @Test("replacing the layout brings the pointer back first")
    func layoutChangeReturnsPointer() {
        var r = router()
        crossOver(&r)
        #expect(r.isRemote)

        // The monitor has just been switched to the work Mac: it leaves us, joins them.
        let after = ScreenLayout(localDisplays: [display(0, 0, 1470, 956, main: true)],
                                 remoteDisplays: [display(-1920, 32, 1920, 1080),
                                                  display(0, 0, 1512, 982, main: true)],
                                 edge: .right, alignment: .proportional)!
        let destination = r.replaceLayout(after)
        #expect(!r.isRemote)
        #expect(destination != nil)

        // And the new arrangement works: crossing now lands on the monitor.
        guard let entry = crossOver(&r, at: ScreenPoint(x: 1469, y: 478)) else {
            Issue.record("could not cross over after the switch"); return
        }
        #expect(display(-1920, 32, 1920, 1080).rect.contains(entry),
                "expected to arrive on the middle monitor, got \(entry)")
    }

    @Test("clearing the layout stops any swallowing")
    func clearingLayoutStopsSwallowing() {
        var r = router()
        crossOver(&r)
        _ = r.replaceLayout(nil)
        #expect(!r.isRemote)
        #expect(r.pointerMoved(localLocation: ScreenPoint(x: 3389, y: 556), delta: push) == .passThrough)
    }

    // MARK: clicks

    @Test("a click while remote carries the current position")
    func clickPosition() {
        var r = router()
        crossOver(&r)
        for _ in 0..<20 { _ = r.pointerMoved(localLocation: .init(x: 0, y: 0), delta: ScreenPoint(x: 11, y: 7)) }

        let current = r.currentRemotePoint()
        let point = try! #require(current)
        #expect(remoteScreens.contains { $0.rect.contains(point) })
    }

    @Test("there is no remote position while the pointer is here")
    func noRemotePointWhenLocal() {
        let r = router()
        #expect(r.currentRemotePoint() == nil)
    }

    // MARK: every edge

    @Test("crossing and returning works on each edge", arguments: ScreenEdge.allCases)
    func everyEdge(edge: ScreenEdge) {
        var r = router(edge: edge, local: [display(0, 0, 1470, 956, main: true)])
        let bounds = ScreenRect(x: 0, y: 0, width: 1470, height: 956)

        let (at, outward, inward): (ScreenPoint, ScreenPoint, ScreenPoint)
        switch edge {
        case .right:  at = .init(x: bounds.maxX - 1, y: 478); outward = .init(x: 9, y: 0); inward = .init(x: -9, y: 0)
        case .left:   at = .init(x: 0, y: 478);               outward = .init(x: -9, y: 0); inward = .init(x: 9, y: 0)
        case .bottom: at = .init(x: 735, y: bounds.maxY - 1); outward = .init(x: 0, y: 9); inward = .init(x: 0, y: -9)
        case .top:    at = .init(x: 735, y: 0);               outward = .init(x: 0, y: -9); inward = .init(x: 0, y: 9)
        }

        var entry: ScreenPoint?
        for _ in 0..<40 where entry == nil {
            if case let .cross(e) = r.pointerMoved(localLocation: at, delta: outward) { entry = e }
        }
        guard let entry else { Issue.record("\(edge): did not cross over"); return }
        #expect(remoteScreens.contains { $0.rect.contains(entry) }, "\(edge): entry \(entry) is on no screen")

        var returned = false
        for _ in 0..<600 where !returned {
            if case .comeBack = r.pointerMoved(localLocation: .init(x: 0, y: 0), delta: inward) {
                returned = true
            }
        }
        #expect(returned, "\(edge): never came back")
        #expect(!r.isRemote)
    }
}
