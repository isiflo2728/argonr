"""Play the game, measure what went wrong, hand Argon the evidence.

A generated world can be beautiful and unplayable. The only way to know is to
play it, so this runs the same simulation the client runs, many times, and
reports facts rather than impressions: how long a match lasted, whether one
side ever lost, whether anybody got stuck, whether half the roster never
mattered.

Those are the bugs Argon then fixes. They are measurable, which is what makes
the loop converge instead of drifting on taste.
"""

import math
import random
from dataclasses import dataclass, field

ATTACK_INTERVAL = 0.6
PERSONAL_SPACE = 0.022
STEP = 1 / 30
MAX_SECONDS = 180


@dataclass
class Unit:
    index: int
    name: str
    team: str
    behaviour: str
    max_hp: float
    damage: float
    range: float
    speed: float
    x: float
    z: float
    hp: float
    cooldown: float = 0.0
    damage_dealt: float = 0.0
    distance_moved: float = 0.0
    attacks: int = 0
    died_at: float | None = None

    @property
    def alive(self) -> bool:
        return self.hp > 0

    @property
    def fighter(self) -> bool:
        return self.behaviour != "static" and self.damage > 0 and self.team != "neutral"


@dataclass
class Match:
    seconds: float = 0.0
    winner: str | None = None
    ended: bool = False
    survivors: dict[str, int] = field(default_factory=dict)
    units: list[Unit] = field(default_factory=list)


def simulate(world: dict, seed: int = 0) -> Match:
    """One match, deterministic for a given seed."""
    rng = random.Random(seed)
    half_w = world["ground"]["size"][0] / 2
    half_d = world["ground"]["size"][1] / 2

    units: list[Unit] = []
    for i, e in enumerate(world["entities"]):
        position = e.get("position") or [0, 0, 0]
        units.append(Unit(
            index=i, name=e.get("name", e.get("id", f"unit{i}")),
            team=e.get("team", "neutral"), behaviour=e.get("behaviour", "charge"),
            max_hp=max(1.0, float(e.get("hp", 10))), damage=float(e.get("damage", 2)),
            range=max(0.01, float(e.get("range", 0.06))), speed=float(e.get("speed", 0.03)),
            x=float(position[0]), z=float(position[2]), hp=max(1.0, float(e.get("hp", 10)))))

    match = Match(units=units)
    time = 0.0

    while time < MAX_SECONDS:
        time += STEP

        for unit in units:
            if not unit.alive or unit.behaviour == "static":
                continue
            unit.cooldown = max(0.0, unit.cooldown - STEP)

            target = _nearest_enemy(units, unit)
            if target is None:
                continue

            dx, dz = target.x - unit.x, target.z - unit.z
            distance = math.hypot(dx, dz)
            if distance < 1e-5:
                continue
            ux, uz = dx / distance, dz / distance

            if unit.behaviour == "charge":
                want = unit.range * 0.6
            elif unit.behaviour == "hold":
                want = distance
            elif unit.behaviour == "skirmish":
                want = unit.range * (2.5 if unit.hp / unit.max_hp < 0.4 else 0.7)
            elif unit.behaviour == "ranged":
                want = unit.range * 0.85
            elif unit.behaviour == "wander":
                want = unit.range * 0.9
            else:
                want = distance

            gap = distance - want
            if abs(gap) > 0.004 and unit.speed > 0:
                move = min(unit.speed * STEP, abs(gap))
                unit.x += ux * (move if gap > 0 else -move)
                unit.z += uz * (move if gap > 0 else -move)
                unit.x = min(max(unit.x, -half_w), half_w)
                unit.z = min(max(unit.z, -half_d), half_d)
                unit.distance_moved += move

            if distance <= unit.range and unit.cooldown == 0 and unit.fighter:
                target.hp -= unit.damage
                unit.damage_dealt += unit.damage
                unit.attacks += 1
                unit.cooldown = ATTACK_INTERVAL
                if target.hp <= 0 and target.died_at is None:
                    target.died_at = time

        _separate(units, half_w, half_d)

        standing = {u.team for u in units if u.alive and u.fighter}
        if len(standing) <= 1:
            match.ended = True
            match.winner = next(iter(standing), None)
            break

    match.seconds = round(time, 1)
    match.survivors = {}
    for unit in units:
        if unit.alive and unit.team != "neutral":
            match.survivors[unit.team] = match.survivors.get(unit.team, 0) + 1
    return match


def _nearest_enemy(units: list[Unit], unit: Unit) -> Unit | None:
    best, best_distance = None, float("inf")
    for other in units:
        if not other.alive or other.team == unit.team or other.team == "neutral":
            continue
        distance = math.hypot(other.x - unit.x, other.z - unit.z)
        if distance < best_distance:
            best, best_distance = other, distance
    return best


