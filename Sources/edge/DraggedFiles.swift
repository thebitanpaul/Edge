import AppKit
import CoreGraphics
import EdgeCore

/// What is currently being dragged on this Mac, if anything.
///
/// macOS keeps the contents of a drag on a system pasteboard that any process can read, which
/// is how a drag started in Finder can be inspected from here without Finder's cooperation.
/// Reading it is the only way to answer "is the thing crossing this edge a file?" — and the
/// answer has to be known at the moment the pointer leaves, because by the time it has
/// arrived on the other Mac the drag is over.
enum DraggedFiles {
    /// Files on the drag pasteboard right now. Empty for a window drag, a text selection, or
    /// no drag at all.
    static func current() -> [URL] {
        let board = NSPasteboard(name: .drag)
        guard let items = board.readObjects(forClasses: [NSURL.self],
                                            options: [.urlReadingFileURLsOnly: true]) as? [URL]
        else { return [] }
        return items
    }

    /// Cancels the drag that is in progress on this Mac.
    ///
    /// Without this the source application is left holding a drag that will never be dropped:
    /// the pointer has gone to the other Mac and every event it would have ended with is being
    /// swallowed. Escape is the gesture macOS already defines for "put that back".
    ///
    /// Both events are stamped so this app's own event tap can tell them from the user's —
    /// otherwise the Escape it posts here would be forwarded to the other Mac as a keystroke.
    static func cancelLocalDrag(releasingAt point: ScreenPoint) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let location = CGPoint(x: point.x, y: point.y)

        if let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                            mouseCursorPosition: location, mouseButton: .left) {
            SyntheticEvent.mark(up)
            up.post(tap: .cghidEventTap)
        }
        for down in [true, false] {
            if let key = CGEvent(keyboardEventSource: source, virtualKey: 53, keyDown: down) {
                SyntheticEvent.mark(key)
                key.post(tap: .cghidEventTap)
            }
        }
    }
}
