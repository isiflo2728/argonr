"""Converts GLB / glTF / OBJ / STL into USD ASCII, which RealityKit loads.

Stdlib only. The phone cannot do this itself and the model host may not want
to, so it happens in the middle.

Only geometry and flat colour survive the trip — enough for a model to read
correctly on a table, which is all the viewer needs.
"""
import json, pathlib, struct, sys

# ----------------------------------------------------------------- GLB/glTF

COMPONENT = {5120: ("b", 1), 5121: ("B", 1), 5122: ("h", 2),
             5123: ("H", 2), 5125: ("I", 4), 5126: ("f", 4)}
COUNTS = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}


def _unpack_glb(data):
    """GLB is a 12-byte header then length-prefixed chunks."""
    magic, _, _ = struct.unpack_from("<4sII", data, 0)
    if magic != b"glTF":
        raise ValueError("not a GLB")
    offset, js, bin_chunk = 12, None, b""
    while offset < len(data):
        length, kind = struct.unpack_from("<II", data, offset)
        body = data[offset + 8: offset + 8 + length]
        if kind == 0x4E4F534A:
            # The spec pads this chunk with spaces; some writers use nulls.
            # Either way it is not JSON until the tail comes off.
            js = json.loads(body.decode("utf-8").strip(" \t\r\n\x00"))
        elif kind == 0x004E4942:
            bin_chunk = body
        offset += 8 + length + (-length % 4)
    if js is None:
        raise ValueError("GLB had no JSON chunk")
    return js, bin_chunk


def _read_accessor(gltf, blob, index):
    acc = gltf["accessors"][index]
    fmt, size = COMPONENT[acc["componentType"]]
    per = COUNTS[acc["type"]]
    count = acc["count"]

    view = gltf["bufferViews"][acc["bufferView"]]
    start = view.get("byteOffset", 0) + acc.get("byteOffset", 0)
    stride = view.get("byteStride") or (size * per)

    out = []
    for i in range(count):
        at = start + i * stride
        out.append(struct.unpack_from("<" + fmt * per, blob, at))
    return out


def _node_matrix(node):
    """Column-major 4x4 from either an explicit matrix or TRS."""
    if "matrix" in node:
        m = node["matrix"]
        return [m[0:4], m[4:8], m[8:12], m[12:16]]

    tx, ty, tz = node.get("translation", [0, 0, 0])
    qx, qy, qz, qw = node.get("rotation", [0, 0, 0, 1])
    sx, sy, sz = node.get("scale", [1, 1, 1])

    xx, yy, zz = qx * qx, qy * qy, qz * qz
    xy, xz, yz = qx * qy, qx * qz, qy * qz
    wx, wy, wz = qw * qx, qw * qy, qw * qz
    r = [[1 - 2 * (yy + zz), 2 * (xy + wz),     2 * (xz - wy)],
         [2 * (xy - wz),     1 - 2 * (xx + zz), 2 * (yz + wx)],
         [2 * (xz + wy),     2 * (yz - wx),     1 - 2 * (xx + yy)]]
    s = [sx, sy, sz]
    return [[r[0][0] * s[0], r[0][1] * s[0], r[0][2] * s[0], 0],
            [r[1][0] * s[1], r[1][1] * s[1], r[1][2] * s[1], 0],
            [r[2][0] * s[2], r[2][1] * s[2], r[2][2] * s[2], 0],
            [tx, ty, tz, 1]]


def _mul(a, b):
    return [[sum(a[i][k] * b[k][j] for k in range(4)) for j in range(4)] for i in range(4)]


def _apply(m, p):
    x, y, z = p
    return (x * m[0][0] + y * m[1][0] + z * m[2][0] + m[3][0],
            x * m[0][1] + y * m[1][1] + z * m[2][1] + m[3][1],
            x * m[0][2] + y * m[1][2] + z * m[2][2] + m[3][2])


IDENTITY = [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]]


