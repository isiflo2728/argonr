"""3D scene schema returned by the model, plus exporters to GLB, OBJ and STL.

The model never writes file formats directly. It returns a Scene (enforced with
Gemini structured output) and we build each file format from it, which keeps
binary formats like GLB correct and lets every format share one validator.
"""

import json
import math
import struct
from enum import StrEnum

from pydantic import BaseModel, Field


class MeshFormat(StrEnum):
    GLB = "glb"
    OBJ = "obj"
    STL = "stl"
    USDA = "usda"


MEDIA_TYPES = {
    MeshFormat.GLB: "model/gltf-binary",
    MeshFormat.OBJ: "model/obj",
    MeshFormat.STL: "model/stl",
    MeshFormat.USDA: "model/vnd.usda",
}


class Part(BaseModel):
    name: str = Field(description="Short name of this part, e.g. 'seat' or 'front left leg'")
    color: list[float] = Field(description="Base color as [r, g, b], each between 0 and 1 (sRGB)")
    vertices: list[list[float]] = Field(description="Vertex positions as [x, y, z] in meters")
    faces: list[list[int]] = Field(
        description="Polygons as lists of 0-based indices into this part's vertices, "
        "counter-clockwise when viewed from outside"
    )


class Scene(BaseModel):
    name: str = Field(description="Short name of the whole model")
    parts: list[Part] = Field(description="Separately colored parts that make up the model")


SYSTEM_INSTRUCTION = (
    "You are a 3D modeling assistant. Build the requested object as a set of parts, "
    "giving each visually distinct piece (different material or color) its own part "
    "with a realistic color. Use meters, Y as up, rest the model on y = 0 and center "
    "it on the origin in x and z. Each part's faces index only that part's vertices, "
    "starting at 0. Prefer clean low-poly geometry: closed shapes, planar convex faces, "
    "and enough segments (12-24) to make round objects look round."
)


class InvalidMeshError(ValueError):
    pass


def validate(scene: Scene) -> dict[str, int]:
    """Check the scene is structurally valid and return vertex/triangle counts."""
    if not scene.parts:
        raise InvalidMeshError("Model has no parts")
    vertices = triangles = 0
    for part in scene.parts:
        label = f"Part {part.name!r}"
        if len(part.color) != 3 or not all(0 <= c <= 1 for c in part.color):
            raise InvalidMeshError(f"{label} color must be 3 values between 0 and 1")
        if len(part.vertices) < 3 or not part.faces:
            raise InvalidMeshError(f"{label} needs at least 3 vertices and 1 face")
        for v in part.vertices:
            if len(v) != 3 or not all(math.isfinite(c) for c in v):
                raise InvalidMeshError(f"{label} has an invalid vertex: {v}")
        for face in part.faces:
            if len(face) < 3:
                raise InvalidMeshError(f"{label} has a face with fewer than 3 vertices")
            if not all(0 <= i < len(part.vertices) for i in face):
                raise InvalidMeshError(f"{label} has a face referencing a missing vertex: {face}")
            triangles += len(face) - 2
        vertices += len(part.vertices)
    return {"vertices": vertices, "faces": triangles}


def export(scene: Scene, fmt: MeshFormat) -> bytes:
    if fmt is MeshFormat.GLB:
        return to_glb(scene)
    if fmt is MeshFormat.OBJ:
        return to_obj(scene).encode()
    if fmt is MeshFormat.USDA:
        return to_usda(scene).encode()
    return to_stl(scene).encode()


def _triangles(face: list[int]) -> list[tuple[int, int, int]]:
    """Fan-triangulate a convex polygon."""
    return [(face[0], face[i], face[i + 1]) for i in range(1, len(face) - 1)]


