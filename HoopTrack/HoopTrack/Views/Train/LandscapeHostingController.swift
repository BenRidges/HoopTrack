// LandscapeHostingController.swift
// UIHostingController subclass that forces landscape orientation
// for LiveSessionView. Sets OrientationLock flag and requests rotation.

import SwiftUI
import UIKit

final class LandscapeHostingController<Content: View>: UIHostingController<Content> {

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        .landscapeRight
    }

    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        .landscapeRight
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        OrientationLock.allowLandscape = true
        requestOrientationChange(to: .landscapeRight)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        OrientationLock.allowLandscape = false
        requestOrientationChange(to: .portrait)
    }

    private func requestOrientationChange(to orientation: UIInterfaceOrientation) {
        guard let windowScene = view.window?.windowScene else { return }
        let geometryPreferences = UIWindowScene.GeometryPreferences.iOS(
            interfaceOrientations: orientation == .landscapeRight ? .landscapeRight : .portrait
        )
        windowScene.requestGeometryUpdate(geometryPreferences) { error in
            // Non-fatal — the system may decline the request
            print("HoopTrack: orientation change request error: \(error)")
        }
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
