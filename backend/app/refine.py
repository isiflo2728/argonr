"""Improve a generated model from a photo of it placed in a real (AR) scene.

Argon sees the photo plus a summary of the model (each part's size, position
and color) and returns a RefinePlan: how big the object should really be, and
targeted edits to parts. The server applies the plan to the stored Scene.

Edits rather than a full rewrite keep the answer small (well inside the output
limit), fast, and safe: a scale fix can't accidentally mangle the geometry.
"""

import json
import struct

from pydantic import BaseModel, Field

from app.mesh import Part, Scene

MIN_SCALE, MAX_SCALE = 0.05, 20.0


class PartEdit(BaseModel):
    name: str = Field(description="Exact name of an existing part")
    remove: bool = Field(description="True to delete this part")
    color: list[float] | None = Field(description="New [r, g, b] in 0-1 sRGB, or null to keep")
    scale: float | None = Field(description="Uniform scale of this part about its own center, or null to keep")
    offset: list[float] | None = Field(description="Move this part by [dx, dy, dz] meters, or null to keep")


class RefinePlan(BaseModel):
    assessment: str = Field(description="What looks wrong (or right) about the model in this scene")
    apparent_size_m: float = Field(
        description="How large the model's LARGEST dimension APPEARS in the photo, in meters, judged "
        "against real objects around it (not the size listed in the summary)"
    )
    target_size_m: float = Field(
        description="How large that dimension SHOULD appear for this object to look right in this scene, "
        "in meters. Equal to apparent_size_m if the size already looks right."
    )
    part_edits: list[PartEdit] = Field(description="Changes to existing parts; empty if none")
    new_parts: list[Part] = Field(description="Parts to add (same coordinate system as the model); usually empty")
    changes: list[str] = Field(description="One short line per change made, for the user")


INSTRUCTION = """\
You are improving a 3D model so it fits a real scene. The photo shows a real environment
with the model placed in it using augmented reality. Judge it against the surroundings:

1. Size. The AR app may display the model at a different size than its file says, so judge
   size only from the photo. Using real references in it (tables, chairs, doors, hands, cups,
   floor tiles), estimate how big the model currently APPEARS and how big it SHOULD appear.
2. Proportions and parts. Fix parts that are clearly too big, too small, misplaced or missing.
3. Color. Adjust colors that clash with what the object should look like. Keep the style.

Only change what the photo gives you reason to change. The model uses meters, Y up, resting
on y = 0. Part names in edits must match the summary exactly.
"""


def _bounds(points: list[list[float]]) -> tuple[list[float], list[float]]:
    return [min(p[i] for p in points) for i in range(3)], [max(p[i] for p in points) for i in range(3)]


def size(scene: Scene) -> list[float]:
    lo, hi = _bounds([v for part in scene.parts for v in part.vertices])
    return [hi[i] - lo[i] for i in range(3)]


def summary(scene: Scene) -> str:
    """Compact description of the model for the prompt: no raw geometry."""
    w, h, d = size(scene)
    parts = []
    for part in scene.parts:
        lo, hi = _bounds(part.vertices)
        parts.append({
            "name": part.name,
            "color": [round(c, 3) for c in part.color],
            "size_m": [round(hi[i] - lo[i], 4) for i in range(3)],
            "center_m": [round((hi[i] + lo[i]) / 2, 4) for i in range(3)],
        })
    return json.dumps({
        "name": scene.name,
        "size_m": {"width_x": round(w, 4), "height_y": round(h, 4), "depth_z": round(d, 4)},
        "largest_dimension_m": round(max(w, h, d), 4),
        "parts": parts,
    }, indent=1)


def prompt(scene: Scene, note: str) -> str:
    text = f"Current model:\n{summary(scene)}\n"
    if note:
        text += f"\nThe user says: {note}\n"
    return text


