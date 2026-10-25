"""Runs INSIDE Blender:  blender --background --python blender_build.py -- <out.usdz> <variant>

Stand-in for the script Argon will write. Variant 0 is deliberately broken
(flipped normals, loose geometry, wrong scale) and variant 5 is clean, so the
iOS history strip has something real to swap between before the loop exists.
"""
import sys, math, bpy

argv = sys.argv[sys.argv.index("--") + 1:]
out_path, variant = argv[0], int(argv[1])

bpy.ops.wm.read_factory_settings(use_empty=True)

# --- body -------------------------------------------------------------
bpy.ops.mesh.primitive_cube_add(size=1.0)
body = bpy.context.active_object
body.scale = (0.6, 0.4, 0.35)

bpy.ops.object.select_all(action="DESELECT")
body.select_set(True)
bpy.context.view_layer.objects.active = body
bpy.ops.object.transform_apply(scale=True)

# --- lid --------------------------------------------------------------
bpy.ops.mesh.primitive_cylinder_add(vertices=16, radius=0.4, depth=1.2,
                                    rotation=(0, math.pi / 2, 0))
lid = bpy.context.active_object
lid.scale = (1.0, 1.0, 1.0)
lid.location = (0, 0, 0.35)

# --- the deliberate defects, cleared as the variant climbs -------------
if variant < 3:
    # loose floating chunk
    bpy.ops.mesh.primitive_cube_add(size=0.2, location=(0.9, 0.5, 0.6))
if variant < 4:
    # flipped normals on the lid
    bpy.context.view_layer.objects.active = lid
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.mesh.flip_normals()
    bpy.ops.object.mode_set(mode="OBJECT")
if variant < 2:
    # nonsense scale
    body.scale = (2.4, 1.6, 1.4)

# --- material ---------------------------------------------------------
mat = bpy.data.materials.new("Wood")
mat.use_nodes = True
bsdf = mat.node_tree.nodes["Principled BSDF"]
tone = 0.25 + 0.05 * variant
bsdf.inputs["Base Color"].default_value = (tone, tone * 0.6, tone * 0.3, 1.0)
bsdf.inputs["Roughness"].default_value = 0.8
for obj in bpy.context.scene.objects:
    if obj.type == "MESH":
        obj.data.materials.append(mat)

bpy.ops.object.select_all(action="SELECT")
bpy.ops.wm.usd_export(filepath=out_path, export_materials=True, selected_objects_only=False)
print(f"[blender_build] wrote {out_path}")
