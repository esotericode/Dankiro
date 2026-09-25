class_name MeshKit
extends RefCounted
## Procedural mesh builders for the characters, weapons and props.
##
## Winding: Godot treats clockwise triangles as front faces. For a parametric surface
## P(u, v) whose outward normal is dP/dv x dP/du, quads are emitted as (D, C, A) + (D, A, B)
## with A = (v, u), B = (v, u+1), C = (v+1, u), D = (v+1, u+1).

static var _mat_cache: Dictionary = {}


static func mat(color: Color, roughness := 0.8, metallic := 0.0, opts: Dictionary = {}) -> StandardMaterial3D:
	var cache_key := "%s|%.3f|%.3f|%s" % [color.to_html(), roughness, metallic, str(opts)]
	if _mat_cache.has(cache_key):
		return _mat_cache[cache_key]
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = roughness
	m.metallic = metallic
	if metallic > 0.5:
		m.metallic_specular = 0.6
	if opts.has("clearcoat"):
		m.clearcoat_enabled = true
		m.clearcoat = float(opts["clearcoat"])
		m.clearcoat_roughness = float(opts.get("clearcoat_roughness", 0.15))
	if opts.has("rim"):
		m.rim_enabled = true
		m.rim = float(opts["rim"])
		m.rim_tint = float(opts.get("rim_tint", 0.4))
	if opts.has("emission"):
		m.emission_enabled = true
		m.emission = opts["emission"]
		m.emission_energy_multiplier = float(opts.get("emission_energy", 1.0))
	if opts.get("double_sided", false):
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
	if opts.has("subsurface"):
		m.subsurf_scatter_enabled = true
		m.subsurf_scatter_strength = float(opts["subsurface"])
	_mat_cache[cache_key] = m
	return m


static func glow(color: Color, energy := 3.0) -> StandardMaterial3D:
	var cache_key := "glow|%s|%.2f" % [color.to_html(), energy]
	if _mat_cache.has(cache_key):
		return _mat_cache[cache_key]
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = color
	m.emission_enabled = true
	m.emission = color
	m.emission_energy_multiplier = energy
	_mat_cache[cache_key] = m
	return m


static func add_mesh(parent: Node3D, mesh: Mesh, material: Material, pos := Vector3.ZERO,
		rot_deg := Vector3.ZERO, scl := Vector3.ONE, cast_shadow := true) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = material
	mi.position = pos
	mi.rotation_degrees = rot_deg
	mi.scale = scl
	if not cast_shadow:
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	return mi


static func _quads(st: SurfaceTool, rows: int, cols: int, wrap: bool) -> void:
	# Vertices laid out row-major: index = row * cols + col. Rows follow v, columns follow u.
	var ucount := cols if wrap else cols - 1
	for i in rows - 1:
		for j in ucount:
			var j1 := (j + 1) % cols
			var a := i * cols + j
			var b := i * cols + j1
			var c := (i + 1) * cols + j
			var d := (i + 1) * cols + j1
			st.add_index(d)
			st.add_index(c)
			st.add_index(a)
			st.add_index(d)
			st.add_index(a)
			st.add_index(b)


## Surface of revolution around +Y. `profile` holds (radius, y) points traversed from the
## bottom of the object, around its outside, to the top (outward normals).
static func lathe(profile: PackedVector2Array, segments := 20, sx := 1.0, sz := 1.0, flat := false) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_smooth_group(0xFFFFFFFF if flat else 0)
	for i in profile.size():
		var r := profile[i].x
		var y := profile[i].y
		for j in segments:
			var a := TAU * float(j) / float(segments)
			st.set_uv(Vector2(float(j) / float(segments), float(i) / float(maxi(profile.size() - 1, 1))))
			st.add_vertex(Vector3(cos(a) * r * sx, y, sin(a) * r * sz))
	_quads(st, profile.size(), segments, true)
	st.generate_normals()
	return st.commit()


