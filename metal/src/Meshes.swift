// Procedural geometry. Vertex layout: position(3) normal(3) uv(2) extra(4) — see MeshIn in Shaders.metal.
import Foundation
import simd

struct MeshData {
    static let stride = 12

    var vertices: [Float] = []
    var indices: [UInt32] = []

    var vertexCount: UInt32 { UInt32(vertices.count / MeshData.stride) }

    @discardableResult
    mutating func add(_ p: V3, _ n: V3, _ uv: V2, _ extra: V4) -> UInt32 {
        let i = vertexCount
        vertices.append(contentsOf: [p.x, p.y, p.z, n.x, n.y, n.z, uv.x, uv.y, extra.x, extra.y, extra.z, extra.w])
        return i
    }

    mutating func tube(_ a: V3, _ b: V3, _ ra: Float, _ rb: Float, sides: Int = 6, extra: V4 = V4(0, 0, 0, 0)) {
        let axis = normalize(b - a)
        let u = normalize(cross(axis, abs(axis.y) < 0.95 ? V3(0, 1, 0) : V3(1, 0, 0)))
        let v = cross(axis, u)
        let base = vertexCount
        for i in 0...sides {
            let ang = Float(i) / Float(sides) * 2 * .pi
            let dir = u * cos(ang) + v * sin(ang)
            let uvx = Float(i) / Float(sides)
            add(a + dir * ra, dir, V2(uvx, 0), extra)
            add(b + dir * rb, dir, V2(uvx, 1), extra)
        }
        for i in 0..<UInt32(sides) {
            let k = base + i * 2
            indices.append(contentsOf: [k, k + 1, k + 2, k + 2, k + 1, k + 3])
        }
    }

    mutating func card(center: V3, normal: V3, size: Float, shadeNormal: V3, seed: Float, spin: V3) {
        let t = normalize(cross(normal, abs(dot(normal, spin)) < 0.95 ? spin : V3(0.31, 0.2, 0.93)))
        let b = cross(normal, t)
        let h = size * 0.5
        let extra = V4(1, seed, 1, 0)
        let base = vertexCount
        add(center - t * h - b * h, shadeNormal, V2(0, 0), extra)
        add(center + t * h - b * h, shadeNormal, V2(1, 0), extra)
        add(center + t * h + b * h, shadeNormal, V2(1, 1), extra)
        add(center - t * h + b * h, shadeNormal, V2(0, 1), extra)
        indices.append(contentsOf: [base, base + 1, base + 2, base, base + 2, base + 3])
    }
}

// Umbrella thorn: short trunk, branches fanning out to a flat crown of leaf cards.
func makeAcacia(seed: UInt64) -> MeshData {
    var m = MeshData()
    var rng = RNG(seed)
    var tips: [V3] = []
    let lengths: [Float] = [0.7, 2.6, 2.0, 1.4]
    let radii: [Float] = [0.17, 0.12, 0.075, 0.045]
    let childElevation: [Float] = [0.70, 0.30, 0.10]

    func grow(_ start: V3, _ dir: V3, _ depth: Int) {
        let len = lengths[depth] * rng.range(0.8, 1.15)
        let rad = radii[depth]
        let mid = start + dir * (len * 0.5) + V3(rng.range(-1, 1), rng.range(-0.3, 0.6), rng.range(-1, 1)) * (len * 0.1)
        let end = start + dir * len
        m.tube(start - dir * (rad * 0.8), mid, rad, rad * 0.85)
        m.tube(mid, end, rad * 0.85, rad * 0.65)
        if depth == 3 {
            tips.append(mid)
            tips.append(end)
            return
        }
        let n = depth == 0 ? Int(rng.range(3, 4.99)) : (depth == 1 ? Int(rng.range(2, 3.99)) : 2)
        let az0 = rng.range(0, 2 * .pi)
        for i in 0..<n {
            let az: Float
            if depth == 0 {
                az = az0 + Float(i) / Float(n) * 2 * .pi + rng.range(-0.3, 0.3)
            } else {
                az = atan2(dir.z, dir.x) + (Float(i) - Float(n - 1) / 2) * 0.9 + rng.range(-0.25, 0.25)
            }
            let e = childElevation[depth] + rng.range(-0.12, 0.12)
            grow(end, V3(cos(az) * cos(e), sin(e), sin(az) * cos(e)), depth + 1)
        }
    }

    let trunkH = rng.range(2.2, 3.4)
    let lean = V3(rng.range(-0.3, 0.3), 0, rng.range(-0.3, 0.3))
    let p1 = V3(lean.x * 0.35, trunkH * 0.5, lean.z * 0.35)
    let p2 = V3(lean.x, trunkH, lean.z)
    m.tube(V3(0, -0.5, 0), p1, 0.27, 0.21, sides: 8)
    m.tube(p1, p2, 0.21, 0.17, sides: 8)
    grow(p2, normalize(V3(lean.x * 0.3, 1, lean.z * 0.3)), 0)

    var center = tips.reduce(V3(), +) / Float(tips.count)
    center.y -= 0.6
    for tip in tips {
        for _ in 0..<26 {
            let c = tip + V3(rng.range(-1.1, 1.1), rng.range(-0.2, 0.28), rng.range(-1.1, 1.1))
            let n = rng.next() < 0.6 ? normalize(V3(rng.range(-0.5, 0.5), 1, rng.range(-0.5, 0.5))) : rng.unit()
            let shade = normalize((c - center) * V3(1, 3, 1) + V3(0, 0.6, 0))
            m.card(center: c, normal: n, size: rng.range(0.6, 1.0), shadeNormal: shade, seed: rng.next(), spin: rng.unit())
        }
    }
    return m
}

