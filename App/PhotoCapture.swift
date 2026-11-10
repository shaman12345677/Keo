import SwiftUI
import UIKit

struct CameraPicker: UIViewControllerRepresentable {
    @Binding var imageData: Data?
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        picker.allowsEditing = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker

        init(_ parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                parent.imageData = uprightJPEG(image)
            }
            parent.dismiss()
        }

        /// Vykreslí UIImage včetně imageOrientation, aby pixely nebyly vzhůru nohama.
        private func uprightJPEG(_ image: UIImage) -> Data? {
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            format.opaque = true
            let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
            let upright = renderer.image { _ in
                image.draw(in: CGRect(origin: .zero, size: image.size))
            }
            return upright.jpegData(compressionQuality: 0.92)
        }
    }
}