## Tube swept along a path with per-point radii. Radii of 0 at the ends close the tube.
## `squash` scales the binormal direction (flattened tubes, e.g. ribbons of armor).
static func sweep(path: PackedVector3Array, radii: PackedFloat32Array, segments := 12,
		normal_hint := Vector3(0, 0, -1), squash := 1.0) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := path.size()
	var prev_n := normal_hint.normalized()
	for i in n:
		var t: Vector3
		if i == 0:
			t = (path[1] - path[0]).normalized()
		elif i == n - 1:
			t = (path[n - 1] - path[n - 2]).normalized()
		else:
			t = (path[i + 1] - path[i - 1]).normalized()
		var nn := prev_n - t * prev_n.dot(t)
		if nn.length() < 1e-4:
			nn = t.cross(Vector3.RIGHT)
		nn = nn.normalized()
		prev_n = nn
		var b := nn.cross(t)
		for j in segments:
			var a := TAU * float(j) / float(segments)
			var dir := nn * cos(a) + b * (sin(a) * squash)
			st.add_vertex(path[i] + dir * radii[i])
	_quads(st, n, segments, true)
	st.generate_normals()
	return st.commit()


## Limb segment hanging from the joint along -Y: tapered capsule from r0 (top) to r1 (bottom).
static func limb(length: float, r0: float, r1: float, segments := 16, sx := 1.0, sz := 1.0) -> ArrayMesh:
	var prof := PackedVector2Array()
	var cap := 5
	# bottom cap (around y = -length)
	for i in cap + 1:
		var a := -PI / 2.0 + (PI / 2.0) * float(i) / float(cap)
		prof.append(Vector2(cos(a) * r1, -length + sin(a) * r1 * 0.9))
	# top cap (around y = 0)
	for i in cap + 1:
		var a2 := (PI / 2.0) * float(i) / float(cap)
		prof.append(Vector2(cos(a2) * r0, sin(a2) * r0 * 0.9))
	return lathe(prof, segments, sx, sz)


## Curved blade along +Y. The edge faces local -Z and the blade curves toward +Z (sori).
## `edge_sign` = -1 mirrors it (edge +Z, curving to -Z) for the staff's lower blade.
static func blade(length: float, width: float, thickness: float, curve: float, kissaki := 0.12,
		steps := 16, edge_sign := 1.0, tip_width := -1.0) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_smooth_group(0xFFFFFFFF)
	var tw := width * 0.82 if tip_width < 0.0 else tip_width
	# cross-section in (n, b): n toward the edge, b across the flat. CCW from n toward b.
	var sec := [Vector2(0.5, 0.0), Vector2(-0.15, 0.5), Vector2(-0.5, 0.32), Vector2(-0.5, -0.32), Vector2(-0.15, -0.5)]
	var cols := sec.size()
	var rows := steps + 1
	for i in rows:
		var u := float(i) / float(steps)
		var y := u * length
		var spine_z := curve * u * u * edge_sign                      # quadratic sori
		var w := lerpf(width, tw, u)
		var th := thickness * lerpf(1.0, 0.7, u)
		var tip_start := 1.0 - kissaki
		if u > tip_start:
			var k := (u - tip_start) / kissaki
			w *= sqrt(maxf(0.0, 1.0 - k * k))
			th *= (1.0 - k * 0.9)
		# Edge side (n) is -Z for edge_sign = 1. Binormal b = n x t.
		var n := Vector3(0, 0, -edge_sign)
		var t := Vector3(0, 1, 2.0 * curve * u * edge_sign / maxf(length, 0.001)).normalized()
		n = (n - t * n.dot(t)).normalized()
		var b := n.cross(t)
		# The edge side is thinner toward the tip: shift the section so the back stays straight-ish.
		var center := Vector3(0, y, spine_z) + n * (w * 0.0)
		for s in sec:
			var sv: Vector2 = s
			st.add_vertex(center + n * (sv.x * w) + b * (sv.y * th))
	_quads(st, rows, cols, true)
	st.generate_normals()
	return st.commit()


