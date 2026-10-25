//
//  WorldARView.swift
//  argonr
//
//  Builds Argon's geometry once, then moves it every frame from the
//  simulation. The meshes come straight from the program Argon wrote —
//  vertices and faces it computed — so nothing here invents shape.
//

import ARKit
import Combine
import RealityKit
import SwiftUI

struct WorldARView: UIViewRepresentable {
    var world: World?
    var isRunning: Bool
    var onTick: (WorldBattle) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onTick: onTick) }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero)

        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal]
        config.environmentTexturing = .automatic
        view.session.run(config)

        let coaching = ARCoachingOverlayView()
        coaching.session = view.session
        coaching.goal = .horizontalPlane
        coaching.activatesAutomatically = true
        coaching.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(coaching)
        NSLayoutConstraint.activate([
            coaching.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            coaching.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            coaching.topAnchor.constraint(equalTo: view.topAnchor),
            coaching.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        let anchor = AnchorEntity(.plane(.horizontal, classification: .any,
                                         minimumBounds: [0.2, 0.2]))
        view.scene.addAnchor(anchor)

        context.coordinator.attach(view: view, anchor: anchor)
        context.coordinator.load(world)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.onTick = onTick
        context.coordinator.isRunning = isRunning
        context.coordinator.load(world)
    }

    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        coordinator.detach()
        uiView.session.pause()
    }

    @MainActor
    final class Coordinator {
        var onTick: (WorldBattle) -> Void
        var isRunning = true

        private var anchor: AnchorEntity?
        private var entities: [Int: Entity] = [:]
        private var battle: WorldBattle?
        private var current: World?
        private var subscription: (any Cancellable)?
        private var sinceReport: Float = 0

        init(onTick: @escaping (WorldBattle) -> Void) {
            self.onTick = onTick
        }

        func attach(view: ARView, anchor: AnchorEntity) {
            self.anchor = anchor
            subscription = view.scene.subscribe(to: SceneEvents.Update.self) { [weak self] event in
                self?.tick(Float(event.deltaTime))
            }
        }

        func detach() {
            subscription?.cancel()
            subscription = nil
        }

        func load(_ world: World?) {
            guard let world, world != current, let anchor else { return }
            current = world

            anchor.children.removeAll()
            entities = [:]

            let root = Entity()
            root.addChild(ground(world))

            let colors = world.teamColors
            for (index, entity) in world.entities.enumerated() {
                let node = build(entity, teamColor: colors[entity.team] ?? SIMD3(0.7, 0.7, 0.7))
                node.position = entity.origin
                root.addChild(node)
                entities[index] = node
            }
            anchor.addChild(root)

            var fresh = WorldBattle(world: world)
            fresh.step(0)
            battle = fresh
            onTick(fresh)
        }

        private func ground(_ world: World) -> Entity {
            let mesh = MeshResource.generateBox(
                width: world.ground.width, height: 0.003,
                depth: world.ground.depth, cornerRadius: 0.002)
            let entity = ModelEntity(
                mesh: mesh,
                materials: [material(world.ground.color?.rgb ?? SIMD3(0.35, 0.40, 0.35))])
            entity.position = SIMD3(0, -0.0015, 0)
            return entity
        }

        /// Argon's vertices and faces, turned into a RealityKit mesh verbatim.
        private func build(_ entity: World.Entity, teamColor: SIMD3<Float>) -> Entity {
            let node = Entity()
            for mesh in entity.meshes {
                guard let resource = resource(from: mesh) else { continue }
                node.addChild(ModelEntity(mesh: resource,
                                          materials: [material(mesh.color.rgb)]))
            }
            if node.children.isEmpty {
                // Never leave an entity invisible: a placeholder is a bug the
                // loop can see, an absence is not.
                node.addChild(ModelEntity(mesh: .generateBox(size: 0.02),
                                          materials: [material(teamColor)]))
            }
            return node
        }

        private func resource(from mesh: World.Mesh) -> MeshResource? {
            var positions: [SIMD3<Float>] = []
            positions.reserveCapacity(mesh.vertices.count)
            for v in mesh.vertices where v.count >= 3 {
                positions.append(SIMD3(v[0], v[1], v[2]))
            }
            guard positions.count >= 3 else { return nil }

            // RealityKit wants triangles; Argon is allowed arbitrary polygons,
            // so anything with more than three corners is fanned here.
            var indices: [UInt32] = []
            for face in mesh.faces where face.count >= 3 {
                guard face.allSatisfy({ $0 >= 0 && $0 < positions.count }) else { continue }
                for i in 1..<(face.count - 1) {
                    indices.append(UInt32(face[0]))
                    indices.append(UInt32(face[i]))
                    indices.append(UInt32(face[i + 1]))
                }
            }
            guard indices.count >= 3 else { return nil }

            var descriptor = MeshDescriptor(name: mesh.name)
            descriptor.positions = MeshBuffers.Positions(positions)
            descriptor.primitives = .triangles(indices)
            return try? MeshResource.generate(from: [descriptor])
        }

        private func material(_ colour: SIMD3<Float>) -> RealityKit.Material {
            var material = PhysicallyBasedMaterial()
            material.baseColor = .init(tint: UIColor(red: CGFloat(colour.x),
                                                     green: CGFloat(colour.y),
                                                     blue: CGFloat(colour.z), alpha: 1))
            material.roughness = 0.85
            material.metallic = 0.0
            return material
        }

        private func tick(_ dt: Float) {
            guard isRunning, var running = battle, !running.isOver else { return }
            running.step(min(dt, 1.0 / 20))

            for unit in running.units {
                guard let node = entities[unit.id] else { continue }
                if unit.isAlive {
                    node.position = unit.position
                    node.orientation = simd_quatf(angle: unit.facing, axis: SIMD3(0, 1, 0))
                } else if node.isEnabled {
                    node.orientation = simd_quatf(angle: .pi / 2, axis: SIMD3(1, 0, 0))
                    node.components.set(OpacityComponent(opacity: 0.4))
                }
            }
            battle = running

            sinceReport += dt
            if sinceReport > 0.2 || running.isOver {
                sinceReport = 0
                onTick(running)
            }
        }

        func restart() {
            guard let current else { return }
            let world = current
            self.current = nil
            load(world)
        }
    }
}
