// The savanna itself: height field, the path, and where trees, shrubs and rocks stand.
import Foundation
import simd

@inline(__always) private func hash2(_ x: Int32, _ y: Int32) -> Float {
    var h = UInt32(bitPattern: x) &* 374_761_393 &+ UInt32(bitPattern: y) &* 668_265_263
    h = (h ^ (h >> 13)) &* 1_274_126_177
    h ^= h >> 16
    return Float(h & 0xFFFFFF) / Float(0x1000000)
}

func vnoise(_ x: Float, _ y: Float) -> Float {
    let xf = x.rounded(.down), yf = y.rounded(.down)
    let xi = Int32(xf), yi = Int32(yf)
    let fx = x - xf, fy = y - yf
    let ux = fx * fx * fx * (fx * (fx * 6 - 15) + 10)
    let uy = fy * fy * fy * (fy * (fy * 6 - 15) + 10)
    let a = hash2(xi, yi), b = hash2(xi + 1, yi), c = hash2(xi, yi + 1), d = hash2(xi + 1, yi + 1)
    return (a + (b - a) * ux) + ((c + (d - c) * ux) - (a + (b - a) * ux)) * uy
}

func fbm(_ x: Float, _ y: Float, _ octaves: Int) -> Float {
    var amp: Float = 0.5, sum: Float = 0, norm: Float = 0, px = x, py = y
    for _ in 0..<octaves {
        sum += amp * vnoise(px, py)
        norm += amp
        px = px * 2.03 + 17.1
        py = py * 2.03 + 9.2
        amp *= 0.5
    }
    return sum / norm
}

func ridged(_ x: Float, _ y: Float, _ octaves: Int) -> Float {
    var amp: Float = 0.5, sum: Float = 0, norm: Float = 0, px = x, py = y
    for _ in 0..<octaves {
        let r = 1 - abs(2 * vnoise(px, py) - 1)
        sum += amp * r * r
        norm += amp
        px = px * 2.03 + 17.1
        py = py * 2.03 + 9.2
        amp *= 0.5
    }
    return sum / norm
}

// The path formula is duplicated in Shaders.metal (pathMask).
func pathX(_ z: Float) -> Float { 60 * sin(z / 180) + 25 * sin(z / 67 + 1.3) }

func pathDistance(_ x: Float, _ z: Float) -> Float {
    let slope = (60.0 / 180.0) * cos(z / 180) + (25.0 / 67.0) * cos(z / 67 + 1.3)
    return abs(x - pathX(z)) / (1 + slope * slope).squareRoot()
}

struct Instance {
    var pos: V3
    var scale: Float
    var yaw: Float
    var seed: Float
    var mesh: Int
    var boundRadius: Float
    var maxDistance: Float
    var anim = V4()   // people only: two frames of the pose table, the blend between them, skin lightening
    var look = V4()   // people only: the head joint in the figure's own space, and how far the head is turned
}

final class World {
    static let half: Float = 1024
    static let spacing: Float = 2
    static let n = 1025
    static let walkLimit: Float = 960
    // 0-2 acacia, 3-4 shrub, 5-6 rock, 7 lighthouse, 8 the stage's buildings, 9 market stall
    static let meshCount = 10

    let stage: Stage
    let index: Int
    let real: RealTerrain?   // baked elevation and imagery, when this stage has been downloaded
    // Real stages are drawn relative to the elevation of their origin, so sea level sits this far below (or at) y = 0.
    private(set) var seaLevel: Float = 0
    private(set) var mask: [UInt8]?          // OSMData.mask(), when the stage has map data
    private(set) var buildings: MeshData?
    private var osm: OSMData?
    private(set) var spawn = V2()            // where the walker enters the stage
    private(set) var trader = V2()           // the stall where they can trade
    private(set) var exit = V2()             // where the way on to the next stop leaves the stage
    private var satMedian: Float = 0.1   // typical brightness of this stage's land in the imagery
    static var dataDirectory: String { (Bundle.main.resourcePath ?? ".") + "/stages" }
    private(set) var heights: [Float] = []
    private(set) var instances: [Instance] = []
    private(set) var colliders: [V3] = []   // x, z, radius
    private(set) var footprints = Footprints()   // walls the walker cannot pass
    private(set) var people: [Person] = []
    private var clock: Float = 0
    private(set) var levelled: Float = 0   // the most the ground was lowered under buildings, in metres
    private var paths: [(points: [V2], cum: [Float], offset: Float)] = []   // mapped roads people walk along

