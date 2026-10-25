// usd_render — renders turntable frames from a USD file using Apple's own
// loader, so what Argon critiques is exactly what the phone will display.
//
// No Blender, no installs: SceneKit and Metal ship with macOS.
//
//   swiftc -O usd_render.swift -o usd_render
//   ./usd_render scene.usda out/ 8

import AppKit
import Metal
import SceneKit

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: usd_render <scene.usd[a|c|z]> <out-dir> [frames] [size]")
    exit(2)
}
let sourceURL = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2])
let frameCount = args.count > 3 ? Int(args[3]) ?? 8 : 8
let pixels = args.count > 4 ? Int(args[4]) ?? 800 : 800

guard let device = MTLCreateSystemDefaultDevice() else {
    print("FAILED no metal device"); exit(1)
}
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let scene: SCNScene
do {
    scene = try SCNScene(url: sourceURL, options: [.checkConsistency: true])
} catch {
    print("FAILED load: \(error.localizedDescription)"); exit(1)
}

// Frame the whole thing, whatever scale it came out at.
let (minB, maxB) = scene.rootNode.boundingBox
let center = SCNVector3((minB.x + maxB.x) / 2, (minB.y + maxB.y) / 2, (minB.z + maxB.z) / 2)
let span = max(maxB.x - minB.x, max(maxB.y - minB.y, maxB.z - minB.z))
let radius = Double(max(span, 0.01)) * 2.2

let cameraNode = SCNNode()
cameraNode.camera = SCNCamera()
cameraNode.camera?.zNear = 0.001
cameraNode.camera?.zFar = 1000
scene.rootNode.addChildNode(cameraNode)

let key = SCNNode()
key.light = SCNLight()
key.light?.type = .directional
key.light?.intensity = 900
key.eulerAngles = SCNVector3(-0.9, 0.6, 0)
scene.rootNode.addChildNode(key)

let renderer = SCNRenderer(device: device, options: nil)
renderer.scene = scene
renderer.autoenablesDefaultLighting = true
renderer.pointOfView = cameraNode

var written: [String] = []
for index in 0..<frameCount {
    let angle = (Double(index) / Double(frameCount)) * 2 * .pi
    cameraNode.position = SCNVector3(
        center.x + CGFloat(radius * cos(angle)),
        center.y + CGFloat(radius * 0.45),
        center.z + CGFloat(radius * sin(angle)))
    cameraNode.look(at: center)

    let image = renderer.snapshot(atTime: 0,
                                  with: CGSize(width: pixels, height: pixels),
                                  antialiasingMode: .multisampling4X)

    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        print("FAILED encode frame \(index)"); exit(1)
    }
    let name = String(format: "view%02d.png", index)
    try png.write(to: outDir.appendingPathComponent(name))
    written.append(name)
}

// Measured facts the critique scores against, alongside the pictures.
var meshes = 0, vertices = 0
scene.rootNode.enumerateHierarchy { node, _ in
    if let geometry = node.geometry {
        meshes += 1
        vertices += geometry.sources(for: .vertex).first?.vectorCount ?? 0
    }
}
let metrics: [String: Any] = [
    "ok": true,
    "meshes": meshes,
    "vertices": vertices,
    "bounds_m": [span, maxB.y - minB.y, maxB.z - minB.z].map { Double($0) },
    "frames": written,
]
let json = try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys])
try json.write(to: outDir.appendingPathComponent("metrics.json"))

print("RENDERED \(written.count) frames · \(meshes) meshes · \(vertices) verts")
