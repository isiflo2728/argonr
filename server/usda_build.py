"""Builds a scene as USD ASCII text — no Blender, no dependencies.

This is the stand-in for what Argon will write. Argon's whole job becomes
"emit a .usda", which is code generation, its strongest mode. The fix step is
then a text rewrite rather than patching a script and re-running a modeller.

    python3 usda_build.py out.usda 0      # variant 0 = deliberately broken

Variants 0-5 start wrong and get corrected, so the version strip has
something real to swap between before the loop exists.
"""
import sys


def box(name, size, at, color, flip=False):
    """One axis-aligned box. `flip` reverses winding, which is what inverted
    normals look like — faces vanish or render black."""
    sx, sy, sz = (d / 2 for d in size)
    points = [(-sx, 0, -sz), (sx, 0, -sz), (-sx, sy * 2, -sz), (sx, sy * 2, -sz),
              (-sx, 0, sz), (sx, 0, sz), (-sx, sy * 2, sz), (sx, sy * 2, sz)]
    faces = [(0, 1, 3, 2), (2, 3, 7, 6), (6, 7, 5, 4), (4, 5, 1, 0), (2, 6, 4, 0), (7, 3, 1, 5)]
    if flip:
        faces = [tuple(reversed(f)) for f in faces]
    indices = [i for f in faces for i in f]

    pts = ", ".join(f"({x}, {y}, {z})" for x, y, z in points)
    return f'''
    def Mesh "{name}"
    {{
        int[] faceVertexCounts = [{", ".join("4" for _ in faces)}]
        int[] faceVertexIndices = [{", ".join(str(i) for i in indices)}]
        point3f[] points = [{pts}]
        color3f[] primvars:displayColor = [({color[0]}, {color[1]}, {color[2]})]
        uniform token subdivisionScheme = "none"
        double3 xformOp:translate = ({at[0]}, {at[1]}, {at[2]})
        uniform token[] xformOpOrder = ["xformOp:translate"]
    }}'''


def build(variant):
    parts = []
    scale = 2.4 if variant < 2 else 1.0          # v0-v1: scale applied twice
    flip = variant < 4                            # v0-v3: normals inverted on the mug
    parts.append(box("Desk", (1.2 * scale, 0.04, 0.6 * scale), (0, 0, 0), (0.42, 0.30, 0.20)))
    parts.append(box("Mug", (0.09, 0.10, 0.09), (-0.30, 0.04, 0.10), (0.85, 0.85, 0.82), flip=flip))

    if variant >= 1:
        parts.append(box("Keyboard", (0.42, 0.02, 0.14), (0.10, 0.04, -0.02), (0.18, 0.18, 0.20)))
    if variant >= 2:
        parts.append(box("Monitor", (0.52, 0.32, 0.03), (0.10, 0.06, -0.22), (0.12, 0.12, 0.14)))
    if variant >= 3:
        parts.append(box("Notebook", (0.20, 0.02, 0.26), (0.42, 0.04, 0.14), (0.70, 0.25, 0.22)))
    if variant < 3:
        # A chunk floating with nothing under it.
        parts.append(box("Stray", (0.08, 0.08, 0.08), (0.55, 0.60, 0.25), (0.6, 0.6, 0.6)))

    return f'''#usda 1.0
(
    defaultPrim = "Scene"
    metersPerUnit = 1
    upAxis = "Y"
)

def Xform "Scene"
{{{"".join(parts)}
}}
'''


if __name__ == "__main__":
    out, variant = sys.argv[1], int(sys.argv[2])
    with open(out, "w") as f:
        f.write(build(variant))
    print(f"[usda_build] wrote {out} (variant {variant})")
