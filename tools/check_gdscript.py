"""Heuristic cross-reference checker for this project's GDScript.

gdtoolkit only checks syntax. This catches the typos Godot's analyzer would reject at load
time: calls to functions that don't exist, and member accesses on our own classes
(`anim.foo`, `rig.bar`, `Fx.baz(...)`) that aren't declared anywhere in the class chain.

Usage: python3 tools/check_gdscript.py
"""
import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Receivers we can type by name -> class_name (or autoload script basename).
RECEIVERS = {
    "anim": "PoseAnimator", "rig": "HumanoidRig", "clip": "ClipData", "c": "ClipData",
    "boss": "Boss", "player": "Player", "p": "Player", "opponent": "Combatant", "lock_target": "Combatant",
    "Fx": "Fx", "MeshKit": "MeshKit", "Combat": "Combat", "PoseMath": "PoseMath", "AnimLibrary": "AnimLibrary",
    "ModelBuilder": "ModelBuilder", "Game": "game", "Sfx": "sfx", "GameInput": "game_input",
    "hud": "Hud", "camera": "CombatCamera", "trail": "WeaponTrail", "sc": "SpringChain", "tr": None,
    "arena": "Arena", "_boss_posture": "PostureBar", "_player_posture": "PostureBar",
    "_boss_hp": "VitalityBar", "_player_hp": "VitalityBar", "overlay_clip": "ClipData",
}
# Engine-inherited members that our classes legitimately use through these receivers.
ENGINE_MEMBERS = {
    "global_position", "global_transform", "position", "rotation", "basis", "transform", "visible", "scale",
    "add_child", "get_parent", "get_tree", "queue_free", "create_tween", "get_rid", "velocity", "name",
    "is_inside_tree", "set", "get", "call", "has_method", "emit", "connect", "is_on_floor", "process_mode",
    "force_color", "modulate", "material_override", "top_level", "hp", "max_hp", "posture", "max_posture",
}
GLOBAL_FUNCS = set("""
abs absf absi acos asin atan atan2 bool ceil ceilf ceili clamp clampf clampi cos cosh deg_to_rad ease exp float
floor floorf floori fmod fposmod int is_equal_approx is_instance_valid is_zero_approx lerp lerp_angle lerpf
load log max maxf maxi min minf mini move_toward posmod pow preload print print_debug printerr push_error
push_warning rad_to_deg randf randf_range randi randi_range range round roundf roundi sign signf signi sin
sinh smoothstep snapped sqrt str tan tanh typeof wrapf wrapi len assert await
""".split())
ENGINE_SELF_FUNCS = set("""
add_child get_tree get_parent queue_free create_tween get_viewport is_on_floor move_and_slide
get_slide_collision_count get_slide_collision set_anchors_preset queue_redraw draw_rect draw_circle
draw_arc draw_colored_polygon draw_line add_theme_font_override add_theme_font_size_override
add_theme_color_override add_theme_constant_override add_theme_stylebox_override get_rid
set_process set_physics_process look_at has_method call emit_signal is_inside_tree get_node
""".split())
CONSTRUCTORS = set("""
Vector2 Vector3 Vector4 Color Basis Quaternion Transform3D Transform2D Rect2 AABB Plane PackedVector2Array
PackedVector3Array PackedFloat32Array PackedStringArray PackedColorArray PackedInt32Array Array Dictionary
String StringName NodePath Callable
""".split())
KEYWORDS = set("if elif while for match return and or not in is as func var const signal class super print".split())


