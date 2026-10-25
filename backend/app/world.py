"""A whole playable world from one decode.

Generating a scene object by object means every call is a cold start: nothing
shares a scale, a palette, or a sense of where anything else sits. The parts
never add up to a place.

So the unit of generation is the world. One program returns every asset's
geometry, where each one stands, which side it is on, and how it behaves —
tens of thousands of lines in a single response, which is what a million
token output window is actually for.

Behaviour is a name, not code. The model picks from a set the client already
implements, so a generated world cannot crash the thing simulating it: the
worst a bad world can do is play badly.
"""

import math
from pydantic import BaseModel, Field, field_validator

from app.procedural import ProgramError, run_program

BEHAVIOURS = ("charge", "hold", "skirmish", "ranged", "static", "wander")


class Mesh(BaseModel):
    name: str = Field(description="What this piece is, e.g. 'helmet'")
    color: list[float] = Field(description="[r, g, b], 0-1, sRGB")
    vertices: list[list[float]] = Field(description="[x, y, z] metres, local to the entity")
    faces: list[list[int]] = Field(description="Indices into this mesh's vertices, CCW from outside")


class Entity(BaseModel):
    id: str
    name: str
    team: str = Field(description="A team id, or 'neutral' for scenery")
    # A plain string with a validator rather than a Literal: a world that
    # invents one behaviour should lose that behaviour, not be thrown away
    # whole. Rejecting the lot cost a working rewrite once already.
    behaviour: str = "charge"
    hp: float = 10
    damage: float = 2
    range: float = 0.06
    speed: float = 0.03
    position: list[float] = Field(description="[x, 0, z] metres on the board")
    meshes: list[Mesh] = Field(description="Geometry, resting on y=0, centred on x and z")


    @field_validator("behaviour", mode="before")
    @classmethod
    def _known_behaviour(cls, value):
        text = str(value or "").strip().lower()
        if text in BEHAVIOURS:
            return text
        # Nearest sensible neighbour for the ones a model reaches for.
        return {
            "direct": "charge", "attack": "charge", "melee": "charge",
            "aggressive": "charge", "assault": "charge", "rush": "charge",
            "defend": "hold", "guard": "hold", "defensive": "hold",
            "turret": "hold", "stationary": "static", "scenery": "static",
            "prop": "static", "terrain": "static", "fixed": "static",
            "shoot": "ranged", "shooter": "ranged", "artillery": "ranged",
            "sniper": "ranged", "support": "ranged", "fire": "ranged",
            "harass": "skirmish", "flank": "skirmish", "scout": "skirmish",
            "patrol": "wander", "roam": "wander", "idle": "wander",
        }.get(text, "charge")


class Team(BaseModel):
    id: str
    name: str
    color: list[float]


class Ground(BaseModel):
    size: list[float] = Field(description="[width, depth] metres, at most 1.2 x 0.8")
    color: list[float] = [0.32, 0.42, 0.26]


class World(BaseModel):
    name: str
    pitch: str = Field(description="One line on what this game is")
    ground: Ground
    teams: list[Team]
    entities: list[Entity]
    victory: str = "eliminate"
    notes: str = ""