def gltf_meshes(data):
    """-> [(name, points, faceCounts, faceIndices, rgb)]"""
    if data[:4] == b"glTF":
        gltf, blob = _unpack_glb(data)
    else:
        gltf, blob = json.loads(data.decode("utf-8")), b""

    materials = gltf.get("materials", [])
    out = []

    def walk(node_index, parent):
        node = gltf["nodes"][node_index]
        world = _mul(_node_matrix(node), parent)

        if "mesh" in node:
            mesh = gltf["meshes"][node["mesh"]]
            for n, prim in enumerate(mesh.get("primitives", [])):
                if prim.get("mode", 4) != 4:          # triangles only
                    continue
                attrs = prim.get("attributes", {})
                if "POSITION" not in attrs:
                    continue
                points = [_apply(world, p) for p in _read_accessor(gltf, blob, attrs["POSITION"])]

                if "indices" in prim:
                    idx = [i[0] for i in _read_accessor(gltf, blob, prim["indices"])]
                else:
                    idx = list(range(len(points)))

                rgb = (0.72, 0.72, 0.74)
                if prim.get("material") is not None and prim["material"] < len(materials):
                    pbr = materials[prim["material"]].get("pbrMetallicRoughness", {})
                    base = pbr.get("baseColorFactor")
                    if base:
                        rgb = tuple(float(c) for c in base[:3])

                name = (mesh.get("name") or node.get("name") or f"mesh{node_index}")
                safe = "".join(ch if ch.isalnum() else "_" for ch in name) or "mesh"
                out.append((f"{safe}_{node_index}_{n}", points,
                            [3] * (len(idx) // 3), idx, rgb))

        for child in node.get("children", []):
            walk(child, world)

    scene = gltf.get("scenes", [{}])[gltf.get("scene", 0)]
    roots = scene.get("nodes") or list(range(len(gltf.get("nodes", []))))
    for root in roots:
        walk(root, IDENTITY)
    return out


# ---------------------------------------------------------------- OBJ / STL

def obj_meshes(data):
    points, faces = [], []
    for line in data.decode("utf-8", "replace").splitlines():
        bits = line.split()
        if not bits:
            continue
        if bits[0] == "v":
            points.append(tuple(float(v) for v in bits[1:4]))
        elif bits[0] == "f":
            corners = [int(b.split("/")[0]) for b in bits[1:]]
            corners = [c - 1 if c > 0 else len(points) + c for c in corners]
            for i in range(1, len(corners) - 1):       # fan-triangulate
                faces.extend([corners[0], corners[i], corners[i + 1]])
    return [("obj", points, [3] * (len(faces) // 3), faces, (0.72, 0.72, 0.74))]


def stl_meshes(data):
    points, faces = [], []
    if data[:5].lower() == b"solid" and b"facet" in data[:512]:
        for line in data.decode("utf-8", "replace").splitlines():
            bits = line.split()
            if bits[:1] == ["vertex"]:
                points.append(tuple(float(v) for v in bits[1:4]))
        faces = list(range(len(points)))
    else:
        count = struct.unpack_from("<I", data, 80)[0]
        at = 84
        for _ in range(count):
            for v in range(3):
                points.append(struct.unpack_from("<3f", data, at + 12 + v * 12))
            faces.extend([len(points) - 3, len(points) - 2, len(points) - 1])
            at += 50
    return [("stl", points, [3] * (len(faces) // 3), faces, (0.72, 0.72, 0.74))]


# -------------------------------------------------------------------- USD

def to_usda(meshes):
    blocks = []
    for name, points, counts, indices, rgb in meshes:
        if not points or not counts:
            continue
        pts = ", ".join(f"({x:.6g}, {y:.6g}, {z:.6g})" for x, y, z in points)
        blocks.append(f'''
    def Mesh "{name}"
    {{
        int[] faceVertexCounts = [{", ".join(str(c) for c in counts)}]
        int[] faceVertexIndices = [{", ".join(str(i) for i in indices)}]
        point3f[] points = [{pts}]
        color3f[] primvars:displayColor = [({rgb[0]:.4g}, {rgb[1]:.4g}, {rgb[2]:.4g})]
        uniform token subdivisionScheme = "none"
    }}''')
    if not blocks:
        raise ValueError("no triangle geometry found")
    return f'''#usda 1.0
(
    defaultPrim = "Model"
    metersPerUnit = 1
    upAxis = "Y"
)

def Xform "Model"
{{{"".join(blocks)}
}}
'''


def convert(data, hint=""):
    """Sniff the format and return USD ASCII text."""
    if data[:4] == b"glTF":
        meshes = gltf_meshes(data)
    elif data[:5] == b"#usda" or data[:8] == b"PXR-USDC":
        return data.decode("utf-8", "replace")        # already USD
    elif hint.endswith(".obj") or data[:2] in (b"v ", b"# "):
        meshes = obj_meshes(data)
    elif hint.endswith(".stl") or data[:5].lower() == b"solid":
        meshes = stl_meshes(data)
    elif data.lstrip()[:1] == b"{":
        meshes = gltf_meshes(data)                     # .gltf JSON
    else:
        raise ValueError(f"unrecognised format (hint={hint!r}, head={data[:8]!r})")
    return to_usda(meshes)


if __name__ == "__main__":
    src = pathlib.Path(sys.argv[1])
    out = pathlib.Path(sys.argv[2] if len(sys.argv) > 2 else src.with_suffix(".usda"))
    text = convert(src.read_bytes(), src.name.lower())
    out.write_text(text)
    print(f"{src.name} -> {out.name}  ({text.count('def Mesh')} meshes, {len(text)} chars)")
