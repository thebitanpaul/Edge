import WidgetKit

// Not the process's entry point: that is the system's `NSExtensionMain` (see Package.swift),
// which sets up the extension runtime and then calls this, finding it through the entry
// record Swift emits for a main file.
//
// A main file rather than `@main`, so the package can keep supporting macOS 13: the controls
// only exist from macOS 26, and the extension's Info.plist keeps older systems from loading
// it at all. The guard is for completeness.
if #available(macOS 26.0, *) {
    EdgeControls.main()
}