def _separate(units: list[Unit], half_w: float, half_d: float) -> None:
    for a in units:
        if not a.alive or a.behaviour == "static":
            continue
        for b in units:
            if b is a or not b.alive:
                continue
            dx, dz = a.x - b.x, a.z - b.z
            distance = math.hypot(dx, dz)
            if 1e-5 < distance < PERSONAL_SPACE:
                push = (PERSONAL_SPACE - distance) * 0.5
                a.x = min(max(a.x + dx / distance * push, -half_w), half_w)
                a.z = min(max(a.z + dz / distance * push, -half_d), half_d)


def playtest(world: dict, runs: int = 5) -> dict:
    """Play it several times and report what is wrong, worst first."""
    matches = [simulate(world, seed) for seed in range(runs)]
    bugs: list[dict] = []

    def bug(severity, kind, evidence, fix):
        bugs.append({"severity": severity, "kind": kind,
                     "evidence": evidence, "fix": fix})

    # Does it end at all?
    stalled = [m for m in matches if not m.ended]
    if stalled:
        bug("high", "no_resolution",
            f"{len(stalled)} of {runs} matches never ended inside {MAX_SECONDS}s.",
            "Someone must be able to win: raise damage, lower hp, or stop both "
            "sides sitting outside each other's range.")

    finished = [m for m in matches if m.ended]
    lengths = [m.seconds for m in finished]
    if lengths:
        average = sum(lengths) / len(lengths)
        if average < 8:
            bug("high", "too_fast",
                f"Matches end in {average:.1f}s on average — over before it is watchable.",
                "Raise hp or cut damage so a fight lasts 20-60s.")
        elif average > 110:
            bug("med", "too_slow",
                f"Matches drag on for {average:.0f}s on average.",
                "Raise damage or speed so it resolves inside about a minute.")

    # Is it a walkover?
    winners = [m.winner for m in finished if m.winner]
    if winners:
        top = max(set(winners), key=winners.count)
        share = winners.count(top) / len(winners)
        if share >= 0.9 and len(finished) >= 3:
            losses = [sum(c for t, c in m.survivors.items() if t == top) for m in finished]
            bug("high", "one_sided",
                f"{top} wins {winners.count(top)}/{len(finished)} with "
                f"{sum(losses)/len(losses):.1f} survivors on average.",
                "Even the sides up: adjust hp, damage, range or numbers on the "
                "weaker team until both can win.")

    # Did anyone just stand there?
    sample = matches[0]
    idle = [u for u in sample.units
            if u.fighter and u.attacks == 0 and u.distance_moved < 0.01]
    if idle:
        bug("high", "never_engaged",
            "Never moved or attacked: " + ", ".join(u.name for u in idle[:4]),
            "Give them a speed above 0, a range that can reach, or place them "
            "where an enemy will come to them.")

    useless = [u for u in sample.units
               if u.fighter and u.attacks == 0 and u not in idle]
    if useless:
        bug("med", "never_landed_a_hit",
            "Moved but never attacked: " + ", ".join(u.name for u in useless[:4]),
            "Their range is too short for their speed, or they die before "
            "arriving. Extend range or toughen them.")

    # Is anything a one-shot?
    for attacker in sample.units:
        if not attacker.fighter:
            continue
        victims = [u for u in sample.units
                   if u.team not in (attacker.team, "neutral") and u.max_hp <= attacker.damage]
        if victims and attacker.damage > 0:
            bug("med", "one_shot",
                f"{attacker.name} ({attacker.damage} damage) one-shots "
                f"{len(victims)} enemies, e.g. {victims[0].name} ({victims[0].max_hp} hp).",
                "Cut that damage or raise their hp so a fight takes more than "
                "one exchange.")
            break

    # Did half the cast matter?
    contributors = [u for u in sample.units if u.damage_dealt > 0]
    fighters = [u for u in sample.units if u.fighter]
    if fighters and len(contributors) < len(fighters) * 0.5:
        bug("med", "spectators",
            f"Only {len(contributors)} of {len(fighters)} fighters dealt any damage.",
            "Move the idle ones closer to the action or give them reach.")

    order = {"high": 0, "med": 1, "low": 2}
    bugs.sort(key=lambda b: order.get(b["severity"], 3))

    return {
        "runs": runs,
        "resolved": len(finished),
        "avg_seconds": round(sum(lengths) / len(lengths), 1) if lengths else None,
        "winners": {w: winners.count(w) for w in set(winners)} if winners else {},
        "bugs": bugs,
        "playable": not any(b["severity"] == "high" for b in bugs),
        "top_damage": sorted(
            [{"name": u.name, "team": u.team, "damage": round(u.damage_dealt, 1),
              "attacks": u.attacks, "moved_m": round(u.distance_moved, 3)}
             for u in sample.units if u.fighter],
            key=lambda r: -r["damage"])[:8],
    }
