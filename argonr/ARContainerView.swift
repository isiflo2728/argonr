//
//  ARContainerView.swift
//  argonr
//
//  Drops the current .usdz onto a horizontal plane and swaps it in place when
//  you pick a different iteration. The swap is the demo: tap v0, tap v5, and
//  watch it correct itself in front of you.
//
//  ARKit appears only here. Capture is an ordinary video; the loop runs
//  against headless renders server-side. AR is purely how you see the result.
//

import SwiftUI
import RealityKit
import ARKit

struct ARContainerView: UIViewRepresentable {
    var modelURL: URL?
    /// Bumped to ask for a snapshot. A counter rather than a flag, so two
    /// captures in a row both fire.
    var captureTicket: Int
    var onNote: (String) -> Void
    var onCapture: (UIImage) -> Void
    /// Longest side of the placed model, in metres, so the UI can show the
    /// size the user is actually looking at.
    var onSize: (Float) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onNote: onNote, onCapture: onCapture, onSize: onSize) }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero)

        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]
        config.environmentTexturing = .automatic
        view.session.run(config)

        // Without this the session starts cold and nothing happens for several
        // seconds, which reads as a broken app. Apple's overlay says "move
        // your phone to find a surface" and gets out of the way on its own.
        let coaching = ARCoachingOverlayView()
        coaching.session = view.session
        coaching.goal = .horizontalPlane
        coaching.activatesAutomatically = true
        coaching.delegate = context.coordinator
        coaching.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(coaching)
        NSLayoutConstraint.activate([
            coaching.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            coaching.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            coaching.topAnchor.constraint(equalTo: view.topAnchor),
            coaching.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // A real surface rather than the first 15cm ledge in view. The model
        // can be dragged elsewhere afterwards.
        let anchor = AnchorEntity(.plane(.horizontal,
                                         classification: .any,
                                         minimumBounds: [0.2, 0.2]))
        view.scene.addAnchor(anchor)

        context.coordinator.arView = view
        context.coordinator.anchor = anchor
        context.coordinator.coaching = coaching
        context.coordinator.load(modelURL)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.onNote = onNote
        context.coordinator.onCapture = onCapture
        context.coordinator.onSize = onSize
        context.coordinator.load(modelURL)
        context.coordinator.captureIfAsked(captureTicket)
    }

    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        uiView.session.pause()
    }

    @MainActor
    final class Coordinator: NSObject, ARCoachingOverlayViewDelegate {
        var arView: ARView?
        var anchor: AnchorEntity?
        var coaching: ARCoachingOverlayView?
        var onNote: (String) -> Void
        var onCapture: (UIImage) -> Void
        var onSize: (Float) -> Void
        private var servedTicket = 0

        private var currentURL: URL?
        private var host: ModelEntity?
        private var task: Task<Void, Never>?

        init(onNote: @escaping (String) -> Void,
             onCapture: @escaping (UIImage) -> Void,
             onSize: @escaping (Float) -> Void) {
            self.onNote = onNote
            self.onCapture = onCapture
            self.onSize = onSize
            super.init()
        }

        /// Snapshots the camera feed with the model composited into it — what
        /// the person is actually looking at, which is context no server-side
        /// render has. SwiftUI chrome is a sibling view, so it stays out.
        func captureIfAsked(_ ticket: Int) {
            guard ticket > servedTicket, let arView else { return }
            servedTicket = ticket
            arView.snapshot(saveToHDR: false) { [weak self] image in
                guard let self, let image else { return }
                Task { @MainActor in self.onCapture(image) }
            }
        }

        func load(_ url: URL?) {
            guard url != currentURL else { return }
            currentURL = url
            task?.cancel()

            guard let url, let anchor else {
                host?.removeFromParent()
                host = nil
                return
            }

            onNote("Loading")
            task = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let entity = try await Entity(contentsOf: url)
                    guard !Task.isCancelled else { return }

                    // A usdz root is usually a plain Entity, which cannot take
                    // gestures. Parent it to a ModelEntity so it can.
                    let wrapper = ModelEntity()
                    wrapper.addChild(entity)
                    let metres = Self.placeAtTrueScale(entity)
                    wrapper.generateCollisionShapes(recursive: true)

                    self.host?.removeFromParent()
                    anchor.addChild(wrapper)
                    self.host = wrapper

                    // Translation lets the model be dragged onto whatever
                    // surface the user actually wants it on.
                    self.arView?.installGestures([.translation, .rotation, .scale],
                                                 for: wrapper)
                    self.onSize(metres)
                    self.onNote("")
                } catch {
                    self.onNote("Couldn't load that model — \(error.localizedDescription)")
                }
            }
        }

        /// Places the model at the size it says it is.
        ///
        /// USD here is metres with `metersPerUnit = 1`, and the backend builds
        /// to real-world scale, so the file already knows how big the thing
        /// should be. Normalising to a fixed size — which this used to do —
        /// silently discarded every size correction the backend made, so the
        /// refinement loop could never converge: it was always judging an
        /// object the app had resized behind its back.
        ///
        /// Only absurd values are clamped, so a model that comes back as a
        /// forty metre chair is still reachable rather than filling the room.
        @discardableResult
        private static func placeAtTrueScale(_ entity: Entity) -> Float {
            let extents = entity.visualBounds(relativeTo: nil).extents
            let longest = max(extents.x, max(extents.y, extents.z))
            guard longest > 0.0001 else { return 0 }

            let limit: Float = 2.5          // taller than a person: clamp
            let floor: Float = 0.02         // smaller than a coin: clamp
            if longest > limit {
                entity.scale = .init(repeating: limit / longest)
                return limit
            }
            if longest < floor {
                entity.scale = .init(repeating: floor / longest)
                return floor
            }
            return longest
        }

        // MARK: - ARCoachingOverlayViewDelegate

        func coachingOverlayViewWillActivate(_ overlay: ARCoachingOverlayView) {
            onNote("")
        }
    }
}