    init(stageIndex: Int) {
        index = min(max(stageIndex, 0), Route.stages.count - 1)
        stage = Route.stages[index]
        real = RealTerrain.load(dir: World.dataDirectory, index: index)
        if let real = real { seaLevel = -max(real.inner[(Geo.innerN / 2) * Geo.innerN + Geo.innerN / 2], 0) }
        let n = World.n
        var h = [Float](repeating: 0, count: n * n)
        h.withUnsafeMutableBufferPointer { buf in
            let base = buf.baseAddress!
            DispatchQueue.concurrentPerform(iterations: n) { j in
                let z = -World.half + Float(j) * World.spacing
                for i in 0..<n {
                    base[j * n + i] = self.terrain(-World.half + Float(i) * World.spacing, z)
                }
            }
        }
        heights = h
        if let real = real {
            var lum: [Float] = []
            for z in stride(from: -World.half + 8, to: World.half, by: 16) {
                for x in stride(from: -World.half + 8, to: World.half, by: 16) where !World.isWater(real.nearRGBA, x, z, half: World.half) {
                    lum.append(simd_dot(World.pixel(real.nearRGBA, x, z, half: World.half), V3(0.3, 0.6, 0.1)))
                }
            }
            lum.sort()
            if !lum.isEmpty { satMedian = max(lum[lum.count / 2], 0.01) }
        }
        if real != nil, let osm = OSMData.load(path: RealTerrain.path(World.dataDirectory, index, "_osm.json"), stage: stage) {
            self.osm = osm
            var px = osm.mask()
            // Second opinion on mapped water: seasonal lakes and pans are often mapped as water. Keep it
            // only where the imagery also looks wet, meaning water-coloured or darker than the stage's usual ground.
            if let real = real {
                let s = Geo.imageSize
                for j in 0..<s {
                    for i in 0..<s where px[(j * s + i) * 4 + 2] > 0 {
                        let x = (Float(i) + 0.5) / Float(s) * 2 * World.half - World.half, z = (Float(j) + 0.5) / Float(s) * 2 * World.half - World.half
                        let lum = simd_dot(World.pixel(real.nearRGBA, x, z, half: World.half), V3(0.3, 0.6, 0.1))
                        if !World.isWater(real.nearRGBA, x, z, half: World.half) && lum > satMedian * 0.9 { px[(j * s + i) * 4 + 2] = 0 }
                    }
                }
            }
            // Built-up ground: outside the footprints, alpha carries how much of the 64 m around a spot is
            // building or paved road, so that town centres and swept village yards are not sown with grass.
            // Footprints themselves stay at 255.
            let s = Geo.imageSize, w = s + 1, r = 32
            var sum = [Int32](repeating: 0, count: w * w)
            for j in 0..<s {
                var row: Int32 = 0
                for i in 0..<s {
                    let o = (j * s + i) * 4
                    row += px[o + 3] > 127 || px[o] > 127 ? 1 : 0
                    sum[(j + 1) * w + i + 1] = sum[j * w + i + 1] + row
                }
            }
            for j in 0..<s {
                for i in 0..<s where px[(j * s + i) * 4 + 3] < 128 {
                    let i0 = max(i - r, 0), i1 = min(i + r + 1, s), j0 = max(j - r, 0), j1 = min(j + r + 1, s)
                    let built = Float(sum[j1 * w + i1] - sum[j0 * w + i1] - sum[j1 * w + i0] + sum[j0 * w + i0]) / Float((i1 - i0) * (j1 - j0))
                    px[(j * s + i) * 4 + 3] = UInt8(smoothstep(0.025, 0.12, built) * 200)
                }
            }
            mask = px
            levelBuiltGround(osm.roughHeights(stage: stage, index: index))
        }
        placePeople()
        populate()
        placeCrowd()
    }

    // The walker starts at the named spot, or the nearest open dry ground to it; the trader's stall
    // stands a few paces away on the next clear patch.
    private func placePeople() {
        func open(_ p: V2) -> Bool { height(p.x, p.y) > seaLevel + 1 && isClear(p.x, p.y) && normal(p.x, p.y).y > 0.9 }
        func nearest(to c: V2, from first: Int, accept: (V2) -> Bool) -> V2 {
            for ring in first..<260 {
                let n = max(1, ring * 6)
                for k in 0..<n {
                    let a = Float(k) / Float(n) * 2 * .pi
                    let q = c + V2(sin(a), cos(a)) * Float(ring) * 3
                    if accept(q) { return q }
                }
            }
            return c
        }
        if real != nil {
            spawn = nearest(to: V2(), from: 0, accept: open)
        } else {
            spawn = V2(pathX(-900), -900)
        }
        trader = nearest(to: spawn, from: 4) { q in
            self.real != nil ? open(q) : pathDistance(q.x, q.y) > 3 && pathDistance(q.x, q.y) < 8 && q.y > self.spawn.y
        }
        // The way on: where a mapped road leaves the stage closest to the true bearing of the next stop,
        // or the edge of the stage on that bearing when no road heads that way.
        if real == nil {
            exit = V2(pathX(930), 930)
        } else if index + 1 < Route.stages.count {
            let dir = Route.direction(from: stage, to: Route.stages[index + 1])
            exit = dir * (930 / max(abs(dir.x), abs(dir.y)))
            var best: Float = 0.6
            for road in osm?.roads ?? [] {
                for p in road.points where max(abs(p.x), abs(p.y)) > 840 && max(abs(p.x), abs(p.y)) < 990 {
                    let score = simd_dot(simd_normalize(p), dir)
                    if score > best {
                        best = score
                        exit = p
                    }
                }
            }
        } else {
            exit = spawn
        }
        let toWalker = spawn - trader
        instances.append(Instance(pos: V3(trader.x, height(trader.x, trader.y), trader.y), scale: 1, yaw: atan2(toWalker.x, toWalker.y),
                                  seed: 0, mesh: 9, boundRadius: 4, maxDistance: 900))
        colliders.append(V3(trader.x, trader.y, 0.45))
        let front = simd_normalize(toWalker + V2(0, 1e-4))
        colliders.append(V3(trader.x + front.x * 0.9, trader.y + front.y * 0.9, 0.75))
    }

