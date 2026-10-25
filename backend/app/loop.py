"""Argon plays its own game, works out what is broken, and rewrites it.

The division of labour matters. Argon writes the program that computes every
vertex, decides what the telemetry means, and rewrites the world. This module
only does the things a language model should not: execute the program,
rasterise pixels, step the simulation, and carry evidence between passes.

So the loop is render -> watch -> critique -> fix, with Argon doing the
watching, the critiquing and the fixing. The measurements are ground truth it
cannot talk its way around: a match that ends in four seconds ended in four
seconds.
"""

import json
import time

from app import playtest, world as world_mod
from app.procedural import ProgramError

CRITIQUE_INSTRUCTION = """You are playtesting a tabletop game you built.

You are given four things: what the game was meant to be, the world as it
stands, images of it rendered from several angles, and telemetry from playing
it through several times.

Decide what is actually wrong. Trust the telemetry over the images for
balance and the images over the telemetry for how it looks — a match that
ended in four seconds ended in four seconds, and a model that renders black
is facing the wrong way whatever the numbers say.

Reply with ONLY a JSON object:

{"verdict": "<one sentence on whether this is worth playing>",
 "score": <0-1, how good a game this is right now>,
 "bugs": [
   {"severity": "high|med|low",
    "kind": "<short slug, e.g. one_sided, invisible_mesh, never_engaged>",
    "evidence": "<what you observed, with the number or the frame>",
    "cause": "<why the world produces it>",
    "fix": "<the specific change>"}],
 "keep": ["<what already works and must not be broken>"]}

Rank the worst first, at most six. Be concrete: "the AT-ST has 90 hp against
rebel damage totalling 14 per exchange, so it never dies" beats "balance is
off"."""

FIX_INSTRUCTION = """You are fixing a game you built and then playtested.

You are given the world, your own critique of it, and the telemetry behind
that critique. Write a Python program defining build() -> dict returning the
fixed world.

Fix what the critique found. Everything under "keep" must survive unchanged,
and so must every entity id — the person is watching this scene and it must
not jump around. Geometry for anything the critique did not mention stays as
it was.

You are also given what earlier passes already tried. Read it before you
change anything. If the last pass moved an advantage from one side to the
other, the correction was too large: halve it rather than swinging it back.
A balance that oscillates is a worse bug than the one you set out to fix.

Same schema and the same rules as the original build. Output ONLY the
program."""


def _image_parts(paths, limit=6):
    """generate_content takes typed Parts — raw dicts are the Interactions
    API's shape and fail validation here."""
    import pathlib

    from google.genai import types

    return [types.Part.from_bytes(data=pathlib.Path(path).read_bytes(),
                                  mime_type="image/png")
            for path in list(paths)[:limit]]


def _text(body):
    from google.genai import types
    return types.Part.from_text(text=body)


async def critique(client, model, goal, world, telemetry, frames):
    """Argon watches its own render next to the telemetry and judges it."""
    body = f"""The game was meant to be: {goal}

The world as it stands:

```json
{json.dumps(world)[:120000]}
```

Telemetry from {telemetry['runs']} playthroughs:

```json
{json.dumps(telemetry, indent=1)}
```

The images are that world rendered from several angles."""

    response = await client.aio.models.generate_content(
        model=model,
        contents=_image_parts(frames) + [_text(body)],
        config={"system_instruction": CRITIQUE_INSTRUCTION,
                "response_mime_type": "application/json",
                "max_output_tokens": 32768},
    )
    try:
        return json.loads(response.text or "{}")
    except json.JSONDecodeError:
        return {"verdict": "critique did not parse", "score": 0.0,
                "bugs": [], "keep": [], "raw": (response.text or "")[:2000]}


def _attempts(history):
    """What earlier passes tried and what it did to the outcome, so a fix can
    see its own overshoot instead of repeating it in the other direction."""
    if not history:
        return "This is the first pass. Nothing has been tried yet."
    lines = []
    for entry in history:
        tried = "; ".join(b.get("fix", "")[:110] for b in (entry.get("bugs") or [])[:3])
        lines.append(
            f"Pass {entry['pass']}: matches ran {entry.get('avg_seconds')}s, "
            f"winners {entry.get('winners')}. You changed: {tried or '(nothing)'}")
    return "\n".join(lines)


async def fix(client, model, world, verdict, telemetry, history=None):
    """Argon rewrites the world to answer its own critique."""
    body = f"""What earlier passes already tried:

{_attempts(history)}

The world:

```json
{json.dumps(world)[:120000]}
```

Your critique:

```json
{json.dumps(verdict, indent=1)}
```

The telemetry behind it:

```json
{json.dumps(telemetry, indent=1)}
```"""

    response = await client.aio.models.generate_content(
        model=model,
        contents=body,
        config={"system_instruction": FIX_INSTRUCTION, "max_output_tokens": 262144},
    )
    code = response.text or ""
    fixed, stats = world_mod.world_from_program(code)
    # Plain dict out: everything downstream — playtest, render, the response —
    # works on dicts, and a model leaking through broke the next pass.
    return fixed.model_dump(), stats, len(code)


async def iterate(client, model, goal, world, render, passes=3, runs=5):
    """Play, judge, fix, repeat. `render` turns a world into image paths."""
    history = []
    current = world

    for index in range(passes):
        started = time.monotonic()

        telemetry = playtest.playtest(current, runs=runs)
        frames = render(current, index)
        verdict = await critique(client, model, goal, current, telemetry, frames)

        entry = {
            "pass": index,
            "score": verdict.get("score"),
            "verdict": verdict.get("verdict"),
            "playable": telemetry["playable"],
            "avg_seconds": telemetry["avg_seconds"],
            "winners": telemetry["winners"],
            "bugs": verdict.get("bugs", []),
            "measured_bugs": telemetry["bugs"],
            "seconds": round(time.monotonic() - started, 1),
        }

        bugs = verdict.get("bugs", [])
        if index == passes - 1 or not bugs:
            entry["fixed"] = False
            history.append(entry)
            break

        try:
            current, stats, chars = await fix(
                client, model, current, verdict, telemetry, history)
            entry["fixed"] = True
            entry["program_chars"] = chars
            entry["after"] = stats
        except (ProgramError, ValueError) as e:
            # A failed rewrite must not lose the world that already works.
            entry["fixed"] = False
            entry["fix_error"] = str(e)[:300]
            history.append(entry)
            break

        history.append(entry)

    return current, history
