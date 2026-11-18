import AppKit

/// Shows arriving files where they landed, the way a finished download is shown.
enum Reveal {
    static func inFinder(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}