## Curved armor plate: a slice of a (flared) cylinder shell centered on -Z.
## Radius `r` at y1 (top), `r + flare` at y0 (bottom). `arc_deg` total span.
static func shell(r: float, arc_deg: float, y0: float, y1: float, thickness: float, flare := 0.0,
		segments := 10, rows := 2) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var half := deg_to_rad(arc_deg) * 0.5
	var base := 0
	for layer in 2:
		st.set_smooth_group(layer + 1)
		var off := 0.0 if layer == 0 else -thickness
		for i in rows + 1:
			var v := float(i) / float(rows)
			var y := lerpf(y0, y1, v)
			var rr := r + flare * (1.0 - v) + off
			for j in segments + 1:
				var a := lerpf(-half, half, float(j) / float(segments))
				st.add_vertex(Vector3(sin(a) * rr, y, -cos(a) * rr))
		var cols := segments + 1
		for i in rows:
			for j in segments:
				var a0 := base + i * cols + j
				var b0 := a0 + 1
				var c0 := a0 + cols
				var d0 := c0 + 1
				if layer == 0:
					st.add_index(d0)
					st.add_index(c0)
					st.add_index(a0)
					st.add_index(d0)
					st.add_index(a0)
					st.add_index(b0)
				else:
					st.add_index(a0)
					st.add_index(c0)
					st.add_index(d0)
					st.add_index(b0)
					st.add_index(a0)
					st.add_index(d0)
		base += (rows + 1) * cols
	# Rims (double-sided so their facing never matters).
	var cols2 := segments + 1
	var inner := (rows + 1) * cols2
	st.set_smooth_group(0xFFFFFFFF)
	var rim_pairs: Array = []
	for j in segments:
		rim_pairs.append([j, j + 1])                                   # bottom row
		rim_pairs.append([rows * cols2 + j, rows * cols2 + j + 1])     # top row
	for i in rows:
		rim_pairs.append([i * cols2, (i + 1) * cols2])                 # left column
		rim_pairs.append([i * cols2 + segments, (i + 1) * cols2 + segments])
	for pr in rim_pairs:
		var p0: int = pr[0]
		var p1: int = pr[1]
		st.add_index(p0)
		st.add_index(p1)
		st.add_index(inner + p1)
		st.add_index(p0)
		st.add_index(inner + p1)
		st.add_index(inner + p0)
		st.add_index(inner + p1)
		st.add_index(p1)
		st.add_index(p0)
		st.add_index(inner + p0)
		st.add_index(inner + p1)
		st.add_index(p0)
	st.generate_normals()
	return st.commit()


## Tapered horn/crest along a quadratic bezier from the origin.
static func horn(p1: Vector3, p2: Vector3, base_radius: float, steps := 12, segments := 10, squash := 1.0) -> ArrayMesh:
	var path := PackedVector3Array()
	var radii := PackedFloat32Array()
	for i in steps + 1:
		var t := float(i) / float(steps)
		var p := (1.0 - t) * (1.0 - t) * Vector3.ZERO + 2.0 * (1.0 - t) * t * p1 + t * t * p2
		path.append(p)
		radii.append(base_radius * pow(1.0 - t, 0.8) + 0.0015)
	return sweep(path, radii, segments, Vector3(0, 0, -1), squash)


static func box(size: Vector3) -> BoxMesh:
	var b := BoxMesh.new()
	b.size = size
	return b


static func sphere(radius: float, height := -1.0, segs := 18) -> SphereMesh:
	var s := SphereMesh.new()
	s.radius = radius
	s.height = radius * 2.0 if height < 0.0 else height
	s.radial_segments = segs
	s.rings = maxi(8, segs / 2)
	return s


static func cylinder(r_top: float, r_bottom: float, height: float, segs := 16) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.top_radius = r_top
	c.bottom_radius = r_bottom
	c.height = height
	c.radial_segments = segs
	c.rings = 1
	return c


static func torus(inner: float, outer: float, rings := 24, ring_segments := 8) -> TorusMesh:
	var t := TorusMesh.new()
	t.inner_radius = inner
	t.outer_radius = outer
	t.rings = rings
	t.ring_segments = ring_segments
	return t