    // Radar elevation is of whatever the beam bounced off, so a dense city reads as a hill as high as its
    // buildings. Under built-up ground the terrain is taken down to the level of the open ground around it: a
    // morphological opening, which leaves slopes alone, and any rise more than 400 m across. It is never lowered
    // by more than the buildings standing there could account for, so real ridges under low houses stay.
    private func levelBuiltGround(_ built: [(centre: V2, reach: Float, height: Float)]) {
        let n = World.n, step = 4, m = (n - 1) / step + 1, r = 25   // 8 m cells, 200 m reach
        var tallest = [Float](repeating: 0, count: m * m)
        for b in built {
            let reach = b.reach + 40, cell = World.spacing * Float(step)
            let i0 = max(Int((b.centre.x - reach + World.half) / cell), 0), i1 = min(Int((b.centre.x + reach + World.half) / cell), m - 1)
            let j0 = max(Int((b.centre.y - reach + World.half) / cell), 0), j1 = min(Int((b.centre.y + reach + World.half) / cell), m - 1)
            if i0 > i1 || j0 > j1 { continue }
            for j in j0...j1 { for i in i0...i1 { tallest[j * m + i] = max(tallest[j * m + i], b.height) } }
        }
        var low = [Float](repeating: 0, count: m * m)
        for j in 0..<m { for i in 0..<m { low[j * m + i] = heights[j * step * n + i * step] } }
        func sweep(_ src: [Float], _ pick: (Float, Float) -> Float) -> [Float] {
            var rows = src, out = src
            for j in 0..<m {
                for i in 0..<m {
                    var v = src[j * m + i]
                    for k in max(i - r, 0)...min(i + r, m - 1) { v = pick(v, src[j * m + k]) }
                    rows[j * m + i] = v
                }
            }
            for j in 0..<m {
                for i in 0..<m {
                    var v = rows[j * m + i]
                    for k in max(j - r, 0)...min(j + r, m - 1) { v = pick(v, rows[k * m + i]) }
                    out[j * m + i] = v
                }
            }
            return out
        }
        let opened = sweep(sweep(low, min), max)
        for j in 0..<n {
            for i in 0..<n {
                let x = -World.half + Float(i) * World.spacing, z = -World.half + Float(j) * World.spacing
                let weight = urban(x, z) * smoothstep(0, 150, World.half - max(abs(x), abs(z)))
                if weight <= 0 { continue }
                let fi = Float(i) / Float(step), fj = Float(j) / Float(step)
                let a = min(Int(fi), m - 2), b = min(Int(fj), m - 2)
                let tx = fi - Float(a), tz = fj - Float(b)
                func d(_ p: Int, _ q: Int) -> Float { max(opened[q * m + p] - low[q * m + p], -0.8 * tallest[q * m + p]) }
                let delta = (d(a, b) * (1 - tx) + d(a + 1, b) * tx) * (1 - tz) + (d(a, b + 1) * (1 - tx) + d(a + 1, b + 1) * tx) * tz
                heights[j * n + i] += delta * weight
                levelled = max(levelled, -delta * weight)
            }
        }
    }

    // The trader behind the stall, a couple of customers, people standing by buildings near the walker's
    // way in, and others walking the mapped roads. A park has a handful; a city centre has dozens.
    private func placeCrowd() {
        var rng = RNG(977 + UInt64(index) * 53)
        let look = Locals.mix(stage, index: index)
        // Amboseli is Maasai country, and its people greet in Maa.
        let names = index == 11 ? (men: ["Lemayian", "Saitoti", "Parsaloi", "Sankau"], women: ["Naserian", "Nashipae", "Nasieku", "Naipanoi"])
                                : Locals.names[stage.country] ?? (["A man"], ["A woman"])
        let cast = Cast.shared?.avatars ?? []
        if cast.isEmpty { return }
        func person(at p: V2, yaw: Float, women: Bool? = nil, name: String? = nil) -> Person {
            // Draw from the cast by how common each figure is here; the trader's sex is given.
            // Amboseli is Maasai country; a few Maasai are about at Seronera too.
            func share(_ m: CastMember) -> Float {
                if m.maasai { return index == 11 ? 6 : (index == 10 ? 0.6 : 0) }
                return m.share[look.region] * (index == 11 ? 0.08 : 1)
            }
            let open = cast.indices.filter { (women == nil || cast[$0].member.female == women) && share(cast[$0].member) > 0 }
            var r = rng.next() * open.reduce(0) { $0 + share(cast[$1].member) }
            var pick = open[0]
            for i in open {
                pick = i
                r -= share(cast[i].member)
                if r < 0 { break }
            }
            let member = cast[pick].member
            let list = member.female ? names.women : names.men
            // Skin for this stop, held within reach of how the figure was modelled: features do not change with the tone.
            let wanted = look.skin.0 + look.skin.1 * rng.next()
            let skin = min(max(wanted, member.tone - 0.6), member.tone + 0.12)
            return Person(pos: p, yaw: yaw, avatar: pick, female: member.female, scale: rng.range(0.95, 1.03), seed: rng.next(),
                          skin: skin, name: name ?? list[Int(rng.next() * Float(list.count)) % list.count], homeYaw: yaw)
        }
        func standable(_ p: V2) -> Bool {
            max(abs(p.x), abs(p.y)) < World.walkLimit && height(p.x, p.y) > seaLevel + 0.5 && mapped(p.x, p.y, 2) < 0.1 && !footprints.contains(p)
        }

        let toWalker = simd_normalize(spawn - trader + V2(0, 1e-4))
        let stallYaw = atan2(toWalker.x, toWalker.y)
        let traderName = Economy.trader(at: index)
        people.append(person(at: trader, yaw: stallYaw, women: ["Thandi", "Mwila", "Neema", "Wanjiru", "Naserian", "Amira"].contains(traderName), name: traderName))
        let across = V2(toWalker.y, -toWalker.x)
        for side in [-0.55, 0.7] as [Float] {
            let p = trader + toWalker * 2.1 + across * side
            if standable(p) { people.append(person(at: p, yaw: stallYaw + .pi + side * 0.3)) }
        }

        let count = osm?.buildings.count ?? 0
        if let osm = osm {
            var wanted = min(24, 2 + count / 50)
            for b in osm.buildings where wanted > 0 {
                let c = b.ring.reduce(V2(), +) / Float(b.ring.count)
                if simd_distance(c, spawn) > 450 || b.ring.count < 4 || rng.next() > 0.3 { continue }
                let k = Int(rng.next() * Float(b.ring.count - 1))
                let a = b.ring[k], e = b.ring[k + 1]
                if simd_distance(a, e) < 2 { continue }
                var out = simd_normalize(V2(e.y - a.y, a.x - e.x))
                if simd_dot(out, (a + e) / 2 - c) < 0 { out = -out }
                let p = (a + e) / 2 + out * rng.range(0.8, 1.6)
                if !standable(p) { continue }
                var one = person(at: p, yaw: atan2(out.x, out.y) + rng.range(-0.7, 0.7))
                // Some stand in pairs, talking, each waiting their turn.
                let facing = V2(sin(one.yaw), cos(one.yaw)), q = p + facing * rng.range(0.95, 1.25)
                if rng.next() < 0.45 && standable(q) {
                    var other = person(at: q, yaw: one.yaw + .pi + rng.range(-0.25, 0.25))
                    one.chat = rng.range(0, 6.28)
                    other.chat = one.chat! + .pi
                    people.append(other)
                }
                people.append(one)
                wanted -= 1
            }
            for r in osm.roads where r.points.count >= 2 {
                var cum: [Float] = [0]
                for k in 1..<r.points.count { cum.append(cum[k - 1] + simd_distance(r.points[k], r.points[k - 1])) }
                if cum.last! > 60 { paths.append((r.points, cum, r.width < 2.5 ? 0.3 : (r.paved ? r.width / 2 + 0.7 : r.width / 2 - 0.5))) }
            }
        }
        var walkers = paths.isEmpty ? 0 : min(40, 3 + count / 40)
        var tries = 0
        while walkers > 0 && tries < 4000 {
            tries += 1
            let k = Int(rng.next() * Float(paths.count)) % paths.count
            let path = paths[k]
            let j = Int(rng.next() * Float(path.points.count)) % path.points.count
            let p = path.points[j]
            // Most walkers are put where the walker will see them; the rest anywhere on the stage.
            if !standable(p) || (simd_distance(p, spawn) > 350 && tries < 3000) { continue }
            var w = person(at: p, yaw: 0)
            w.path = k
            w.along = path.cum[j]
            w.heading = rng.next() < 0.5 ? 1 : -1
            w.stroll = rng.next() < 0.4
            w.speed = rng.range(0.92, 1.18)   // times the pace the walk was recorded at
            w.phase = rng.next()
            people.append(w)
            walkers -= 1
        }
        update(dt: 0.001, walker: V2(1e6, 1e6))
    }

