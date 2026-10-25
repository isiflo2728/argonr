"""Rasterise a world so Argon can look at what it built.

Argon authors every vertex; this only turns them into pixels, which is the
one step in the loop that is not a judgement call.
"""

import json
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
RENDERER = ROOT / "server" / "tools" / "usd_render"


def _mesh(name, vertices, faces, colour, at=(0.0, 0.0, 0.0)):
    points = ", ".join(f"({x + at[0]:g}, {y + at[1]:g}, {z + at[2]:g})"
                       for x, y, z in vertices)
    counts = ", ".join(str(len(f)) for f in faces)
    indices = ", ".join(str(i) for f in faces for i in f)
    safe = "".join(c if c.isalnum() else "_" for c in name)[:48] or "mesh"
    return f'''
    def Mesh "{safe}"
    {{
        int[] faceVertexCounts = [{counts}]
        int[] faceVertexIndices = [{indices}]
        point3f[] points = [{points}]
        color3f[] primvars:displayColor = [({colour[0]:.3g}, {colour[1]:.3g}, {colour[2]:.3g})]
        uniform token subdivisionScheme = "none"
    }}'''


def to_usda(world: dict) -> str:
    blocks = []
    width, depth = world["ground"]["size"]
    ground = world["ground"].get("color") or [0.4, 0.45, 0.4]
    blocks.append(_mesh("Ground",
                        [(-width / 2, 0, -depth / 2), (width / 2, 0, -depth / 2),
                         (width / 2, 0, depth / 2), (-width / 2, 0, depth / 2)],
                        [[0, 1, 2, 3]], ground))

    for entity in world["entities"]:
        at = entity.get("position") or [0, 0, 0]
        for i, mesh in enumerate(entity.get("meshes", [])):
            blocks.append(_mesh(f"{entity.get('id', 'e')}_{i}",
                                mesh["vertices"], mesh["faces"],
                                mesh.get("color") or [0.7, 0.7, 0.7], at))

    return f'''#usda 1.0
(
    defaultPrim = "World"
    metersPerUnit = 1
    upAxis = "Y"
)

def Xform "World"
{{{"".join(blocks)}
}}
'''


def render(world: dict, out_dir: pathlib.Path, frames: int = 6, size: int = 800) -> list[str]:
    """-> paths to the rendered frames, newest first in the directory."""
    out_dir.mkdir(parents=True, exist_ok=True)
    scene = out_dir / "world.usda"
    scene.write_text(to_usda(world))

    if not RENDERER.exists():
        return []
    try:
        subprocess.run([str(RENDERER), str(scene), str(out_dir), str(frames), str(size)],
                       check=True, capture_output=True, timeout=180)
    except Exception as exc:
        print(f"[render] failed: {exc}")
        return []
    return [str(p) for p in sorted(out_dir.glob("view*.png"))]
