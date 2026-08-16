import SwiftUI
import UIKit
import PhotosUI

/// 自定义相册选择器：调取设备相册，支持多选图片。
/// 基于 PHPickerViewController（无需相册权限弹窗即可选图）。
struct PhotoPicker: UIViewControllerRepresentable {
    var maxSelection: Int = 1
    var onPick: ([UIImage]) -> Void
    var onCancel: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.selectionLimit = maxSelection
        config.filter = .images
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: PhotoPicker

        init(_ parent: PhotoPicker) {
            self.parent = parent
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true) {
                if results.isEmpty {
                    self.parent.onCancel()
                    return
                }
                let identifiers = results.map(\.assetIdentifier)
                let provider = results.first?.itemProvider
                guard let provider, provider.canLoadObject(ofClass: UIImage.self) else {
                    self.parent.onCancel()
                    return
                }
                provider.loadObject(ofClass: UIImage.self) { object, _ in
                    let image = object as? UIImage
                    let images = image.map { [$0] } ?? []
                    DispatchQueue.main.async {
                        self.parent.onPick(images)
                    }
                }
            }
        }
    }
}

/// 展示设备相册的行内简化版（列表入口用）
struct PhotosHelper {
    static func requestPhotoLibraryPermission(completion: @escaping (Bool) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            DispatchQueue.main.async {
                completion(status == .authorized || status == .limited)
            }
        }
    }
}