def apply(scene: Scene, plan: RefinePlan) -> tuple[Scene, float, list[str]]:
    """Apply a plan. Returns the new scene, the overall scale used, and edits that were skipped."""
    edits = {e.name.strip().lower(): e for e in plan.part_edits}
    skipped = [e.name for e in plan.part_edits if e.name.strip().lower() not in {p.name.lower() for p in scene.parts}]

    parts: list[Part] = []
    for part in scene.parts:
        edit = edits.get(part.name.lower())
        if edit and edit.remove:
            continue
        vertices = [list(v) for v in part.vertices]
        color = list(part.color)
        if edit:
            if edit.color and len(edit.color) == 3:
                color = [min(max(c, 0.0), 1.0) for c in edit.color]
            if edit.scale and edit.scale > 0:
                s = min(max(edit.scale, MIN_SCALE), MAX_SCALE)
                lo, hi = _bounds(vertices)
                center = [(lo[i] + hi[i]) / 2 for i in range(3)]
                vertices = [[center[i] + (v[i] - center[i]) * s for i in range(3)] for v in vertices]
            if edit.offset and len(edit.offset) == 3:
                vertices = [[v[i] + edit.offset[i] for i in range(3)] for v in vertices]
        parts.append(Part(name=part.name, color=color, vertices=vertices, faces=part.faces))
    parts.extend(plan.new_parts)
    if not parts:
        raise ValueError("The refinement removed every part")

    # Overall scale is the ratio of how big the model should look to how big it
    # looks in the photo. A ratio, not an absolute size, because AR viewers often
    # rescale models on placement, so the file's own size says nothing about what
    # the user saw. Computed here rather than trusting the model's arithmetic.
    refined = Scene(name=scene.name, parts=parts)
    if plan.apparent_size_m > 0 and plan.target_size_m > 0:
        scale = min(max(plan.target_size_m / plan.apparent_size_m, MIN_SCALE), MAX_SCALE)
    else:
        scale = 1.0
    # Rest the result on y = 0, centered in x and z.
    lo, hi = _bounds([v for p in parts for v in p.vertices])
    anchor = [(lo[0] + hi[0]) / 2, lo[1], (lo[2] + hi[2]) / 2]
    for part in parts:
        part.vertices = [[(v[i] - anchor[i]) * scale for i in range(3)] for v in part.vertices]
    return refined, scale, skipped


def _linear_to_srgb(c: float) -> float:
    return 12.92 * c if c <= 0.0031308 else 1.055 * c ** (1 / 2.4) - 0.055


def scene_from_glb(data: bytes) -> Scene:
    """Read back a GLB written by mesh.to_glb (one node, mesh and material per part)."""
    magic, _, _ = struct.unpack_from("<4sII", data, 0)
    if magic != b"glTF":
        raise ValueError("Not a GLB file")
    json_len = struct.unpack_from("<I", data, 12)[0]
    gltf = json.loads(data[20:20 + json_len])
    bin_start = 20 + json_len + 8
    binary = data[bin_start:]

    def read(accessor_index: int) -> list:
        acc = gltf["accessors"][accessor_index]
        view = gltf["bufferViews"][acc["bufferView"]]
        offset = view.get("byteOffset", 0) + acc.get("byteOffset", 0)
        width = {"SCALAR": 1, "VEC3": 3}[acc["type"]]
        fmt = {5126: "f", 5125: "I", 5123: "H"}[acc["componentType"]]
        values = struct.unpack_from(f"<{acc['count'] * width}{fmt}", binary, offset)
        return [list(values[i:i + width]) for i in range(0, len(values), width)] if width > 1 else list(values)

    parts = []
    for node in gltf["scenes"][gltf.get("scene", 0)]["nodes"]:
        node = gltf["nodes"][node]
        for prim in gltf["meshes"][node["mesh"]]["primitives"]:
            vertices = read(prim["attributes"]["POSITION"])
            indices = read(prim["indices"])
            factor = gltf["materials"][prim["material"]]["pbrMetallicRoughness"]["baseColorFactor"]
            parts.append(Part(
                name=node.get("name", f"part {len(parts) + 1}"),
                color=[round(_linear_to_srgb(c), 4) for c in factor[:3]],
                vertices=vertices,
                faces=[indices[i:i + 3] for i in range(0, len(indices), 3)],
            ))
    return Scene(name=gltf["scenes"][0].get("name", "model"), parts=parts)