func makeShrub(seed: UInt64) -> MeshData {
    var m = MeshData()
    var rng = RNG(seed)
    var tips: [V3] = []
    let stems = Int(rng.range(4, 6.99))
    for i in 0..<stems {
        let az = Float(i) / Float(stems) * 2 * .pi + rng.range(-0.4, 0.4)
        let e = rng.range(0.85, 1.35)
        let dir = V3(cos(az) * cos(e), sin(e), sin(az) * cos(e))
        let len = rng.range(0.8, 1.4)
        let end = V3(0, -0.1, 0) + dir * len
        m.tube(V3(0, -0.1, 0), end, 0.035, 0.02, sides: 4)
        tips.append(end)
        tips.append(end * 0.6)
    }
    let center = V3(0, 0.55, 0)
    for tip in tips {
        for _ in 0..<7 {
            let c = tip + V3(rng.range(-0.4, 0.4), rng.range(-0.25, 0.3), rng.range(-0.4, 0.4))
            m.card(center: c, normal: rng.unit(), size: rng.range(0.4, 0.65),
                   shadeNormal: normalize(c - center + V3(0, 0.4, 0)), seed: rng.next(), spin: rng.unit())
        }
    }
    return m
}

func makeRock(seed: UInt64) -> MeshData {
    var rng = RNG(seed)
    let t: Float = (1 + Float(5).squareRoot()) / 2
    var pos: [V3] = [V3(-1, t, 0), V3(1, t, 0), V3(-1, -t, 0), V3(1, -t, 0), V3(0, -1, t), V3(0, 1, t),
                     V3(0, -1, -t), V3(0, 1, -t), V3(t, 0, -1), V3(t, 0, 1), V3(-t, 0, -1), V3(-t, 0, 1)].map { normalize($0) }
    var tris: [SIMD3<UInt32>] = [SIMD3(0, 11, 5), SIMD3(0, 5, 1), SIMD3(0, 1, 7), SIMD3(0, 7, 10), SIMD3(0, 10, 11),
                                 SIMD3(1, 5, 9), SIMD3(5, 11, 4), SIMD3(11, 10, 2), SIMD3(10, 7, 6), SIMD3(7, 1, 8),
                                 SIMD3(3, 9, 4), SIMD3(3, 4, 2), SIMD3(3, 2, 6), SIMD3(3, 6, 8), SIMD3(3, 8, 9),
                                 SIMD3(4, 9, 5), SIMD3(2, 4, 11), SIMD3(6, 2, 10), SIMD3(8, 6, 7), SIMD3(9, 8, 1)]
    for _ in 0..<3 {
        var cache: [UInt64: UInt32] = [:]
        func midpoint(_ a: UInt32, _ b: UInt32) -> UInt32 {
            let key = UInt64(min(a, b)) << 32 | UInt64(max(a, b))
            if let i = cache[key] { return i }
            pos.append(normalize((pos[Int(a)] + pos[Int(b)]) * 0.5))
            cache[key] = UInt32(pos.count - 1)
            return UInt32(pos.count - 1)
        }
        var next: [SIMD3<UInt32>] = []
        for tri in tris {
            let a = midpoint(tri.x, tri.y), b = midpoint(tri.y, tri.z), c = midpoint(tri.z, tri.x)
            next.append(contentsOf: [SIMD3(tri.x, a, c), SIMD3(tri.y, b, a), SIMD3(tri.z, c, b), SIMD3(a, b, c)])
        }
        tris = next
    }

    // Lumpy, slightly flattened boulder.
    let o = V3(rng.range(0, 50), rng.range(0, 50), rng.range(0, 50))
    let squash = V3(rng.range(0.85, 1.2), rng.range(0.55, 0.8), rng.range(0.85, 1.2))
    pos = pos.map { p in
        let big = fbm(p.x * 1.3 + o.x, p.y * 1.3 + p.z * 0.9 + o.y, 3) - 0.5
        let fine = fbm(p.x * 5 + p.y * 3 + o.z, p.z * 5 - p.y * 2 + o.x, 2) - 0.5
        return p * (1 + big * 0.7 + fine * 0.12) * squash
    }
    var normals = [V3](repeating: V3(), count: pos.count)
    for tri in tris {
        let a = pos[Int(tri.x)], b = pos[Int(tri.y)], c = pos[Int(tri.z)]
        let n = cross(b - a, c - a)
        normals[Int(tri.x)] += n
        normals[Int(tri.y)] += n
        normals[Int(tri.z)] += n
    }

    var m = MeshData()
    for (p, n) in zip(pos, normals) {
        var nn = normalize(n)
        if dot(nn, p) < 0 { nn = -nn }
        m.add(p, nn, V2(0, 0), V4(2, 0, 0, 0))
    }
    for tri in tris { m.indices.append(contentsOf: [tri.x, tri.y, tri.z]) }
    return m
}