    // Development aid (`--lineup`): eleven of the cast side by side at the spawn point, every other one walking on the spot.
    func lineUp(tone: Float?, row: Int, turned: Bool = false) {
        guard let cast = Cast.shared?.avatars else { return }
        people = cast.indices.filter { $0 / 11 == row }.map { i in
            var p = Person(pos: spawn + V2(Float(i % 11) * 0.95 - 4.75, 0), yaw: 0, avatar: i, female: cast[i].member.female, scale: 1,
                           seed: Float(i) / Float(cast.count), skin: tone ?? cast[i].member.tone, name: cast[i].member.name)
            p.walk = i % 2 == 1 ? 1 : 0
            p.phase = (Float(i) * 0.137).truncatingRemainder(dividingBy: 1)
            if turned { p.look = (Float(i % 11) - 5) * 0.2 }   // heads turned from full left to full right
            return p
        }
    }

    // Moves the people on. Anyone the walker comes up to stops, turns to face them and talks.
    func update(dt: Float, walker: V2) {
        clock += dt
        func turn(_ yaw: Float, towards want: Float, _ rate: Float) -> Float {
            var d = (want - yaw).truncatingRemainder(dividingBy: 2 * .pi)
            if d > .pi { d -= 2 * .pi }
            if d < -.pi { d += 2 * .pi }
            return yaw + d * min(1, rate)
        }
        let cast = Cast.shared?.avatars ?? []
        let before = people
        for i in people.indices {
            var p = people[i]
            let toWalker = walker - p.pos
            let met = simd_length(toWalker) < 2.6
            var target: Float = 0
            var blocked = false
            if met {
                p.yaw = turn(p.yaw, towards: atan2(toWalker.x, toWalker.y), dt * 5)
            } else if p.path >= 0 {
                target = p.met < 0.05 ? 1 : 0   // finish the conversation before setting off again
                let path = paths[p.path]
                // Each walk covers a set distance per cycle, so the feet stay planted whatever the pace.
                let clip = cast[p.avatar].clips[(p.stroll ? Cast.Clip.stroll : .walk).rawValue]
                let stride = max(clip.distance * p.scale, 0.3)
                let step = stride / (Float(clip.frames) / clip.rate) * p.speed * p.walk * dt
                p.along += p.heading * step
                if p.along <= 0 || p.along >= path.cum.last! {
                    p.heading = -p.heading
                    p.along = min(max(p.along, 0), path.cum.last!)
                }
                var k = 0
                while k + 2 < path.cum.count && path.cum[k + 1] < p.along { k += 1 }
                let a = path.points[k], b = path.points[k + 1]
                let d = simd_normalize(b - a + V2(0, 1e-5)) * p.heading
                let q = a + (b - a) * ((p.along - path.cum[k]) / max(path.cum[k + 1] - path.cum[k], 1e-3)) + V2(-d.y, d.x) * (path.offset + p.aside)
                // Step out around anyone close ahead.
                for (j, o) in before.enumerated() where j != i {
                    let v = o.pos - p.pos
                    let ahead = simd_dot(v, d)
                    if ahead > 0.05 && ahead < 1.7 && abs(v.x * d.y - v.y * d.x) < 0.62 { blocked = true; break }
                }
                if max(abs(q.x), abs(q.y)) > World.walkLimit - 10 && simd_dot(d, q) > 0 { p.heading = -p.heading }
                p.pos = q
                p.yaw = turn(p.yaw, towards: atan2(d.x, d.y), dt * 5)
                p.phase = (p.phase + step / stride).truncatingRemainder(dividingBy: 1)
            } else {
                p.yaw = turn(p.yaw, towards: p.homeYaw, dt * 2)
            }
            p.walk += (target - p.walk) * min(1, dt * 4)
            p.aside += ((blocked ? 1.1 : 0) - p.aside) * min(1, dt * 1.6)
            // Heads turn to whoever comes near, as far as a neck allows; past that people look ahead again.
            var glance: Float = 0
            let near = simd_length(toWalker)
            if near < 9 && near > 0.3 {
                var rel = (atan2(toWalker.x, toWalker.y) - p.yaw).truncatingRemainder(dividingBy: 2 * .pi)
                if rel > .pi { rel -= 2 * .pi }
                if rel < -.pi { rel += 2 * .pi }
                if abs(rel) < 1.9 { glance = min(max(rel, -1.0), 1.0) * (near < 6 ? 1 : (9 - near) / 3) }
            }
            p.look += (glance - p.look) * min(1, dt * 3.5)
            p.met += ((met && p.walk < 0.08 ? 1 : 0) - p.met) * min(1, dt * 3)
            people[i] = p
        }
    }

