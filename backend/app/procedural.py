"""Have the model write a program that builds the mesh, not the mesh itself.

Asking for `vertices: [[x, y, z], ...]` makes the model do 3D arithmetic in
its head, one coordinate at a time. It cannot revolve a profile that way, so
round things come out faceted and normals drift until surfaces vanish.

Writing `for i in range(32): angle = i * TAU / 32` is the same model's
strongest mode, and the output window is big enough to hold the program.

Measured on "a blue ceramic teapot with a curved spout and a round handle",
same schema, same model:

    listing vertices   230 verts   176 distinct normals   186s   broken
    writing a program  3124 verts  1107 distinct normals    98s   a teapot

Faster as well as better: ten kilobytes of Python is less to emit than three
thousand hand-written coordinates.
"""

import ast
import math
import re
from concurrent.futures import ThreadPoolExecutor, TimeoutError as FutureTimeout

from app.mesh import InvalidMeshError, Scene, validate

PROGRAM_INSTRUCTION = """You are a 3D modelling assistant. You write Python
that builds geometry; you never write vertex coordinates by hand.

Output ONLY a Python program. No prose, no markdown fences.

The program defines:

    def build() -> dict

returning:

    {"name": "<short name>",
     "parts": [{"name": "<part>",
                "color": [r, g, b],          # 0-1, sRGB, realistic
                "vertices": [[x, y, z], ...],  # metres
                "faces": [[i, j, k, ...], ...]  # indices into THIS part
               }, ...]}

Rules:
- Metres, Y up. The model rests on y = 0 and is centred on x and z.
- Compute geometry. Revolve a profile for anything round, sweep along a path
  for spouts, handles and limbs, and use 20-32 segments where a surface
  should read as curved.
- Give each visually distinct piece its own part with its own colour.
- Faces wind counter-clockwise seen from outside. Get this right: a reversed
  face renders black or disappears.
- Each part's faces index only that part's vertices, from 0.
- Keep the whole model under 20000 vertices.
- Only these imports are available: math, itertools, functools, operator.
  No file, network or system access.
"""

# Enough to compute geometry, nothing more. The code comes from the model
# rather than from a user, but it is still generated text being executed, so
# it gets a narrow surface and a timeout rather than the run of the process.
_ALLOWED_BUILTINS = {
    "abs": abs, "all": all, "any": any, "bool": bool, "dict": dict,
    "divmod": divmod, "enumerate": enumerate, "filter": filter, "float": float,
    "int": int, "len": len, "list": list, "map": map, "max": max, "min": min,
    "pow": pow, "range": range, "reversed": reversed, "round": round,
    "set": set, "sorted": sorted, "str": str, "sum": sum, "tuple": tuple,
    "zip": zip, "ValueError": ValueError, "IndexError": IndexError,
    "TypeError": TypeError, "ZeroDivisionError": ZeroDivisionError,
    "__build_class__": __build_class__, "__name__": "generated",
}

# A generated program naturally opens with `import math`, so banning imports
# outright rejected every good program. Allow the few that only compute.
_ALLOWED_IMPORTS = {"math", "itertools", "functools", "operator"}
_BANNED_NAMES = {"open", "exec", "eval", "compile", "__import__", "globals",
                 "locals", "vars", "getattr", "setattr", "delattr", "input"}


class ProgramError(RuntimeError):
    pass


def _strip_fences(text: str) -> str:
    fenced = re.search(r"```(?:python)?\s*\n(.*?)```", text, re.S)
    return (fenced.group(1) if fenced else text).strip()


def _check(tree: ast.AST) -> None:
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                root = alias.name.split(".")[0]
                if root not in _ALLOWED_IMPORTS:
                    raise ProgramError(f"the program imported {alias.name}")
        elif isinstance(node, ast.ImportFrom):
            root = (node.module or "").split(".")[0]
            if root not in _ALLOWED_IMPORTS:
                raise ProgramError(f"the program imported from {node.module}")
        if isinstance(node, ast.Name) and node.id in _BANNED_NAMES:
            raise ProgramError(f"the program referenced {node.id}")
        if isinstance(node, ast.Attribute) and node.attr.startswith("__"):
            raise ProgramError("the program reached for a dunder attribute")


def _safe_import(name, globals=None, locals=None, fromlist=(), level=0):
    """The allowlist again, at runtime — the AST pass can be walked around."""
    root = name.split(".")[0]
    if root not in _ALLOWED_IMPORTS:
        raise ProgramError(f"the program imported {name}")
    return __import__(name, globals, locals, fromlist, level)


def run_program(code: str, timeout: float = 20.0) -> dict:
    """Executes a generated program and returns whatever build() produced."""
    source = _strip_fences(code)
    try:
        tree = ast.parse(source)
    except SyntaxError as e:
        raise ProgramError(f"the program did not parse: {e.msg} (line {e.lineno})")
    _check(tree)

    env = {"__builtins__": dict(_ALLOWED_BUILTINS, __import__=_safe_import),
           "math": math}

    def call():
        exec(compile(tree, "generated", "exec"), env)
        build = env.get("build")
        if not callable(build):
            raise ProgramError("the program defined no build()")
        return build()

    with ThreadPoolExecutor(max_workers=1) as pool:
        try:
            result = pool.submit(call).result(timeout=timeout)
        except FutureTimeout:
            raise ProgramError(f"the program ran longer than {timeout:.0f}s")
        except ProgramError:
            raise
        except Exception as e:
            raise ProgramError(f"{type(e).__name__}: {e}")

    if not isinstance(result, dict):
        raise ProgramError(f"build() returned {type(result).__name__}, not a dict")
    return result


def scene_from_program(code: str) -> tuple[Scene, dict[str, int]]:
    """Program text in, validated Scene out."""
    scene = Scene.model_validate(run_program(code))
    return scene, validate(scene)
