import Testing
import Foundation
@testable import ContinuousCore

private func display(_ x: Int32, _ y: Int32, _ w: Int32, _ h: Int32, main: Bool = false) -> Display {
    Display(x: x, y: y, width: w, height: h, isMain: main)
}

/// Approximate geometry of the setup this was built for:
///   personal MacBook Air  built-in 1470×956
///   external monitor      1920×1080, switchable between the two Macs
///   work MacBook          built-in 1512×982
private enum Rig {
    static let personalBuiltIn = display(0, 0, 1470, 956, main: true)
    static let workBuiltIn = display(0, 0, 1512, 982, main: true)
    /// The monitor as the left Mac sees it: to the right of the built-in screen.
    static let monitorOnLeftMac = display(1470, 32, 1920, 1080)
    /// The same monitor as the right Mac sees it: to the left of its built-in screen.
    static let monitorOnRightMac = display(-1920, 32, 1920, 1080)
}

@Suite("Screen geometry")
struct ScreenRectTests {
    @Test("union covers every display")
    func union() {
        let r = ScreenRect.union([Rig.personalBuiltIn.rect, Rig.monitorOnLeftMac.rect])
        #expect(r == ScreenRect(x: 0, y: 0, width: 3390, height: 1112))
    }

    @Test("union of nothing is nothing")
    func emptyUnion() {
        #expect(ScreenRect.union([]) == nil)
    }

    @Test("clamp keeps a point inside, a pixel short of the far edges")
    func clamp() {
        let r = ScreenRect(x: 0, y: 0, width: 100, height: 100)
        #expect(r.clamp(ScreenPoint(x: -5, y: 50)) == ScreenPoint(x: 0, y: 50))
        #expect(r.clamp(ScreenPoint(x: 500, y: 50)) == ScreenPoint(x: 99, y: 50))
        #expect(r.clamp(ScreenPoint(x: 50, y: 50)) == ScreenPoint(x: 50, y: 50))
    }

    /// Two screens of different heights leave corners inside the bounding box but on no
    /// screen. The pointer must never be parked in one.
    @Test("nearest point avoids the gap between mismatched screens")
    func deadZone() {
        let screens = [Rig.personalBuiltIn.rect, Rig.monitorOnLeftMac.rect]
        let inGap = ScreenPoint(x: 700, y: 1050)   // below the laptop, beside the monitor
        #expect(!screens.contains { $0.contains(inGap) })

        let snapped = ScreenLayout.nearestPoint(in: screens, to: inGap)
        #expect(screens.contains { $0.contains(snapped) }, "snapped to \(snapped), which is still nowhere")
    }

    @Test("a point already on a screen is left alone")
    func noUnnecessaryMove() {
        let screens = [Rig.personalBuiltIn.rect, Rig.monitorOnLeftMac.rect]
        let p = ScreenPoint(x: 200, y: 300)
        #expect(ScreenLayout.nearestPoint(in: screens, to: p) == p)
    }
}

@Suite("Screen layout")
struct ScreenLayoutTests {
    private func layout(local: [Display], remote: [Display],
                        edge: ScreenEdge = .right,
                        alignment: ScreenAlignment = .proportional) -> ScreenLayout {
        ScreenLayout(localDisplays: local, remoteDisplays: remote,
                     edge: edge, alignment: alignment)!
    }