// One tuft of unit-height blades; the grass shader scales, rotates, widens and bends it.
// extra = (blade random, side offset x, side offset z, 0).
func makeGrassTuft(seed: UInt64, blades: Int, levels: Int, spread: Float, widthScale: Float) -> MeshData {
    var m = MeshData()
    var rng = RNG(seed)
    for _ in 0..<blades {
        let ba = rng.range(0, 2 * .pi), br = rng.range(0, spread)
        let root = V3(cos(ba) * br, 0, sin(ba) * br)
        let phi = rng.range(0, 2 * .pi)
        let leanDir = V3(cos(phi), 0, sin(phi))
        let side = V3(-sin(phi), 0, cos(phi))
        let lean = rng.range(0.1, 0.6)
        let height = rng.next() < 0.2 ? rng.range(1.0, 1.35) : rng.range(0.45, 1.0)
        let width = rng.range(0.012, 0.02) * widthScale
        let normal = normalize(leanDir + V3(0, 0.45, 0))
        let r = rng.next()
        let base = m.vertexCount
        for level in 0..<levels {
            let t = Float(level) / Float(levels)
            let c = root + leanDir * (lean * t * t * height) + V3(0, height * t * (1 - 0.12 * lean * t), 0)
            let off = side * (width * (1 - t * 0.7) * 0.5)
            m.add(c - off, normal, V2(0, t), V4(r, -off.x, -off.z, 0))
            m.add(c + off, normal, V2(1, t), V4(r, off.x, off.z, 0))
        }
        m.add(root + leanDir * (lean * height) + V3(0, height * (1 - 0.12 * lean), 0), normal, V2(0.5, 1), V4(r, 0, 0, 0))
        for level in 0..<UInt32(levels - 1) {
            let k = base + level * 2
            m.indices.append(contentsOf: [k, k + 1, k + 2, k + 2, k + 1, k + 3])
        }
        let k = base + UInt32(levels - 1) * 2
        m.indices.append(contentsOf: [k, k + 1, k + 2])
    }
    return m
}

extension MeshData {
    mutating func box(center c: V3, half h: V3, extra: V4) {
        let faces: [(V3, V3, V3)] = [(V3(1, 0, 0), V3(0, 1, 0), V3(0, 0, 1)), (V3(-1, 0, 0), V3(0, 1, 0), V3(0, 0, -1)),
                                     (V3(0, 1, 0), V3(0, 0, 1), V3(1, 0, 0)), (V3(0, -1, 0), V3(0, 0, 1), V3(-1, 0, 0)),
                                     (V3(0, 0, 1), V3(0, 1, 0), V3(-1, 0, 0)), (V3(0, 0, -1), V3(0, 1, 0), V3(1, 0, 0))]
        for (n, u, v) in faces {
            let base = vertexCount
            for (su, sv) in [(-1, -1), (1, -1), (1, 1), (-1, 1)] as [(Float, Float)] {
                add(c + (n + u * su + v * sv) * h, n, V2(su, sv), extra)
            }
            indices.append(contentsOf: [base, base + 1, base + 2, base, base + 2, base + 3])
        }
    }
}

// Cape Agulhas lighthouse: a long low limestone building with a round banded tower rising from its
// centre, about 27 m to the lantern. Proportions are from photographs, not from plans.
func makeLighthouse() -> MeshData {
    var m = MeshData()
    let stone = V4(3, 0, 0, 0), red = V4(3, 1, 0, 0), white = V4(3, 2, 0, 0), dark = V4(3, 3, 0, 0)
    m.box(center: V3(0, 2.2, 0), half: V3(15, 2.7, 4.5), extra: stone)
    m.box(center: V3(-13, 3.4, 0), half: V3(2.6, 3.9, 5), extra: stone)
    m.box(center: V3(13, 3.4, 0), half: V3(2.6, 3.9, 5), extra: stone)
    m.box(center: V3(0, 3.6, 0), half: V3(4.2, 4.1, 5.2), extra: stone)
    let bands: [(Float, Float, V4)] = [(7, 13, red), (13, 17, white), (17, 23, red)]
    for (y0, y1, colour) in bands {
        m.tube(V3(0, y0, 0), V3(0, y1, 0), 3.3 - (y0 - 7) * 0.05, 3.3 - (y1 - 7) * 0.05, sides: 20, extra: colour)
    }
    m.tube(V3(0, 23, 0), V3(0, 23.5, 0), 3.4, 3.4, sides: 20, extra: white)
    m.tube(V3(0, 23.5, 0), V3(0, 26, 0), 1.9, 1.9, sides: 12, extra: dark)
    m.tube(V3(0, 26, 0), V3(0, 27.4, 0), 2.1, 0.2, sides: 12, extra: red)
    return m
}
