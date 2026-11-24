"""Turns the CC0 Xbox One controller model into App/Resources/XboxController.usdz for the Controller Test.

Source: "Microsoft Xbox One.blend" from https://github.com/CasperH2O/3DControllerModels (CC0 1.0).

    /Applications/Blender.app/Contents/MacOS/Blender --background --disable-autoexec \
        "path/to/Microsoft Xbox One.blend" --python scripts/controller-model/export-xbox.py -- App/Resources/XboxController.usdz

What it does:
- Turns it so +Y is the top of the controller (the triggers) and +Z points out of its face,
  centres it and scales it to 2 units across.
- Puts every part's origin at the centre of its bounds.
- Drops materials: the app colours each part itself.
"""

import sys

import bpy
from mathutils import Matrix, Vector

out = sys.argv[sys.argv.index("--") + 1]

for o in list(bpy.data.objects):
    if o.type != "MESH":
        bpy.data.objects.remove(o)

# Bake every object's transform, then turn, centre and scale the whole thing.
# Blender's axes for this model: x right, -y out of the face, +z towards the triggers.
meshes = [o for o in bpy.data.objects if o.type == "MESH"]
for o in meshes:
    o.data.materials.clear()
    o.data.transform(o.matrix_world)
    o.matrix_world = Matrix.Identity(4)
lo = Vector((1e9,) * 3)
hi = Vector((-1e9,) * 3)
for o in meshes:
    for v in o.data.vertices:
        lo = Vector(map(min, lo, v.co))
        hi = Vector(map(max, hi, v.co))
scale = 2 / (hi.x - lo.x)
# (x, y, z) -> (x, z, -y): face towards +Z, triggers towards +Y
turn = Matrix.Rotation(-1.5707963267948966, 4, "X")
fix = turn @ Matrix.Scale(scale, 4) @ Matrix.Translation(-(lo + hi) / 2)
for o in meshes:
    o.data.transform(fix)
    o.data.update()

bpy.ops.object.select_all(action="SELECT")
bpy.ops.object.origin_set(type="ORIGIN_GEOMETRY", center="BOUNDS")

for o in meshes:
    corners = [o.matrix_world @ Vector(c) for c in o.bound_box]
    lo = Vector([min(c[i] for c in corners) for i in range(3)])
    hi = Vector([max(c[i] for c in corners) for i in range(3)])
    print("PART", o.name.ljust(24), "centre", [round(v, 3) for v in o.location], "size", [round(v, 3) for v in hi - lo])

bpy.ops.wm.usd_export(
    filepath=out,
    selected_objects_only=False,
    export_materials=False,
    export_uvmaps=False,
    export_animation=False,
    convert_orientation=False,
)
print("EXPORTED", out)
