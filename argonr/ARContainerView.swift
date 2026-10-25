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
    /// Longest side the result is scaled to, and how big a surface it demands.
    /// A desk scene needs real floor; a single mug does not.
    var kind: CaptureKind
    var onNote: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onNote: onNote) }

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

        // Demand a surface proportional to what we are about to place, or a
        // 0.8 m scene latches onto a laptop lid.
        let minimum = kind.minimumPlaneMeters
        let anchor = AnchorEntity(.plane(.horizontal,
                                         classification: .any,
                                         minimumBounds: [minimum, minimum]))
        view.scene.addAnchor(anchor)

        context.coordinator.arView = view
        context.coordinator.anchor = anchor
        context.coordinator.coaching = coaching
        context.coordinator.fitMeters = kind.fitMeters
        context.coordinator.load(modelURL)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.onNote = onNote
        context.coordinator.fitMeters = kind.fitMeters
        context.coordinator.load(modelURL)
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
        var fitMeters: Float = 0.3

        private var currentURL: URL?
        private var host: ModelEntity?
        private var task: Task<Void, Never>?

        init(onNote: @escaping (String) -> Void) {
            self.onNote = onNote
            super.init()
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
                    Self.fit(entity, longestSide: self.fitMeters)
                    wrapper.generateCollisionShapes(recursive: true)

                    self.host?.removeFromParent()
                    anchor.addChild(wrapper)
                    self.host = wrapper

                    self.arView?.installGestures([.rotation, .scale], for: wrapper)
                    self.onNote("")
                } catch {
                    self.onNote("Couldn't load that model — \(error.localizedDescription)")
                }
            }
        }

        /// Generated models come out at wildly different scales. Normalize so
        /// the result lands at a believable size wherever it is placed.
        private static func fit(_ entity: Entity, longestSide: Float) {
            let extents = entity.visualBounds(relativeTo: nil).extents
            let longest = max(extents.x, max(extents.y, extents.z))
            guard longest > 0.0001 else { return }
            entity.scale = .init(repeating: longestSide / longest)
        }

        // MARK: - ARCoachingOverlayViewDelegate

        func coachingOverlayViewWillActivate(_ overlay: ARCoachingOverlayView) {
            onNote("")
        }
    }
}
