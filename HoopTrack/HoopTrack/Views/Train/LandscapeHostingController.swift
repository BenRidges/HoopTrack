// LandscapeHostingController.swift
// UIHostingController subclass that forces landscape-right for
// LiveSessionView. Sets the OrientationLock flag and requests rotation.

import SwiftUI
import UIKit

final class LandscapeHostingController<Content: View>: UIHostingController<Content> {
    deinit {} // Keep: see "Explicit deinit" in CLAUDE.md


    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        .landscapeRight
    }

    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        .landscapeRight
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        OrientationLock.mode = .landscapeRight
        Orientation.request(.landscapeRight, from: view.window?.windowScene)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // `view.window` is often still nil in viewWillAppear for an embedded
        // controller; ask again now that it's on screen.
        Orientation.request(.landscapeRight, from: view.window?.windowScene)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        Orientation.restorePortrait()
    }
}

/// SwiftUI view that presents its content inside a LandscapeHostingController.
/// Use as the content of a `.fullScreenCover`.
struct LandscapeContainer<Content: View>: UIViewControllerRepresentable {

    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeUIViewController(context: Context) -> LandscapeHostingController<Content> {
        LandscapeHostingController(rootView: content)
    }

    func updateUIViewController(_ uiViewController: LandscapeHostingController<Content>, context: Context) {
        uiViewController.rootView = content
    }
}