def parse_classes():
    classes = {}
    for path in glob.glob(os.path.join(ROOT, "scripts", "**", "*.gd"), recursive=True):
        src = open(path).read()
        m = re.search(r"^class_name\s+(\w+)", src, re.M)
        name = m.group(1) if m else os.path.splitext(os.path.basename(path))[0]
        ext = re.search(r"^extends\s+(\w+)", src, re.M)
        members = set(re.findall(r"^(?:static\s+)?func\s+(\w+)", src, re.M))
        members |= set(re.findall(r"^(?:@export\s+|@onready\s+)?(?:static\s+)?var\s+(\w+)", src, re.M))
        members |= set(re.findall(r"^const\s+(\w+)", src, re.M))
        members |= set(re.findall(r"^signal\s+(\w+)", src, re.M))
        for enum_body in re.findall(r"^enum\s+(\w+)?\s*\{([^}]*)\}", src, re.M | re.S):
            if enum_body[0]:
                members.add(enum_body[0])
            members |= set(re.findall(r"\b([A-Z_][A-Z0-9_]*)\b", enum_body[1]))
        inner = set(re.findall(r"^class\s+(\w+)", src, re.M))
        classes[name] = {"path": path, "extends": ext.group(1) if ext else None, "members": members | inner,
                         "src": src}
    return classes


def parse_types_and_sigs(classes):
    """member -> type for typed vars, and func -> (required, total) arg counts."""
    for name, info in classes.items():
        types, sigs = {}, {}
        for m in re.finditer(r"^(?:@export\s+)?(?:static\s+)?var\s+(\w+)\s*:\s*(\w+)", info["src"], re.M):
            types[m.group(1)] = m.group(2)
        for m in re.finditer(r"^(?:@export\s+)?(?:static\s+)?var\s+(\w+)\s*:=\s*(\w+)\.new\(", info["src"], re.M):
            types[m.group(1)] = m.group(2)
        for m in re.finditer(r"^(?:static\s+)?func\s+(\w+)\s*\(", info["src"], re.M):
            src, i, depth = info["src"], m.end() - 1, 0
            j = i
            while j < len(src):
                if src[j] == "(":
                    depth += 1
                elif src[j] == ")":
                    depth -= 1
                    if depth == 0:
                        break
                j += 1
            params = [x.strip() for x in split_args(src[i + 1:j]) if x.strip()]
            required = sum(1 for x in params if "=" not in x)
            sigs[m.group(1)] = (required, len(params))
        info["types"], info["sigs"] = types, sigs


def split_args(s):
    out, depth, cur = [], 0, ""
    for ch in s:
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(cur)
            cur = ""
        else:
            cur += ch
    if cur.strip():
        out.append(cur)
    return out


def call_args(line, start):
    """Given index of '(' return the argument list string (single line only)."""
    depth, i = 0, start
    while i < len(line):
        if line[i] == "(":
            depth += 1
        elif line[i] == ")":
            depth -= 1
            if depth == 0:
                return line[start + 1:i]
        i += 1
    return None


def resolve_member(classes, cls, attr):
    while cls in classes:
        if attr in classes[cls].get("types", {}):
            return classes[cls]["types"][attr]
        cls = classes[cls]["extends"]
    return None


def find_sig(classes, cls, fn):
    while cls in classes:
        if fn in classes[cls].get("sigs", {}):
            return classes[cls]["sigs"][fn]
        cls = classes[cls]["extends"]
    return None


def chain_members(classes, name):
    out = set()
    while name in classes:
        out |= classes[name]["members"]
        name = classes[name]["extends"]
    return out


def strip_strings_comments(line):
    line = re.sub(r'"(?:[^"\\]|\\.)*"', '""', line)
    line = re.sub(r"'(?:[^'\\]|\\.)*'", "''", line)
    return line.split("#", 1)[0]


