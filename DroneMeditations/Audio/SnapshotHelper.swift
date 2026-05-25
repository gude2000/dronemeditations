import SwiftUI
import UIKit
import Photos

/// Capture a SwiftUI view to a `UIImage`, then save it to the user's
/// Photos library. Used by the Chladni snapshot button so cymatics
/// captures live in the system gallery (no in-app browser needed —
/// iOS Photos already provides search, share, edit, delete).
///
/// We use `NSPhotoLibraryAddUsageDescription` (add-only access) so
/// users don't have to grant full library read access. The first save
/// triggers the system permission sheet; subsequent saves are silent.
enum SnapshotHelper {

    /// Render an off-screen SwiftUI view (a fresh, untransformed
    /// `ChladniView` at the requested pixel size) into a `UIImage`.
    /// Keeping the captured view separate from the on-screen one means
    /// the snapshot resolution is independent of device size — we always
    /// export a square 1500×1500 PNG-quality image.
    @MainActor
    static func renderChladni(vm: DroneViewModel, size: CGSize = CGSize(width: 1500, height: 1500), zoom: Double = 1.0) -> UIImage? {
        // Compose the same visual stack ContentView uses (background blob
        // + Chladni overlay) so the saved image matches what's on screen.
        let view = ZStack {
            Color.black
            ChladniView(zoom: zoom)
                .environmentObject(vm)
        }
        .frame(width: size.width, height: size.height)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 1.0  // size is already in render-pixel units
        renderer.proposedSize = ProposedViewSize(size)
        return renderer.uiImage
    }

    /// Persist an image to the user's photo library with add-only access.
    /// On success, posts `.cymaticSnapshotSaved`; on failure, posts
    /// `.cymaticSnapshotFailed` (with `error` in the userInfo). The
    /// caller can listen to surface a transient toast.
    static func saveToPhotos(_ image: UIImage) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                NotificationCenter.default.post(
                    name: .cymaticSnapshotFailed,
                    object: nil,
                    userInfo: ["reason": "Photo library permission denied"]
                )
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetCreationRequest.creationRequestForAsset(from: image)
            }) { success, error in
                DispatchQueue.main.async {
                    if success {
                        NotificationCenter.default.post(name: .cymaticSnapshotSaved, object: nil)
                    } else {
                        NotificationCenter.default.post(
                            name: .cymaticSnapshotFailed,
                            object: nil,
                            userInfo: ["reason": error?.localizedDescription ?? "Unknown error"]
                        )
                    }
                }
            }
        }
    }

    /// One-call convenience: render + save. Returns immediately; result
    /// is delivered via the notifications above.
    @MainActor
    static func captureAndSave(vm: DroneViewModel, zoom: Double = 1.0) {
        guard let image = renderChladni(vm: vm, zoom: zoom) else {
            NotificationCenter.default.post(
                name: .cymaticSnapshotFailed,
                object: nil,
                userInfo: ["reason": "Rendering failed"]
            )
            return
        }
        saveToPhotos(image)
    }
}

extension Notification.Name {
    static let cymaticSnapshotSaved  = Notification.Name("DroneMeditations.cymaticSnapshotSaved")
    static let cymaticSnapshotFailed = Notification.Name("DroneMeditations.cymaticSnapshotFailed")
}