    // Each person's place in the pose table: mid-stride, or standing idle, or talking, and part-way between when they change.
    var peopleInstances: [Instance] {
        guard let cast = Cast.shared?.avatars else { return [] }
        return people.map { p in
            let clips = cast[p.avatar].clips
            func frame(_ c: Cast.Clip, at seconds: Float) -> Float {
                let clip = clips[c.rawValue]
                return Float(clip.start) + (seconds * clip.rate).truncatingRemainder(dividingBy: Float(clip.frames))
            }
            let walk = clips[(p.stroll ? Cast.Clip.stroll : .walk).rawValue]
            let striding = Float(walk.start) + p.phase * Float(walk.frames) * 0.9999
            let own = clock + p.seed * 40
            let idle = frame(p.seed < 0.5 ? .idle : .idleTwo, at: own)
            // Two poses can be mixed at once: idle into a stride while they walk, idle into talk once they have stopped.
            let second = p.walk > 0.08 ? striding : frame(.talk, at: own)
            let lighten = Cast.reflectance(p.skin) / Cast.reflectance(cast[p.avatar].member.tone)
            // Two people talking take turns: one gestures while the other stands and listens.
            var talking = p.met
            if let turn = p.chat { talking = max(talking, 0.1 + 0.8 * simd_smoothstep(-0.35, 0.35, sin(clock * 0.45 + turn))) }
            let anim = V4(idle, second, p.walk > 0.08 ? p.walk : talking, lighten)
            return Instance(pos: V3(p.pos.x, height(p.pos.x, p.pos.y), p.pos.y), scale: p.scale, yaw: p.yaw, seed: p.seed,
                            mesh: p.avatar, boundRadius: 2, maxDistance: 700, anim: anim,
                            look: V4(Cast.shared!.headPivot(p.avatar, anim: anim), p.look))
        }
    }

    // The nearest person within reach, and what they have to say: a greeting in the local language and the way on.
    func greeting(near walker: V2) -> String? {
        guard let p = people.filter({ simd_distance($0.pos, walker) < 3.5 }).min(by: { simd_distance($0.pos, walker) < simd_distance($1.pos, walker) }) else { return nil }
        let g = Locals.greetings[index]
        var text = "\(p.name): “\(g.0)” (\(g.1): \(g.2))."
        if index + 1 < Route.stages.count {
            text += String(format: " The road to %@ leaves to the %@, about %.0f m from here.", Route.stages[index + 1].name.components(separatedBy: ",")[0],
                           Locals.compass(exit - walker), simd_distance(exit, walker))
        }
        if simd_distance(p.pos, trader) > 8 {
            text += String(format: " %@ trades %.0f m to the %@.", Economy.trader(at: index), simd_distance(trader, walker), Locals.compass(trader - walker))
        }
        return text
    }

    // Metres this spot stands above the ground 60 m around it: outcrops and hilltops score high.
    private func prominence(_ x: Float, _ z: Float) -> Float {
        var around: Float = 0
        for k in 0..<8 {
            let a = Float(k) / 8 * 2 * .pi
            around += height(x + cos(a) * 60, z + sin(a) * 60)
        }
        return height(x, z) - around / 8
    }

    private func kopjeMask(_ x: Float, _ z: Float) -> Float {
        let o = Float(index) * 913
        return smoothstep(0.68, 0.84, vnoise((x + o) * 0.0035 + 100, (z - o) * 0.0035 + 100)) * smoothstep(25, 90, pathDistance(x, z))
    }

    // Ground height from the stage's landscape; each stage samples its own region of the noise.
    func terrain(_ x: Float, _ z: Float) -> Float {
        if let real = real { return realTerrain(real, x, z) }
        let b = stage.biome
        let o = Float(index) * 913
        let ox = x + o, oz = z - o * 0.7
        var h = (fbm(ox * 0.0011, oz * 0.0011, 4) - 0.5) * 60 * b.relief
        h += (fbm(ox * 0.009 + 50, oz * 0.009, 3) - 0.5) * 5 * min(b.relief, 1.5)
        h += (vnoise(ox * 0.06, oz * 0.06) - 0.5) * 0.35

        let kop = kopjeMask(x, z) * b.kopjes
        if kop > 0 { h += kop * (14 + 22 * ridged(ox * 0.018, oz * 0.018, 3)) }
        if b.dunes > 0 {
            let crest = ridged(ox * 0.007 + 0.6 * sin(oz * 0.003), oz * 0.0022, 2)
            h += b.dunes * crest * 16 * smoothstep(4, 40, pathDistance(x, z))
        }

        // Distant ranges, with gaps so the plain stays open.
        let r = (x * x + z * z).squareRoot()
        let m = smoothstep(2200, 9000, r) * smoothstep(0.35, 0.6, fbm(ox * 0.00008 + 3, oz * 0.00008, 2)) * b.mountains
        if m > 0 { h += m * ridged(ox * 0.00022, oz * 0.00022, 5) * 1500 }

        // Kilimanjaro, as seen from Amboseli.
        if stage.volcano {
            let dx = x + 2500, dz = z - 11200
            let cone = max(0, 1 - (dx * dx + dz * dz).squareRoot() / 4600)
            if cone > 0 { h += min(pow(cone, 1.5) * 3400, 2650 + 60 * vnoise(x * 0.002, z * 0.002)) }
        }
        return h
    }

