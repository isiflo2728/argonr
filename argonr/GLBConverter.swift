//
//  GLBConverter.swift
//  argonr
//
//  Converts glTF/GLB into USD ASCII on the device.
//
//  RealityKit loads USD and nothing else, and the backend currently emits
//  GLB. Converting here rather than on a laptop means the app works against
//  the deployed backend with nothing else running.
//
//  Geometry and flat per-material colour survive; textures, PBR maps,
//  animation and skinning do not. For a model being read on a table that is
//  the part that matters.
//

import Foundation
import simd

enum GLBConverterError: LocalizedError {
    case notGLTF
    case malformed(String)
    case noGeometry

    var errorDescription: String? {
        switch self {
        case .notGLTF:            "That file is not glTF"
        case .malformed(let why): "Couldn't read that glTF — \(why)"
        case .noGeometry:         "That glTF had no triangle geometry"
        }
    }
}

enum GLBConverter {

    static func isGLTF(_ data: Data) -> Bool {
        if data.starts(with: Data("glTF".utf8)) { return true }
        // A .gltf is JSON; only treat it as one if it declares an asset block.
        guard let first = data.first, first == UInt8(ascii: "{") else { return false }
        return String(decoding: data.prefix(512), as: UTF8.self).contains("\"asset\"")
    }

    /// -> USD ASCII text.
    static func usda(from data: Data) throws -> String {
        let (json, binary) = try container(data)
        let meshes = try meshes(json: json, binary: binary)
        guard !meshes.isEmpty else { throw GLBConverterError.noGeometry }
        return assemble(meshes)
    }

    // MARK: - Container

    /// GLB is a 12-byte header followed by length-prefixed chunks.
    private static func container(_ data: Data) throws -> ([String: Any], Data) {
        guard isGLTF(data) else { throw GLBConverterError.notGLTF }

        if data.first == UInt8(ascii: "{") {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw GLBConverterError.malformed("top level was not an object")
            }
            return (object, Data())
        }

        guard data.count >= 12 else { throw GLBConverterError.malformed("truncated header") }
        var offset = 12
        var json: [String: Any]?
        var binary = Data()

        while offset + 8 <= data.count {
            let length = Int(read32(data, offset))
            let kind = read32(data, offset + 4)
            let start = offset + 8
            guard start + length <= data.count else {
                throw GLBConverterError.malformed("chunk runs past the end")
            }
            let body = data[start..<(start + length)]

            if kind == 0x4E4F534A {
                // The spec pads this chunk with spaces; some writers use
                // nulls. Either way it is not JSON until the tail comes off.
                let trimmed = body.drop { _ in false }.reversed()
                    .drop { $0 == 0x00 || $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }
                let cleaned = Data(trimmed.reversed())
                json = try JSONSerialization.jsonObject(with: cleaned) as? [String: Any]
            } else if kind == 0x004E4942 {
                binary = Data(body)
            }
            offset = start + length + ((4 - length % 4) % 4)
        }