    @Test("needs displays on both sides")
    func requiresDisplays() {
        #expect(ScreenLayout(localDisplays: [], remoteDisplays: [Rig.workBuiltIn],
                             edge: .right, alignment: .start) == nil)
        #expect(ScreenLayout(localDisplays: [Rig.personalBuiltIn], remoteDisplays: [],
                             edge: .right, alignment: .start) == nil)
    }

    @Test("the other Mac is placed flush against the chosen edge", arguments: ScreenEdge.allCases)
    func placement(edge: ScreenEdge) {
        let l = layout(local: [Rig.personalBuiltIn], remote: [Rig.workBuiltIn],
                       edge: edge, alignment: .start)
        let local = l.localBounds
        let remote = l.remoteBoundsInVirtual

        switch edge {
        case .right:  #expect(remote.x == local.maxX)
        case .left:   #expect(remote.maxX == local.x)
        case .bottom: #expect(remote.y == local.maxY)
        case .top:    #expect(remote.maxY == local.y)
        }
        // Placed next to our screens, never overlapping them.
        #expect(!(remote.x < local.maxX && remote.maxX > local.x
                  && remote.y < local.maxY && remote.maxY > local.y))
    }

    @Test("mapping between the two coordinate spaces round-trips", arguments: ScreenEdge.allCases)
    func roundTrip(edge: ScreenEdge) {
        for alignment in ScreenAlignment.allCases {
            let l = layout(local: [Rig.personalBuiltIn, Rig.monitorOnLeftMac],
                           remote: [Rig.workBuiltIn], edge: edge, alignment: alignment)
            for p in [ScreenPoint(x: 0, y: 0), ScreenPoint(x: 755, y: 491),
                      ScreenPoint(x: 1511, y: 981), ScreenPoint(x: -40, y: 12)] {
                let back = l.remote(fromVirtual: l.virtual(fromRemote: p))
                #expect(abs(back.x - p.x) < 0.001 && abs(back.y - p.y) < 0.001,
                        "\(edge)/\(alignment): \(p) -> \(back)")
            }
        }
    }

    @Test("proportional alignment makes the whole of the other screen reachable")
    func proportionalCoversEverything() {
        // A short laptop screen next to a tall monitor: with a fixed alignment, the bottom of
        // the taller screen cannot be reached by walking off the shorter one.
        let l = layout(local: [display(0, 0, 1470, 956, main: true)],
                       remote: [display(0, 0, 1920, 1440, main: true)],
                       alignment: .proportional)
        let top = l.entryPoint(leavingLocalAt: ScreenPoint(x: 1469, y: 0))
        let bottom = l.entryPoint(leavingLocalAt: ScreenPoint(x: 1469, y: 955))
        #expect(top.y < 10, "top of our screen should reach the top of theirs, got \(top)")
        #expect(bottom.y > 1430, "bottom should reach the bottom, got \(bottom)")
    }

    @Test("fixed alignments keep the scale at 1:1")
    func fixedAlignmentsDoNotStretch() {
        for alignment in [ScreenAlignment.start, .center, .end] {
            let l = layout(local: [display(0, 0, 1470, 956, main: true)],
                           remote: [display(0, 0, 1920, 1440, main: true)],
                           alignment: alignment)
            #expect(l.remoteBoundsInVirtual.height == 1440,
                    "\(alignment) should not scale the other Mac's screen")
        }
    }

    @Test("center alignment lines the two screens up through their middles")
    func centerAlignment() {
        let l = layout(local: [display(0, 0, 1470, 956, main: true)],
                       remote: [display(0, 0, 1920, 1440, main: true)],
                       alignment: .center)
        #expect(abs(l.remoteBoundsInVirtual.midY - l.localBounds.midY) < 0.001)
    }

    @Test("leaving is detected only at the right edge and only when still pushing")
    func leaveDetection() {
        let l = layout(local: [Rig.personalBuiltIn], remote: [Rig.workBuiltIn], edge: .right)
        let atEdge = ScreenPoint(x: 1469, y: 400)
        let pushingRight = ScreenPoint(x: 4, y: 0)
        let pushingLeft = ScreenPoint(x: -4, y: 0)

        #expect(l.isLeavingLocal(at: atEdge, delta: pushingRight))
        #expect(!l.isLeavingLocal(at: atEdge, delta: pushingLeft), "moving away must not hand over")
        #expect(!l.isLeavingLocal(at: ScreenPoint(x: 700, y: 400), delta: pushingRight),
                "mid-screen must not hand over")
        #expect(!l.isLeavingLocal(at: ScreenPoint(x: 0, y: 400), delta: pushingLeft),
                "the opposite edge must not hand over")
    }

    @Test("the pointer arrives just inside the other Mac and comes back just inside this one")
    func entryAndReturn() {
        let l = layout(local: [Rig.personalBuiltIn], remote: [Rig.workBuiltIn], edge: .right)
        let entry = l.entryPoint(leavingLocalAt: ScreenPoint(x: 1469, y: 478))
        #expect(entry.x > 8 && entry.x < 60, "should arrive inside their left edge, got \(entry)")
        #expect(l.remoteDisplays.contains { $0.contains(entry) }, "must land on a real screen")

        let back = l.returnPoint(enteringLocalAt: ScreenPoint(x: 1469, y: 478))
        #expect(back.x > 1400 && back.x < 1470, "should come back near our right edge, got \(back)")
        #expect(l.localDisplays.contains { $0.contains(back) })
    }

    @Test("a point mapped onto the other Mac always lands on one of its screens")
    func clampAlwaysLandsOnScreen() {
        let l = layout(local: [Rig.personalBuiltIn, Rig.monitorOnLeftMac],
                       remote: [Rig.workBuiltIn, display(1512, 100, 1920, 1080)])
        for y in stride(from: -200.0, through: 1400.0, by: 37) {
            let p = l.clampToRemote(virtual: ScreenPoint(x: l.remoteBoundsInVirtual.midX, y: y))
            #expect(l.remoteDisplays.contains { $0.contains(p) },
                    "y=\(y) mapped to \(p), which is on no screen")
        }
    }

    // MARK: the external-monitor-in-the-middle case

    /// The monitor sits physically between the two Macs and is switched from one to the other.
    /// Whichever Mac owns it, the combined desktop must stay the same shape — that is what
    /// makes the pointer keep behaving the same way after a switch.
    @Test("switching the middle monitor between Macs keeps one continuous desktop")
    func monitorSwitchesSides() {
        let monitorOnPersonal = ScreenLayout(
            localDisplays: [Rig.personalBuiltIn, Rig.monitorOnLeftMac],
            remoteDisplays: [Rig.workBuiltIn],
            edge: .right, alignment: .proportional)!

        let monitorOnWork = ScreenLayout(
            localDisplays: [Rig.personalBuiltIn],
            remoteDisplays: [Rig.monitorOnRightMac, Rig.workBuiltIn],
            edge: .right, alignment: .proportional)!

        func totalWidth(_ l: ScreenLayout) -> Double {
            ScreenRect.union(l.localDisplays + l.remoteDisplaysInVirtual)!.width
        }
        // Same three physical screens either way: laptop + monitor + laptop.
        #expect(abs(totalWidth(monitorOnPersonal) - totalWidth(monitorOnWork)) < 1,
                "\(totalWidth(monitorOnPersonal)) vs \(totalWidth(monitorOnWork))")

        // And in both arrangements the pointer can still get from one Mac to the other.
        for l in [monitorOnPersonal, monitorOnWork] {
            let edgePoint = ScreenPoint(x: l.localBounds.maxX - 1, y: l.localBounds.midY)
            #expect(l.isLeavingLocal(at: edgePoint, delta: ScreenPoint(x: 5, y: 0)))
            let entry = l.entryPoint(leavingLocalAt: edgePoint)
            #expect(l.remoteDisplays.contains { $0.contains(entry) },
                    "entry \(entry) is on no screen")
        }
    }

    /// With the monitor on the work Mac, the pointer should cross onto the *monitor* — the
    /// screen physically in the middle — not jump straight to the far laptop.
    @Test("the pointer crosses onto whichever screen is physically next")
    func crossesOntoTheNearestScreen() {
        let l = ScreenLayout(localDisplays: [Rig.personalBuiltIn],
                             remoteDisplays: [Rig.monitorOnRightMac, Rig.workBuiltIn],
                             edge: .right, alignment: .proportional)!
        let entry = l.entryPoint(leavingLocalAt: ScreenPoint(x: 1469, y: 478))
        // The monitor occupies x -1920..0 in the work Mac's own coordinates.
        #expect(Rig.monitorOnRightMac.rect.contains(entry),
                "expected to arrive on the middle monitor, got \(entry)")
    }

    @Test("a long name is shortened rather than spilling over a screen border")
    func diagramLabelsStayInside() {
        let l = ScreenLayout(localDisplays: [Rig.personalBuiltIn, Rig.monitorOnLeftMac],
                             remoteDisplays: [Rig.workBuiltIn],
                             edge: .right, alignment: .proportional)!
        let art = l.diagram(width: 60,
                            localName: "this Mac",
                            remoteName: "An Extremely Long Computer Name That Will Not Fit")
        for line in art.split(separator: "\n") {
            #expect(line.count <= 60)
        }
        // The border between the two Macs must survive: a spilled caption would eat it.
        #expect(art.contains("#"))
        #expect(art.contains("+"))
        #expect(art.contains("…"), "an over-long name should be elided")
    }

    @Test("the diagram renders something shaped like the arrangement")
    func diagram() {
        let l = ScreenLayout(localDisplays: [Rig.personalBuiltIn, Rig.monitorOnLeftMac],
                             remoteDisplays: [Rig.workBuiltIn],
                             edge: .right, alignment: .proportional)!
        let art = l.diagram(width: 60, localName: "mine", remoteName: "theirs")
        let lines = art.split(separator: "\n")
        #expect(lines.count >= 6)
        #expect(art.contains("#"), "local screens should be drawn")
        #expect(art.contains("+"), "remote screens should be drawn")
        #expect(lines.allSatisfy { $0.count <= 60 })
    }
}