    // Measured elevation: smooth interpolation of the 8 m posts inside the walkable square, the 125 m
    // posts beyond it, and a little invented roughness on dry land that the data is too coarse to hold.
    private func realTerrain(_ real: RealTerrain, _ x: Float, _ z: Float) -> Float {
        func outer() -> Float {
            let n = Geo.outerN
            let fx = min(max((x + Geo.farHalf) / Geo.outerSpacing, 0), Float(n - 1) - 0.001)
            let fz = min(max((z + Geo.farHalf) / Geo.outerSpacing, 0), Float(n - 1) - 0.001)
            let i = Int(fx), j = Int(fz)
            let tx = fx - Float(i), tz = fz - Float(j)
            let a = real.outer[j * n + i], b = real.outer[j * n + i + 1]
            let c = real.outer[(j + 1) * n + i], d = real.outer[(j + 1) * n + i + 1]
            let h = (a + (b - a) * tx) * (1 - tz) + (c + (d - c) * tx) * tz
            // Coarse posts smear coastal hills out over the sea; where the imagery shows water, it is water.
            return h < 40 && World.isWater(real.farRGBA, x, z, half: Geo.farHalf) ? min(h, -1.5) : h
        }
        let edge = max(abs(x), abs(z))
        if edge >= World.half {
            func horizon() -> Float {
                let n = Geo.horizonN
                let fx = min(max((x + Geo.horizonHalf) / Geo.horizonSpacing, 0), Float(n - 1) - 0.001)
                let fz = min(max((z + Geo.horizonHalf) / Geo.horizonSpacing, 0), Float(n - 1) - 0.001)
                let i = Int(fx), j = Int(fz)
                let tx = fx - Float(i), tz = fz - Float(j)
                let a = real.horizon[j * n + i], b = real.horizon[j * n + i + 1]
                let c = real.horizon[(j + 1) * n + i], d = real.horizon[(j + 1) * n + i + 1]
                return (a + (b - a) * tx) * (1 - tz) + (c + (d - c) * tx) * tz
            }
            if edge >= Geo.farHalf { return World.shelve(horizon()) + seaLevel }
            let o = outer()
            return World.shelve(o + (horizon() - o) * smoothstep(Geo.farHalf - 1500, Geo.farHalf, edge)) + seaLevel
        }

        let n = Geo.innerN
        let fx = (x + World.half) / Geo.innerSpacing, fz = (z + World.half) / Geo.innerSpacing
        let i = Int(fx.rounded(.down)), j = Int(fz.rounded(.down))
        let tx = fx - Float(i), tz = fz - Float(j)
        func post(_ i: Int, _ j: Int) -> Float { real.inner[min(max(j, 0), n - 1) * n + min(max(i, 0), n - 1)] }
        func cubic(_ p0: Float, _ p1: Float, _ p2: Float, _ p3: Float, _ t: Float) -> Float {
            p1 + 0.5 * t * (p2 - p0 + t * (2 * p0 - 5 * p1 + 4 * p2 - p3 + t * (3 * (p1 - p2) + p3 - p0)))
        }
        var rows = [Float](repeating: 0, count: 4)
        for r in 0..<4 {
            rows[r] = cubic(post(i - 1, j - 1 + r), post(i, j - 1 + r), post(i + 1, j - 1 + r), post(i + 2, j - 1 + r), tx)
        }
        var h = cubic(rows[0], rows[1], rows[2], rows[3], tz)
        // Near sea level the 10 m imagery places the waterline better than the 30 m elevation does.
        if h < 3 && World.isWater(real.nearRGBA, x, z, half: World.half) { h = min(h, -1.5) }
        h += (fbm(x * 0.11, z * 0.11, 3) - 0.5) * 0.5 * smoothstep(0.3, 2.5, h)
        h += (outer() - h) * smoothstep(World.half - 120, World.half, edge)
        if h < 40 && World.isWater(real.nearRGBA, x, z, half: World.half) { h = min(h, -1.5) }
        return World.shelve(h) + seaLevel
    }

    // The open elevation data is flat at sea level over water; drop the seabed away from the shore so
    // the sea has depth and the waterline stays where the data puts it.
    private static func shelve(_ h: Float) -> Float {
        h - 6 * (1 - smoothstep(-1.0, 0.3, h))
    }

    private static func pixel(_ rgba: [UInt8], _ x: Float, _ z: Float, half: Float) -> V3 {
        let s = Geo.imageSize
        let i = min(max(Int((x + half) / (2 * half) * Float(s)), 0), s - 1)
        let j = min(max(Int((z + half) / (2 * half) * Float(s)), 0), s - 1)
        let o = (j * s + i) * 4
        let c = V3(Float(rgba[o]), Float(rgba[o + 1]), Float(rgba[o + 2])) / 255
        return c * c * (c * 0.305 + 0.695)   // sRGB to linear, near enough
    }

    private static func isWater(_ rgba: [UInt8], _ x: Float, _ z: Float, half: Float) -> Bool {
        let c = pixel(rgba, x, z, half: half)
        return c.z > c.x * 1.25 && c.y > c.x
    }

    // 0 to 1: how wooded the imagery shows this spot to be. Tree crowns and riverine bush read as
    // patches clearly darker than the stage's typical ground.
    func woodland(_ x: Float, _ z: Float) -> Float {
        guard let real = real, !World.isWater(real.nearRGBA, x, z, half: World.half) else { return 0 }
        let lum = simd_dot(World.pixel(real.nearRGBA, x, z, half: World.half), V3(0.3, 0.6, 0.1))
        return 1 - smoothstep(0.6, 0.92, lum / satMedian)
    }

