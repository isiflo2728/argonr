//
//  WorldBattle.swift
//  argonr
//
//  The same rules the server plays by, so what the phone shows and what Argon
//  critiques are the same game. Pure value types and plain arithmetic.
//

import Foundation
import simd

struct WorldBattle {

    struct Unit: Identifiable {
        let id: Int
        let name: String
        let team: String
        let behaviour: World.Behaviour
        let maxHP: Float
        let damage: Float
        let range: Float
        let speed: Float

        var position: SIMD3<Float>
        var facing: Float = 0
        var hp: Float
        var cooldown: Float = 0

        var isAlive: Bool { hp > 0 }
        var isFighter: Bool { behaviour != .static && damage > 0 && team != "neutral" }
        var healthFraction: Float { maxHP > 0 ? max(0, hp / maxHP) : 1 }
    }

    private(set) var units: [Unit] = []
    private(set) var elapsed: Float = 0
    private(set) var isOver = false
    private(set) var winner: String?

    private let bounds: SIMD2<Float>
    private let attackInterval: Float = 0.6
    private let personalSpace: Float = 0.022

    init(world: World) {
        bounds = SIMD2(world.ground.width / 2, world.ground.depth / 2)
        for (index, entity) in world.entities.enumerated() {
            units.append(Unit(id: index, name: entity.name, team: entity.team,
                              behaviour: entity.behaviour,
                              maxHP: max(1, entity.hp), damage: max(0, entity.damage),
                              range: max(0.01, entity.range), speed: max(0, entity.speed),
                              position: entity.origin, hp: max(1, entity.hp)))
        }
    }

    mutating func step(_ dt: Float) {
        guard !isOver else { return }
        elapsed += dt

        for index in units.indices where units[index].isAlive {
            advance(index, dt: dt)
        }
        separate()

        let standing = Set(units.filter { $0.isAlive && $0.isFighter }.map(\.team))
        if standing.count <= 1 {
            isOver = true
            winner = standing.first
        }
    }

    private mutating func advance(_ index: Int, dt: Float) {
        var unit = units[index]
        guard unit.behaviour != .static else { return }
        unit.cooldown = max(0, unit.cooldown - dt)

        guard let targetIndex = nearestEnemy(of: unit) else { units[index] = unit; return }
        let target = units[targetIndex]
        let toTarget = target.position - unit.position
        let distance = simd_length(toTarget)
        guard distance > 0.0001 else { units[index] = unit; return }
        let direction = toTarget / distance
        unit.facing = atan2(direction.x, direction.z)

        let preferred: Float
        switch unit.behaviour {
        case .charge:   preferred = unit.range * 0.6
        case .hold:     preferred = distance
        case .skirmish: preferred = unit.healthFraction < 0.4 ? unit.range * 2.5 : unit.range * 0.7
        case .ranged:   preferred = unit.range * 0.85
        case .wander:   preferred = unit.range * 0.9
        case .static:   preferred = distance
        }

        let gap = distance - preferred
        if abs(gap) > 0.004, unit.speed > 0 {
            let step = min(unit.speed * dt, abs(gap))
            unit.position += direction * (gap > 0 ? step : -step)
            unit.position = clamped(unit.position)
        }

        if distance <= unit.range, unit.cooldown == 0, unit.isFighter {
            units[targetIndex].hp -= unit.damage
            unit.cooldown = attackInterval
        }
        units[index] = unit
    }

    private mutating func separate() {
        for a in units.indices where units[a].isAlive {
            guard units[a].behaviour != .static else { continue }
            for b in units.indices where b != a && units[b].isAlive {
                let delta = units[a].position - units[b].position
                let distance = simd_length(delta)
                guard distance > 0.0001, distance < personalSpace else { continue }
                let push = (personalSpace - distance) * 0.5
                units[a].position = clamped(units[a].position + (delta / distance) * push)
            }
        }
    }

    private func nearestEnemy(of unit: Unit) -> Int? {
        var best: Int?
        var bestDistance = Float.greatestFiniteMagnitude
        for (index, other) in units.enumerated()
        where other.isAlive && other.team != unit.team && other.team != "neutral" {
            let distance = simd_distance(other.position, unit.position)
            if distance < bestDistance { bestDistance = distance; best = index }
        }
        return best
    }

    private func clamped(_ p: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(min(max(p.x, -bounds.x), bounds.x), 0, min(max(p.z, -bounds.y), bounds.y))
    }

    var livingByTeam: [(team: String, count: Int)] {
        Dictionary(grouping: units.filter { $0.isAlive && $0.team != "neutral" }, by: \.team)
            .map { ($0.key, $0.value.count) }
            .sorted { $0.0 < $1.0 }
    }
}
