//
//  CameraPicker.swift
//  argonr
//
//  SwiftUI has no native capture view, so this is the one place we reach for
//  UIKit. Library picking goes through PhotosPicker instead (see
//  CaptureScreen) because it runs out of process and needs no permission.
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct CameraPicker: UIViewControllerRepresentable {
    enum Mode { case photo, video }

    var mode: Mode
    var onPhoto: (UIImage) -> Void = { _ in }
    var onVideo: (URL) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = .camera
        controller.delegate = context.coordinator

        switch mode {
        case .photo:
            controller.mediaTypes = [UTType.image.identifier]
            controller.cameraCaptureMode = .photo
        case .video:
            controller.mediaTypes = [UTType.movie.identifier]
            controller.cameraCaptureMode = .video
            controller.videoQuality = .typeHigh
            controller.videoMaximumDuration = MediaPrep.maxSeconds
        }
        return controller
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPhoto: onPhoto, onVideo: onVideo, dismiss: { dismiss() })
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onPhoto: (UIImage) -> Void
        private let onVideo: (URL) -> Void
        private let dismiss: () -> Void

        init(onPhoto: @escaping (UIImage) -> Void,
             onVideo: @escaping (URL) -> Void,
             dismiss: @escaping () -> Void) {
            self.onPhoto = onPhoto
            self.onVideo = onVideo
            self.dismiss = dismiss
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let url = info[.mediaURL] as? URL {
                onVideo(url)
            } else if let image = info[.originalImage] as? UIImage {
                onPhoto(image)
            }
            dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            dismiss()
        }
    }
}