        guard let json else { throw GLBConverterError.malformed("no JSON chunk") }
        return (json, binary)
    }

    private static func read32(_ data: Data, _ offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for i in (0..<4).reversed() {
            value = value << 8 | UInt32(data[data.startIndex + offset + i])
        }
        return value
    }

    // MARK: - Meshes

    private struct Mesh {
        let name: String
        let points: [SIMD3<Float>]
        let indices: [Int]
        let colour: SIMD3<Float>
    }

    private static func meshes(json: [String: Any], binary: Data) throws -> [Mesh] {
        let nodes = json["nodes"] as? [[String: Any]] ?? []
        let meshDefs = json["meshes"] as? [[String: Any]] ?? []
        let materials = json["materials"] as? [[String: Any]] ?? []
        let accessors = json["accessors"] as? [[String: Any]] ?? []
        let views = json["bufferViews"] as? [[String: Any]] ?? []

        var out: [Mesh] = []

        func walk(_ index: Int, _ parent: simd_float4x4) {
            guard index < nodes.count else { return }
            let node = nodes[index]
            let world = parent * transform(of: node)

            if let meshIndex = node["mesh"] as? Int, meshIndex < meshDefs.count {
                let mesh = meshDefs[meshIndex]
                let primitives = mesh["primitives"] as? [[String: Any]] ?? []

                for (n, primitive) in primitives.enumerated() {
                    // 4 is TRIANGLES, and the default when absent.
                    if let mode = primitive["mode"] as? Int, mode != 4 { continue }
                    guard let attributes = primitive["attributes"] as? [String: Any],
                          let positionIndex = attributes["POSITION"] as? Int else { continue }

                    let local = readVec3(accessors, views, binary, positionIndex)
                    guard !local.isEmpty else { continue }
                    let points = local.map { point -> SIMD3<Float> in
                        let p = world * SIMD4<Float>(point.x, point.y, point.z, 1)
                        return SIMD3(p.x, p.y, p.z)
                    }

                    let indices: [Int]
                    if let accessor = primitive["indices"] as? Int {
                        indices = readScalars(accessors, views, binary, accessor)
                    } else {
                        indices = Array(0..<points.count)
                    }
                    guard indices.count >= 3 else { continue }

                    var colour = SIMD3<Float>(0.72, 0.72, 0.74)
                    if let materialIndex = primitive["material"] as? Int,
                       materialIndex < materials.count,
                       let pbr = materials[materialIndex]["pbrMetallicRoughness"] as? [String: Any],
                       let base = pbr["baseColorFactor"] as? [Double], base.count >= 3 {
                        colour = SIMD3(Float(base[0]), Float(base[1]), Float(base[2]))
                    }

                    let raw = (mesh["name"] as? String) ?? (node["name"] as? String) ?? "mesh"
                    out.append(Mesh(name: "\(identifier(raw))_\(index)_\(n)",
                                    points: points, indices: indices, colour: colour))
                }
            }

            for child in node["children"] as? [Int] ?? [] {
                walk(child, world)
            }
        }

        let scenes = json["scenes"] as? [[String: Any]] ?? []
        let sceneIndex = json["scene"] as? Int ?? 0
        let roots = (sceneIndex < scenes.count ? scenes[sceneIndex]["nodes"] as? [Int] : nil)
            ?? Array(0..<nodes.count)

        for root in roots { walk(root, matrix_identity_float4x4) }
        return out
    }

    /// Either an explicit matrix or translation/rotation/scale.
    private static func transform(of node: [String: Any]) -> simd_float4x4 {
        if let m = node["matrix"] as? [Double], m.count == 16 {
            return simd_float4x4(columns: (
                SIMD4(Float(m[0]), Float(m[1]), Float(m[2]), Float(m[3])),
                SIMD4(Float(m[4]), Float(m[5]), Float(m[6]), Float(m[7])),
                SIMD4(Float(m[8]), Float(m[9]), Float(m[10]), Float(m[11])),
                SIMD4(Float(m[12]), Float(m[13]), Float(m[14]), Float(m[15]))))
        }

        let t = (node["translation"] as? [Double]).map { SIMD3<Float>(Float($0[0]), Float($0[1]), Float($0[2])) } ?? .zero
        let s = (node["scale"] as? [Double]).map { SIMD3<Float>(Float($0[0]), Float($0[1]), Float($0[2])) } ?? SIMD3(repeating: 1)
        let r = (node["rotation"] as? [Double]).map {
            simd_quatf(ix: Float($0[0]), iy: Float($0[1]), iz: Float($0[2]), r: Float($0[3]))
        } ?? simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

        var m = simd_float4x4(r)
        m.columns.0 *= s.x
        m.columns.1 *= s.y
        m.columns.2 *= s.z
        m.columns.3 = SIMD4(t.x, t.y, t.z, 1)
        return m
    }

    // MARK: - Accessors

    private static func layout(_ accessors: [[String: Any]], _ views: [[String: Any]],
                               _ index: Int) -> (offset: Int, stride: Int, count: Int, component: Int, per: Int)? {
        guard index < accessors.count else { return nil }
        let accessor = accessors[index]
        guard let componentType = accessor["componentType"] as? Int,
              let type = accessor["type"] as? String,
              let count = accessor["count"] as? Int,
              let viewIndex = accessor["bufferView"] as? Int,
              viewIndex < views.count else { return nil }

        let sizes = [5120: 1, 5121: 1, 5122: 2, 5123: 2, 5125: 4, 5126: 4]
        let counts = ["SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16]
        guard let size = sizes[componentType], let per = counts[type] else { return nil }

        let view = views[viewIndex]
        let start = (view["byteOffset"] as? Int ?? 0) + (accessor["byteOffset"] as? Int ?? 0)
        let stride = view["byteStride"] as? Int ?? (size * per)
        return (start, stride, count, componentType, per)
    }

    private static func readVec3(_ accessors: [[String: Any]], _ views: [[String: Any]],
                                 _ binary: Data, _ index: Int) -> [SIMD3<Float>] {
        guard let l = layout(accessors, views, index), l.component == 5126, l.per >= 3,
              binary.count >= l.offset + (l.count - 1) * l.stride + 12 else { return [] }
        return (0..<l.count).map { i in
            let at = l.offset + i * l.stride
            return SIMD3(float(binary, at), float(binary, at + 4), float(binary, at + 8))
        }
    }

    private static func readScalars(_ accessors: [[String: Any]], _ views: [[String: Any]],
                                    _ binary: Data, _ index: Int) -> [Int] {
        guard let l = layout(accessors, views, index) else { return [] }
        var out: [Int] = []
        out.reserveCapacity(l.count)
        for i in 0..<l.count {
            let at = l.offset + i * l.stride
            switch l.component {
            case 5121: guard at < binary.count else { return out }
                       out.append(Int(binary[binary.startIndex + at]))
            case 5123: guard at + 2 <= binary.count else { return out }
                       out.append(Int(uint16(binary, at)))
            case 5125: guard at + 4 <= binary.count else { return out }
                       out.append(Int(read32(binary, at)))
            default:   return out
            }
        }
        return out
    }

    private static func float(_ data: Data, _ offset: Int) -> Float {
        Float(bitPattern: read32(data, offset))
    }

    private static func uint16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[data.startIndex + offset]) | UInt16(data[data.startIndex + offset + 1]) << 8
    }

    // MARK: - Output

    private static func identifier(_ raw: String) -> String {
        let safe = String(raw.map { $0.isLetter || $0.isNumber ? $0 : "_" })
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if safe.isEmpty { return "mesh" }
        return safe.first!.isNumber ? "m\(safe)" : safe
    }

    private static func assemble(_ meshes: [Mesh]) -> String {
        var blocks = ""
        for mesh in meshes {
            let triangles = mesh.indices.count / 3
            guard triangles > 0 else { continue }
            let points = mesh.points
                .map { "(\(trim($0.x)), \(trim($0.y)), \(trim($0.z)))" }
                .joined(separator: ", ")
            let counts = Array(repeating: "3", count: triangles).joined(separator: ", ")
            let indices = mesh.indices.prefix(triangles * 3).map(String.init).joined(separator: ", ")

            blocks += """

                def Mesh "\(mesh.name)"
                {
                    int[] faceVertexCounts = [\(counts)]
                    int[] faceVertexIndices = [\(indices)]
                    point3f[] points = [\(points)]
                    color3f[] primvars:displayColor = [(\(trim(mesh.colour.x)), \(trim(mesh.colour.y)), \(trim(mesh.colour.z)))]
                    uniform token subdivisionScheme = "none"
                }
            """
        }

        return """
        #usda 1.0
        (
            defaultPrim = "Model"
            metersPerUnit = 1
            upAxis = "Y"
        )

        def Xform "Model"
        {\(blocks)
        }

        """
    }

    private static func trim(_ value: Float) -> String {
        String(format: "%g", value)
    }
}
