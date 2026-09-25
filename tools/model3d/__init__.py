"""Scripted 3D model pipeline (Blender as a Python module).

Install once:  pip install bpy==4.5.9   (Blender 4.5 LTS; needs Python 3.11)

Geometry is authored in numpy in *game space* (Godot: +Y up, the character faces -Z and its
left is -X), handed to Blender for modifiers, UV packing, texture baking and skinning, and
exported as .glb. The exporter converts back to +Y up, so the .glb is in game space exactly.
"""