SYSTEM_INSTRUCTION = f"""You build complete playable tabletop worlds. You
write Python that computes geometry; you never write vertex coordinates by
hand.

Output ONLY a Python program. No prose, no markdown fences.

The program defines:

    def build() -> dict

returning a world:

    {{"name": "...", "pitch": "one line on what this game is",
      "ground": {{"size": [w, d], "color": [r,g,b]}},
      "teams": [{{"id": "red", "name": "...", "color": [r,g,b]}}, ...],
      "entities": [
        {{"id": "red_1", "name": "Pikeman", "team": "red",
          "behaviour": "charge", "hp": 12, "damage": 3,
          "range": 0.05, "speed": 0.035,
          "position": [x, 0, z],
          "meshes": [{{"name": "body", "color": [r,g,b],
                      "vertices": [[x,y,z], ...], "faces": [[i,j,k,...], ...]}}]
        }}, ...],
      "victory": "eliminate", "notes": ""}}

## Geometry

- Compute it. Revolve profiles for anything round, sweep along a path for
  limbs, spouts and handles, 12-20 segments where a surface should read as
  curved. Write helper functions and reuse them across entities.
- Metres. Each entity's meshes are local to it, resting on y = 0 and centred
  on x and z — the engine places it by `position`.
- A tabletop figure is 0.04-0.08 m tall. Scenery can reach 0.25 m.
- Faces wind counter-clockwise seen from outside. A reversed face renders
  black.
- Each mesh's faces index only that mesh's vertices, from 0.
- Give each visually distinct piece its own mesh with its own colour.

## The game

- 8 to 16 entities. Two fighting sides plus scenery on team "neutral".
- Behaviour is one of: {", ".join(BEHAVIOURS)}.
    charge   close and fight hand to hand
    hold     stand your ground, fight what arrives
    skirmish advance, fall back when hurt
    ranged   keep your distance and shoot
    static   never moves, never attacks (rocks, trees, towers)
    wander   drifts, fights what it meets
- Ground is at most 1.2 x 0.8 m. Everything sits inside it.
- Put the sides apart so they have room to close. Keep entities at least
  0.04 m from each other.
- Vary the stats so the sides are different, not mirrored. An interesting
  fight is asymmetric.

## Budget

Total vertices across the whole world under 40000. Spend it: detailed figures
beat a crowd of blocks. Write the longest, most complete program you can —
the whole world arrives in this one response, so there is nothing to hold
back for."""


REVISE_INSTRUCTION = """You are revising a world you already built.

You are given the current world as JSON and a request. Write a Python program
defining build() -> dict that returns the revised world.

Change what the request implies and leave everything else exactly as it was,
including entity ids and the geometry of anything untouched — the person is
watching this scene and it should not jump around.

Same schema and the same rules as before. Output ONLY the program."""


def _finite(values) -> bool:
    return all(isinstance(v, (int, float)) and math.isfinite(v) for v in values)


def validate(world: World) -> dict[str, int]:
    """Clamp a world onto a real table and report what it cost.

    A generated world is checked rather than trusted: nothing escapes the
    board, no mesh is degenerate, and an unknown behaviour becomes one the
    engine knows.
    """
    if not world.entities:
        raise ValueError("world has no entities")

    w = min(max(float(world.ground.size[0]), 0.2), 1.2)
    d = min(max(float(world.ground.size[1]), 0.2), 0.8)
    world.ground.size = [w, d]

    teams = {t.id for t in world.teams} | {"neutral"}
    vertices = faces = 0
    kept: list[Entity] = []

    for entity in world.entities:
        meshes = []
        for mesh in entity.meshes:
            if len(mesh.vertices) < 3 or not mesh.faces:
                continue
            if not all(len(v) == 3 and _finite(v) for v in mesh.vertices):
                continue
            limit = len(mesh.vertices)
            mesh.faces = [f for f in mesh.faces
                          if len(f) >= 3 and all(0 <= i < limit for i in f)]
            if not mesh.faces:
                continue
            if len(mesh.color) != 3 or not _finite(mesh.color):
                mesh.color = [0.7, 0.7, 0.7]
            mesh.color = [min(max(c, 0.0), 1.0) for c in mesh.color]
            vertices += len(mesh.vertices)
            faces += len(mesh.faces)
            meshes.append(mesh)

        if not meshes:
            continue
        entity.meshes = meshes

        if entity.team not in teams:
            entity.team = "neutral"
        position = entity.position if len(entity.position) == 3 and _finite(entity.position) \
            else [0.0, 0.0, 0.0]
        entity.position = [min(max(position[0], -w / 2), w / 2), 0.0,
                           min(max(position[2], -d / 2), d / 2)]
        entity.hp = max(1.0, min(entity.hp, 500))
        entity.damage = max(0.0, min(entity.damage, 100))
        entity.range = max(0.01, min(entity.range, 0.6))
        entity.speed = max(0.0, min(entity.speed, 0.3))
        kept.append(entity)

    if not kept:
        raise ValueError("every entity was dropped as malformed")
    world.entities = kept

    return {"entities": len(kept), "vertices": vertices, "faces": faces,
            "meshes": sum(len(e.meshes) for e in kept)}


def world_from_program(code: str) -> tuple[World, dict[str, int]]:
    """Program text in, a checked World out."""
    world = World.model_validate(run_program(code, timeout=60.0))
    return world, validate(world)
