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
    name: __builtins__[name] if isinstance(__builtins__, dict)
          else getattr(__builtins__, name)
    for name in (
        # values and arithmetic
        "abs", "bool", "complex", "divmod", "float", "int", "pow", "round",
        "bin", "hex", "oct", "chr", "ord", "format", "repr", "str",
        # containers
        "dict", "frozenset", "list", "set", "tuple", "bytes",
        # iteration
        "all", "any", "enumerate", "filter", "iter", "len", "map", "max",
        "min", "next", "range", "reversed", "slice", "sorted", "sum", "zip",
        # structure — geometry code writes helper classes and type checks
        "isinstance", "issubclass", "type", "callable", "hash", "print",
        # exceptions it may raise or catch
        "Exception", "ValueError", "TypeError", "IndexError", "KeyError",
        "ZeroDivisionError", "ArithmeticError", "RuntimeError",
        "StopIteration", "AttributeError", "NotImplementedError",
        "AssertionError", "OverflowError",
    )
}
# Classes need this, and it is not reachable as a name.
_ALLOWED_BUILTINS["__build_class__"] = __build_class__
_ALLOWED_BUILTINS["__name__"] = "generated"

# A generated program naturally opens with `import math`, so banning imports
# outright rejected every good program. Allow the few that only compute.
_ALLOWED_IMPORTS = {"math", "itertools", "functools", "operator"}
_BANNED_NAMES = {"open", "exec", "eval", "compile", "__import__", "globals",
                 "locals", "vars", "getattr", "setattr", "delattr", "input"}


class ProgramError(RuntimeError):
    pass


def _strip_fences(text: str) -> str:
    """Pull the program out of whatever the model wrapped it in.

    A fifty thousand character program is sometimes preceded by a sentence or
    followed by a stray fence, and a single greedy regex gets that wrong in
    both directions. So: take the fenced block when there is one, and
    otherwise fall back to the first line that looks like code, which skips
    any preamble without touching the body's indentation."""
    body = text.strip()

    blocks = re.findall(r"```(?:python)?[ \t]*\n(.*?)(?:```|\Z)", body, re.S)
    if blocks:
        # The program is the longest block — short ones are usually examples.
        return max(blocks, key=len).strip("\n")

    lines = body.splitlines()
    for index, line in enumerate(lines):
        if re.match(r"^(import |from |def |class |#!|# )", line):
            return "\n".join(lines[index:]).strip("\n")
    return body


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


def _truncate_to_last_definition(source: str) -> str | None:
    """Trim trailing lines until what remains parses."""
    lines = source.splitlines()
    for cut in range(len(lines) - 1, max(len(lines) - 400, 0), -1):
        if lines[cut].startswith(("def ", "class ", "import ", "from ")):
            candidate = "\n".join(lines[:cut])
            try:
                ast.parse(candidate)
                return candidate
            except SyntaxError:
                continue
    return None


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
    except SyntaxError as first:
        # A truncated tail is the usual cause on a very long program. Dropping
        # back to the last complete top-level definition salvages the rest
        # rather than losing the whole rewrite.
        salvaged = _truncate_to_last_definition(source)
        if salvaged is None:
            raise ProgramError(
                f"the program did not parse: {first.msg} (line {first.lineno})")
        try:
            tree = ast.parse(salvaged)
            source = salvaged
            print(f"[procedural] salvaged a truncated program "
                  f"({len(source)} of {len(_strip_fences(code))} chars)")
        except SyntaxError:
            raise ProgramError(
                f"the program did not parse: {first.msg} (line {first.lineno})")
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