    // 0 to 1: how vegetated the satellite image shows this spot to be (dark and not water).
    func vegetation(_ x: Float, _ z: Float) -> Float {
        guard let real = real else { return 1 }
        let lin = World.pixel(real.nearRGBA, x, z, half: World.half)
        if lin.z > lin.x * 1.25 { return 0 }
        let bare = stage.biome.bareAbove
        return 1 - smoothstep(bare * 0.36, bare, simd_dot(lin, V3(0.3, 0.6, 0.1)) * 0.9)
    }

    func height(_ x: Float, _ z: Float) -> Float {
        let n = World.n
        let fx = min(max((x + World.half) / World.spacing, 0), Float(n - 1) - 0.001)
        let fz = min(max((z + World.half) / World.spacing, 0), Float(n - 1) - 0.001)
        let i = Int(fx), j = Int(fz)
        let tx = fx - Float(i), tz = fz - Float(j)
        let a = heights[j * n + i], b = heights[j * n + i + 1]
        let c = heights[(j + 1) * n + i], d = heights[(j + 1) * n + i + 1]
        return (a + (b - a) * tx) * (1 - tz) + (c + (d - c) * tx) * tz
    }

    func normal(_ x: Float, _ z: Float) -> V3 {
        let e = World.spacing
        return normalize(V3(height(x - e, z) - height(x + e, z), 2 * e, height(x, z - e) - height(x, z + e)))
    }

    // Real structures at their surveyed positions.
    // 0 to 1 for one channel of the map mask at a spot: 0 paved road, 1 dirt road, 2 water, 3 building.
    func mapped(_ x: Float, _ z: Float, _ channel: Int) -> Float {
        guard let mask = mask else { return 0 }
        let s = Geo.imageSize
        let i = Int((x + World.half) / (2 * World.half) * Float(s)), j = Int((z + World.half) / (2 * World.half) * Float(s))
        if i < 0 || j < 0 || i >= s || j >= s { return 0 }
        return Float(mask[(j * s + i) * 4 + channel]) / 255
    }

    private func isClear(_ x: Float, _ z: Float) -> Bool {
        mapped(x, z, 0) + mapped(x, z, 1) + mapped(x, z, 2) < 0.1 && mapped(x, z, 3) < 0.9
    }

    // 0 to 1: how built-up the surroundings of a spot are.
    func urban(_ x: Float, _ z: Float) -> Float { min(mapped(x, z, 3) * 255 / 200, 1) }

    func describe(_ x: Float, _ z: Float) -> String {
        guard let real = real else { return "no real data" }
        let near = World.pixel(real.nearRGBA, x, z, half: World.half), far = World.pixel(real.farRGBA, x, z, half: Geo.farHalf)
        let n = Geo.outerN
        let i = Int((x + Geo.farHalf) / Geo.outerSpacing), j = Int((z + Geo.farHalf) / Geo.outerSpacing)
        return "terrain \(terrain(x, z)) · sea level \(seaLevel) · outer post \(real.outer[min(max(j, 0), n - 1) * n + min(max(i, 0), n - 1)])"
            + " · near colour \(near) water \(World.isWater(real.nearRGBA, x, z, half: World.half))"
            + " · far colour \(far) water \(World.isWater(real.farRGBA, x, z, half: Geo.farHalf))"
    }

    private func placeLandmarks() {
        if let osm = osm {
            let near = real?.nearRGBA
            let built = osm.buildingMesh(stage: stage, index: index, height: { self.height($0, $1) },
                                         imagery: { x, z in near.map { World.pixel($0, x, z, half: World.half) } ?? V3(repeating: 0.3) })
            if !built.mesh.indices.isEmpty {
                buildings = built.mesh
                footprints = Footprints(built.footprints)
                instances.append(Instance(pos: V3(), scale: 1, yaw: 0, seed: 0, mesh: 8, boundRadius: 3000, maxDistance: 20000))
            }
        }
        if index == 0, real != nil {
            // Cape Agulhas lighthouse (1849), 34°49′46″S 20°00′32″E.
            let p = Geo.metres(stage, lat: -34.8294, lon: 20.0089)
            instances.append(Instance(pos: V3(p.x, height(p.x, p.z), p.z), scale: 1, yaw: 0, seed: 0, mesh: 7,
                                      boundRadius: 34, maxDistance: 9000))
            colliders.append(V3(p.x, p.z, 7))
        }
    }

