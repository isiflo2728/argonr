//
//  ARContainerView.swift
//  argonr
//
//  Drops the current .usdz onto the first horizontal plane it finds and
//  swaps it in place when you pick a different iteration. The swap is the
//  demo: tap v0, tap v5, watch it correct itself on the table.
//

import SwiftUI
import RealityKit
import ARKit

struct ARContainerView: UIViewRepresentable {
    var modelURL: URL?
    var onNote: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onNote: onNote) }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero)

        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]
        config.environmentTexturing = .automatic
        view.session.run(config)

        // Waits for a surface roughly the size of a sheet of paper.
        let anchor = AnchorEntity(.plane(.horizontal,
                                         classification: .any,
                                         minimumBounds: [0.15, 0.15]))
        view.scene.addAnchor(anchor)

        context.coordinator.arView = view
        context.coordinator.anchor = anchor
        context.coordinator.load(modelURL)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.onNote = onNote
        context.coordinator.load(modelURL)
    }

    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        uiView.session.pause()
    }

    @MainActor
    final class Coordinator {
        var arView: ARView?
        var anchor: AnchorEntity?
        var onNote: (String) -> Void

        private var currentURL: URL?
        private var host: ModelEntity?
        private var task: Task<Void, Never>?

        init(onNote: @escaping (String) -> Void) {
            self.onNote = onNote
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

            onNote("Loading…")
            task = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let entity = try await Entity(contentsOf: url)
                    guard !Task.isCancelled else { return }

                    // A usdz root is usually a plain Entity, which can't take
                    // gestures. Parent it to a ModelEntity so it can.
                    let wrapper = ModelEntity()
                    wrapper.addChild(entity)
                    Self.fit(entity, longestSide: 0.3)
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
        /// everything lands about hand-sized on the table.
        private static func fit(_ entity: Entity, longestSide: Float) {
            let extents = entity.visualBounds(relativeTo: nil).extents
            let longest = max(extents.x, max(extents.y, extents.z))
            guard longest > 0.0001 else { return }
            entity.scale = .init(repeating: longestSide / longest)
        }
    }
}