def main():
    classes = parse_classes()
    parse_types_and_sigs(classes)
    problems = 0
    for cname, info in sorted(classes.items()):
        own = chain_members(classes, cname)
        in_multiline_string = False
        for i, raw in enumerate(info["src"].splitlines(), 1):
            if raw.count('"""') % 2 == 1:
                in_multiline_string = not in_multiline_string
                continue
            if in_multiline_string:
                continue
            line = strip_strings_comments(raw)
            # locals + params declared in this file (cheap: any var/for/param name anywhere)
            # member access on typed receivers
            for m in re.finditer(r"(?<![\w.])(\w+)\.(\w+)", line):
                recv, attr = m.group(1), m.group(2)
                target = RECEIVERS.get(recv)
                if target is None or target not in classes:
                    continue
                if recv in ("p", "c", "tr") and cname not in ("Boss", "Player", "Hud", "PoseAnimator", "ClipData"):
                    continue
                members = chain_members(classes, target)
                if attr not in members and attr not in ENGINE_MEMBERS:
                    print(f"{os.path.relpath(info['path'], ROOT)}:{i}: '{recv}.{attr}' not found in {target}")
                    problems += 1
            # chained accesses: recv.a.b(...) and (x as Class).member
            for m in re.finditer(r"(?:(?<![\w.])(\w+)|\(\s*[\w.]+\s+as\s+(\w+)\s*\))((?:\.\w+)+)(\s*\()?", line):
                recv = m.group(1)
                cls = m.group(2) or RECEIVERS.get(recv) if recv else m.group(2)
                if recv and recv in ("p", "c", "tr") and cname not in ("Boss", "Player", "Hud", "PoseAnimator", "ClipData"):
                    continue
                if recv == "self":
                    cls = cname
                if cls is None or cls not in classes:
                    continue
                parts = m.group(3).split(".")[1:]
                for k, attr in enumerate(parts):
                    if cls not in classes:
                        break
                    members = chain_members(classes, cls)
                    if attr not in members:
                        if attr not in ENGINE_MEMBERS:
                            print(f"{os.path.relpath(info['path'], ROOT)}:{i}: '{attr}' not found in {cls} ({m.group(0).strip()})")
                            problems += 1
                        break
                    is_last = k == len(parts) - 1
                    if is_last and m.group(4):
                        sig = find_sig(classes, cls, attr)
                        args = call_args(line, m.end() - 1)
                        if sig and args is not None:
                            n = len([x for x in split_args(args) if x.strip()])
                            if n < sig[0] or n > sig[1]:
                                print(f"{os.path.relpath(info['path'], ROOT)}:{i}: {cls}.{attr}() takes {sig[0]}-{sig[1]} args, got {n}")
                                problems += 1
                    cls = resolve_member(classes, cls, attr)
                    if cls is None:
                        break
            # arity of bare calls to own functions
            for m in re.finditer(r"(?<![\w.])([a-z_]\w*)\s*\(", line):
                fn = m.group(1)
                if fn in own and not re.search(r"\bfunc\s+" + fn + r"\b", line):
                    sig = find_sig(classes, cname, fn)
                    args = call_args(line, m.end() - 1)
                    if sig and args is not None:
                        n = len([x for x in split_args(args) if x.strip()])
                        if n < sig[0] or n > sig[1]:
                            print(f"{os.path.relpath(info['path'], ROOT)}:{i}: {fn}() takes {sig[0]}-{sig[1]} args, got {n}")
                            problems += 1
            # bare calls
            for m in re.finditer(r"(?<![\w.])([a-z_]\w*)\s*\(", line):
                fn = m.group(1)
                if fn in KEYWORDS or fn in GLOBAL_FUNCS or fn in ENGINE_SELF_FUNCS or fn in own:
                    continue
                if re.search(r"\bfunc\s+" + fn + r"\b", line):
                    continue
                # lambdas / locals holding callables are rare here; report
                print(f"{os.path.relpath(info['path'], ROOT)}:{i}: call to unknown function '{fn}' in {cname}")
                problems += 1
            for m in re.finditer(r"(?<![\w.])([A-Z]\w*)\s*\(", line):
                ctor = m.group(1)
                if ctor in CONSTRUCTORS or ctor in classes:
                    continue
                print(f"{os.path.relpath(info['path'], ROOT)}:{i}: unknown constructor '{ctor}('")
                problems += 1
    print(f"{problems} potential problems")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