def _srgb_to_linear(c: float) -> float:
    # glTF color factors are in linear space; the model picks colors in sRGB.
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def to_glb(scene: Scene) -> bytes:
    """Build a binary glTF 2.0 file with one mesh and material per part."""
    binary = bytearray()
    buffer_views, accessors, meshes, materials, nodes = [], [], [], [], []

    def add_view(data: bytes, target: int) -> int:
        buffer_views.append({"buffer": 0, "byteOffset": len(binary), "byteLength": len(data), "target": target})
        binary.extend(data)
        binary.extend(b"\x00" * (-len(binary) % 4))  # keep every view 4-byte aligned
        return len(buffer_views) - 1

    for part in scene.parts:
        positions = struct.pack(f"<{len(part.vertices) * 3}f", *(c for v in part.vertices for c in v))
        indices = [i for face in part.faces for tri in _triangles(face) for i in tri]

        accessors.append({
            "bufferView": add_view(positions, 34962),  # ARRAY_BUFFER
            "componentType": 5126,  # FLOAT
            "count": len(part.vertices),
            "type": "VEC3",
            "min": [min(v[axis] for v in part.vertices) for axis in range(3)],
            "max": [max(v[axis] for v in part.vertices) for axis in range(3)],
        })
        position_accessor = len(accessors) - 1
        accessors.append({
            "bufferView": add_view(struct.pack(f"<{len(indices)}I", *indices), 34963),  # ELEMENT_ARRAY_BUFFER
            "componentType": 5125,  # UNSIGNED_INT
            "count": len(indices),
            "type": "SCALAR",
        })

        materials.append({
            "name": part.name,
            "pbrMetallicRoughness": {
                "baseColorFactor": [*(_srgb_to_linear(c) for c in part.color), 1.0],
                "metallicFactor": 0.0,
                "roughnessFactor": 0.7,
            },
            "doubleSided": True,  # generated meshes may have inconsistent winding
        })
        # No normals: glTF viewers must then render flat-shaded, which suits low-poly models.
        meshes.append({
            "name": part.name,
            "primitives": [{
                "attributes": {"POSITION": position_accessor},
                "indices": len(accessors) - 1,
                "material": len(materials) - 1,
            }],
        })
        nodes.append({"name": part.name, "mesh": len(meshes) - 1})

    gltf = {
        "asset": {"version": "2.0", "generator": "argon-hackathon"},
        "scene": 0,
        "scenes": [{"name": scene.name, "nodes": list(range(len(nodes)))}],
        "nodes": nodes,
        "meshes": meshes,
        "materials": materials,
        "accessors": accessors,
        "bufferViews": buffer_views,
        "buffers": [{"byteLength": len(binary)}],
    }
    json_chunk = json.dumps(gltf, separators=(",", ":")).encode()
    json_chunk += b" " * (-len(json_chunk) % 4)
    bin_chunk = bytes(binary)

    total = 12 + 8 + len(json_chunk) + 8 + len(bin_chunk)
    return b"".join([
        struct.pack("<4sII", b"glTF", 2, total),
        struct.pack("<I4s", len(json_chunk), b"JSON"), json_chunk,
        struct.pack("<I4s", len(bin_chunk), b"BIN\x00"), bin_chunk,
    ])


def to_usda(scene: Scene) -> str:
    """USD ASCII, which Apple's RealityKit and QuickLook load directly.

    A Scene is already parts with vertices, faces and a colour, which is the
    shape USD wants, so nothing is lost on the way out. The alternative —
    shipping GLB and converting on the client — costs a hop and drops colour
    to whatever the converter can recover.

    Faces keep their original arity rather than being triangulated: USD takes
    arbitrary polygons, and leaving them whole keeps the file smaller and the
    geometry closer to what the model actually described.
    """
    def ident(text: str, fallback: str) -> str:
        safe = "".join(c if c.isalnum() or c == "_" else "_" for c in text).strip("_")
        if not safe or safe[0].isdigit():
            safe = f"{fallback}_{safe}" if safe else fallback
        return safe

    blocks = []
    for index, part in enumerate(scene.parts):
        points = ", ".join(f"({x:g}, {y:g}, {z:g})" for x, y, z in part.vertices)
        counts = ", ".join(str(len(face)) for face in part.faces)
        indices = ", ".join(str(i) for face in part.faces for i in face)
        r, g, b = part.color
        blocks.append(f'''
    def Mesh "{ident(part.name, f"part{index}")}_{index}"
    {{
        int[] faceVertexCounts = [{counts}]
        int[] faceVertexIndices = [{indices}]
        point3f[] points = [{points}]
        color3f[] primvars:displayColor = [({r:.4g}, {g:.4g}, {b:.4g})]
        uniform token subdivisionScheme = "none"
    }}''')

    root = ident(scene.name, "Model")
    return f'''#usda 1.0
(
    defaultPrim = "{root}"
    metersPerUnit = 1
    upAxis = "Y"
)

def Xform "{root}"
{{{"".join(blocks)}
}}
'''


def to_obj(scene: Scene) -> str:
    """OBJ with per-vertex colors ('v x y z r g b'), one object per part."""
    lines = [f"# {scene.name}"]
    offset = 1
    for part in scene.parts:
        lines.append(f"o {part.name.replace(' ', '_')}")
        r, g, b = part.color
        lines.extend(f"v {x:g} {y:g} {z:g} {r:.4g} {g:.4g} {b:.4g}" for x, y, z in part.vertices)
        lines.extend("f " + " ".join(str(i + offset) for i in face) for face in part.faces)
        offset += len(part.vertices)
    return "\n".join(lines) + "\n"


def to_stl(scene: Scene) -> str:
    """ASCII STL. Converts Y-up to Z-up and drops colors, which STL can't store."""
    name = scene.name.replace(" ", "_") or "model"
    lines = [f"solid {name}"]
    for part in scene.parts:
        verts = [(x, -z, y) for x, y, z in part.vertices]
        for face in part.faces:
            for a, b, c in _triangles(face):
                p0, p1, p2 = verts[a], verts[b], verts[c]
                u = [p1[i] - p0[i] for i in range(3)]
                w = [p2[i] - p0[i] for i in range(3)]
                n = [u[1] * w[2] - u[2] * w[1], u[2] * w[0] - u[0] * w[2], u[0] * w[1] - u[1] * w[0]]
                length = math.hypot(*n) or 1.0
                lines.append("  facet normal " + " ".join(f"{c / length:g}" for c in n))
                lines.append("    outer loop")
                lines.extend(f"      vertex {p[0]:g} {p[1]:g} {p[2]:g}" for p in (p0, p1, p2))
                lines.append("    endloop")
                lines.append("  endfacet")
    lines.append(f"endsolid {name}")
    return "\n".join(lines) + "\n"