    private func populate() {
        placeLandmarks()
        var rng = RNG(7 + UInt64(index) * 31)
        let b = stage.biome
        let limit = World.half - 30
        var taken: [SIMD2<Int32>: [V2]] = [:]
        let cell: Float = 12

        func isFree(_ p: V2, _ minDist: Float) -> Bool {
            let cx = Int32((p.x / cell).rounded(.down)), cz = Int32((p.y / cell).rounded(.down))
            for dz in -1...1 {
                for dx in -1...1 {
                    for q in taken[SIMD2(cx + Int32(dx), cz + Int32(dz))] ?? [] where distance(p, q) < minDist {
                        return false
                    }
                }
            }
            return true
        }
        func take(_ p: V2) {
            taken[SIMD2(Int32((p.x / cell).rounded(.down)), Int32((p.y / cell).rounded(.down))), default: []].append(p)
        }

        // Acacias: sparse, in loose groves.
        for _ in 0..<(real == nil ? 6500 : 14000) {
            let p = V2(rng.range(-limit, limit), rng.range(-limit, limit))
            let density = fbm(p.x * 0.004 + 9, p.y * 0.004 + 2, 2)
            // Real stages put trees where the satellite shows them; invented ones scatter loose groves.
            let chance = real == nil ? smoothstep(0.38, 0.62, density) * 0.55 + 0.03 : woodland(p.x, p.y) * 0.7 + 0.004
            if rng.next() > chance * b.trees * (1 - 0.85 * urban(p.x, p.y)) { continue }
            if (real == nil && pathDistance(p.x, p.y) < 5) || normal(p.x, p.y).y < 0.95 || !isFree(p, 11) { continue }
            if real != nil && (height(p.x, p.y) < seaLevel + 1.5 || !isClear(p.x, p.y)) { continue }
            take(p)
            let scale = rng.range(0.9, 1.5)
            instances.append(Instance(pos: V3(p.x, height(p.x, p.y), p.y), scale: scale, yaw: rng.range(0, 2 * .pi),
                                      seed: rng.next(), mesh: Int(rng.range(0, 2.999)),
                                      boundRadius: 8 * scale, maxDistance: 3000))
            colliders.append(V3(p.x, p.y, 0.3 * scale))
        }

        // Shrubs.
        // Scrub country gets many small bushes; elsewhere fewer, larger ones.
        let scrub = b.shrubs > 2
        for _ in 0..<Int(5200 * max(1, b.shrubs * (scrub ? 4 : 1))) {
            let p = V2(rng.range(-limit, limit), rng.range(-limit, limit))
            let density = fbm(p.x * 0.01 + 40, p.y * 0.01 + 12, 2)
            if rng.next() > (smoothstep(0.35, 0.65, density) * 0.6 + 0.04) * min(b.shrubs, 1.5) { continue }
            if (real == nil && pathDistance(p.x, p.y) < 2.5) || normal(p.x, p.y).y < 0.93 || !isFree(p, scrub ? 1.4 : 3) { continue }
            if real != nil && (height(p.x, p.y) < seaLevel + 1.5 || rng.next() > vegetation(p.x, p.y) * (1 - urban(p.x, p.y)) || !isClear(p.x, p.y)) { continue }
            take(p)
            let scale = scrub ? rng.range(0.35, 0.95) : rng.range(0.7, 1.6)
            instances.append(Instance(pos: V3(p.x, height(p.x, p.y), p.y), scale: scale, yaw: rng.range(0, 2 * .pi),
                                      seed: rng.next(), mesh: 3 + Int(rng.range(0, 1.999)),
                                      boundRadius: 2 * scale, maxDistance: scrub ? 320 : 700))
        }

        // Riverine trees: a line of them along each mapped river and stream.
        if let osm = osm, b.trees > 0 {
            for river in osm.rivers {
                for k in 0..<river.points.count - 1 {
                    let a = river.points[k], c = river.points[k + 1]
                    let steps = max(1, Int(simd_distance(a, c) / 7))
                    for s in 0..<steps {
                        let side = (rng.next() < 0.5 ? -1 : 1) * (river.width / 2 + rng.range(2, 14))
                        let along = a + (c - a) * (Float(s) + rng.next()) / Float(steps)
                        let d = simd_normalize(c - a + V2(0.001, 0))
                        let p = along + V2(-d.y, d.x) * side
                        if max(abs(p.x), abs(p.y)) > limit || !isClear(p.x, p.y) || !isFree(p, 6) { continue }
                        take(p)
                        let scale = rng.range(0.9, 1.6)
                        instances.append(Instance(pos: V3(p.x, height(p.x, p.y), p.y), scale: scale, yaw: rng.range(0, 2 * .pi),
                                                  seed: rng.next(), mesh: Int(rng.range(0, 2.999)), boundRadius: 8 * scale, maxDistance: 3000))
                        colliders.append(V3(p.x, p.y, 0.3 * scale))
                    }
                }
            }
        }

        // A rocky shore: boulders and ledges crowd the band just above and below the waterline.
        if real != nil && seaLevel > -30 {
            for _ in 0..<120_000 {
                let p = V2(rng.range(-limit, limit), rng.range(-limit, limit))
                let h = height(p.x, p.y) - seaLevel
                if h < -0.6 || h > 2.6 || !isClear(p.x, p.y) { continue }
                let scale = rng.range(0.3, 1.9)
                if !isFree(p, scale * 1.1) { continue }
                take(p)
                instances.append(Instance(pos: V3(p.x, height(p.x, p.y) - 0.3 * scale, p.y), scale: scale,
                                          yaw: rng.range(0, 2 * .pi), seed: rng.next(), mesh: 5 + Int(rng.range(0, 1.999)),
                                          boundRadius: 1.3 * scale, maxDistance: 200 + 300 * scale))
                if scale > 0.9 { colliders.append(V3(p.x, p.y, 0.8 * scale)) }
            }
        }

        // Rocks: boulders piled on the kopjes, a few stones on the plain.
        for _ in 0..<9000 {
            let p = V2(rng.range(-limit, limit), rng.range(-limit, limit))
            // On real ground, boulders gather on the measured outcrops instead of an invented pattern.
            let kop = real != nil ? smoothstep(1.5, 5, prominence(p.x, p.y)) : kopjeMask(p.x, p.y)
            if rng.next() > kop * b.kopjes * 0.9 + 0.035 * b.rocks { continue }
            if real == nil && pathDistance(p.x, p.y) < 2 { continue }
            if real != nil && (height(p.x, p.y) < seaLevel - 0.5 || !isClear(p.x, p.y) || urban(p.x, p.y) > 0.3) { continue }
            let scale = kop > 0.2 ? rng.range(0.7, 3.4) : rng.range(0.25, 0.9)
            if !isFree(p, scale * 0.9) { continue }
            take(p)
            instances.append(Instance(pos: V3(p.x, height(p.x, p.y) - 0.22 * scale, p.y), scale: scale,
                                      yaw: rng.range(0, 2 * .pi), seed: rng.next(), mesh: 5 + Int(rng.range(0, 1.999)),
                                      boundRadius: 1.3 * scale, maxDistance: 250 + 450 * scale))
            if scale > 0.6 { colliders.append(V3(p.x, p.y, 0.8 * scale)) }
        }
    }
}
