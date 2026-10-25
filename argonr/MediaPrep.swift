//
//  MediaPrep.swift
//  argonr
//
//  A raw 4K clip off the camera is ~50 MB for ten seconds, which is painful
//  over venue wifi and slows every iteration. Everything gets squeezed to
//  720p and trimmed before it leaves the phone.
//

import AVFoundation
import CoreTransferable
import UIKit
import UniformTypeIdentifiers

enum MediaPrepError: LocalizedError {
    case exportFailed
    case noVideoTrack

    var errorDescription: String? {
        switch self {
        case .exportFailed: "Couldn't compress that clip"
        case .noVideoTrack: "That file has no video in it"
        }
    }
}

enum MediaPrep {
    /// Keep captures short — Argon reasons over the whole clip, and a long
    /// orbit adds latency without adding angles.
    static let maxSeconds: Double = 10

    /// Trim to `maxSeconds`, re-encode at 720p, and drop the audio track.
    ///
    /// The audio is recorded only because UIImagePickerController insists on
    /// it in video mode — nothing downstream wants it. Stripping it here
    /// means no audio ever leaves the device, and the upload gets smaller.
    static func compress(_ source: URL) async throws -> URL {
        let asset = AVURLAsset(url: source)

        guard let sourceTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw MediaPrepError.noVideoTrack
        }

        let duration = try await asset.load(.duration)
        let cap = CMTime(seconds: maxSeconds, preferredTimescale: 600)
        let range = CMTimeRange(start: .zero, duration: min(duration, cap))

        // Video-only composition: this is what drops the audio.
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw MediaPrepError.exportFailed
        }
        try videoTrack.insertTimeRange(range, of: sourceTrack, at: .zero)
        videoTrack.preferredTransform = try await sourceTrack.load(.preferredTransform)

        guard let session = AVAssetExportSession(
            asset: composition, presetName: AVAssetExportPreset1280x720) else {
            throw MediaPrepError.exportFailed
        }

        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("reference-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: dest)

        try await session.export(to: dest, as: .mp4)
        return dest
    }

    /// First frame, for the capture screen's well.
    static func thumbnail(_ url: URL) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        do {
            let (cgImage, _) = try await generator.image(at: .zero)
            return UIImage(cgImage: cgImage)
        } catch {
            return nil
        }
    }

    static func seconds(of url: URL) async -> Double? {
        try? await AVURLAsset(url: url).load(.duration).seconds
    }
}

/// PhotosPicker hands back videos only through a Transferable.
struct MovieFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("picked-\(UUID().uuidString).mov")
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: received.file, to: dest)
            return MovieFile(url: dest)
        }
    }
}
