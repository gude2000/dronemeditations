import SwiftUI
import UIKit

/// Thin SwiftUI wrapper around UIActivityViewController so a finished
/// recording (or any URL/Data) can be saved, shared, or sent via the
/// system share sheet.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
