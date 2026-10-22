// Cloth the avatar library lacks, cut to fit each figure and skinned to its skeleton so it moves with them:
// the Maasai shuka, the kanga or kitenge wrap and headwrap of eastern and southern Africa, and the long white
// jalabiya and turban of Sudan. The weave and print are drawn in `skin_fs`.
import Foundation
import simd

enum Cloth: Float {
    case check = 1   // Maasai shuka: red with dark lines
    case print = 2   // wax print
    case white = 3   // plain cotton
}

enum Garment {
    case wrap(toAnkle: Bool, cloth: Cloth)          // a cloth wound round the waist
    case shuka                                      // a sheet tied over one shoulder
    case cape(cloth: Cloth)                         // a sheet over both shoulders
    case headwrap(cloth: Cloth, height: Float)
}

struct Costume {
    let base: String
    let wear: [Garment]
    let share: [Float]
    var maasai = false
}

extension Cast.Avatar {
    private func joint(_ name: String) -> Int { jointNames.firstIndex(of: "Bip01 " + name) ?? 0 }
    private func position(_ v: Int) -> V3 {
        V3(vertices[v * Cast.vertexFloats], vertices[v * Cast.vertexFloats + 1], vertices[v * Cast.vertexFloats + 2])
    }

    // Cloth vertices carry no texture: extra.x is minus the kind of cloth, and uv is in metres along the weave.
    private mutating func add(_ p: V3, _ n: V3, _ uv: V2, _ weights: [(Int, Float)], _ cloth: Cloth) {
        var w = weights.filter { $0.1 > 0.001 }.sorted { $0.1 > $1.1 }.prefix(4).map { $0 }
        let sum = max(w.reduce(0) { $0 + $1.1 }, 1e-5)
        while w.count < 4 { w.append((0, 0)) }
        vertices.append(contentsOf: [p.x, p.y, p.z, n.x, n.y, n.z, uv.x, uv.y])
        vertices.append(contentsOf: w.map { Float($0.0) })
        vertices.append(contentsOf: w.map { $0.1 / sum })
        vertices.append(contentsOf: [-cloth.rawValue, -1, 0, 0])
    }

    func dressed(_ costume: Costume) -> Cast.Avatar {
        var a = self
        a.member.share = costume.share
        a.member.maasai = costume.maasai
        for g in costume.wear {
            switch g {
            case let .wrap(toAnkle, cloth): a.addWrap(toAnkle: toAnkle, cloth: cloth)
            case .shuka: a.addShell(oneShoulder: true, cloth: .check)
            case let .cape(cloth): a.addShell(oneShoulder: false, cloth: cloth)
            case let .headwrap(cloth, height): a.addHeadwrap(cloth: cloth, height: height)
            }
        }
        a.markHead()
        return a
    }

    // A tube round both legs from the waist down. Each ring is sized from the body at that height; its sides
    // follow the leg on their side, so the cloth swings and stretches between the knees as the figure walks.
    private mutating func addWrap(toAnkle: Bool, cloth: Cloth) {
        let hipL = rest[joint("L Thigh")], hipR = rest[joint("R Thigh")]
        let hip = (hipL.z + hipR.z) / 2, knee = rest[joint("L Calf")].z, ankle = rest[joint("L Foot")].z
        let top = hip + 9, bottom = toAnkle ? ankle + 9 : knee - 7
        let rings = max(Int((top - bottom) / 4), 4), sides = 28
        let leftSign: Float = hipL.x >= hipR.x ? 1 : -1
        var shapes: [(c: V2, r: V2, z: Float)] = []
        for k in 0...rings {
            let z = top + (bottom - top) * Float(k) / Float(rings)
            var lo = V2(repeating: .greatestFiniteMagnitude), hi = -lo
            for v in body {
                let p = position(v)
                if abs(p.z - z) < 4.5 && abs(p.x) < 32 {
                    lo = simd_min(lo, V2(p.x, p.y))
                    hi = simd_max(hi, V2(p.x, p.y))
                }
            }
            if lo.x > hi.x { continue }
            // Snug where it is tied at the waist, looser from the hips down.
            let ease = smoothstep(0, 14, top - z)
            var r = (hi - lo) / 2 * (1.02 + 0.08 * ease) + V2(0.5 + 1.4 * ease, 0.5 + 3.2 * ease)
            var c = (lo + hi) / 2
            if let last = shapes.last {
                // Cloth hangs: it does not draw in below the hips, and it eases out a little towards the hem.
                r = simd_max(r, last.r * 1.004)
                c = last.c + (c - last.c) * 0.3
            }
            shapes.append((c, r, z))
        }
        guard shapes.count >= 2 else { return }
        let pelvis = joint("Pelvis"), thighL = joint("L Thigh"), thighR = joint("R Thigh"), calfL = joint("L Calf"), calfR = joint("R Calf")
        let base = UInt32(vertices.count / Cast.vertexFloats)
        for s in shapes {
            let girth = 2 * Float.pi * (s.r.x + s.r.y) / 2
            for i in 0...sides {
                let ang = Float(i) / Float(sides) * 2 * .pi
                let dir = V2(cos(ang), sin(ang))
                let left = smoothstep(-0.32, 0.32, dir.x * leftSign)
                let t = min(max((hip - s.z) / (hip - knee), 0), 1), below = min(max((knee - s.z) / (knee - ankle), 0), 1)
                var w: [(Int, Float)]
                if s.z >= knee {
                    let p = 1 - 0.92 * smoothstep(0, 0.8, t)
                    w = [(pelvis, p), (thighL, (1 - p) * left), (thighR, (1 - p) * (1 - left))]
                } else {
                    w = [(thighL, (1 - below) * left), (thighR, (1 - below) * (1 - left)), (calfL, below * left), (calfR, below * (1 - left))]
                }
                add(V3(s.c.x + dir.x * s.r.x, s.c.y + dir.y * s.r.y, s.z), normalize(V3(dir.x / s.r.x, dir.y / s.r.y, 0)),
                    V2(Float(i) / Float(sides) * girth, s.z) * 0.01, w, cloth)
            }
        }
        for k in 0..<shapes.count - 1 {
            for i in 0..<sides {
                let p = base + UInt32(k * (sides + 1) + i), q = p + UInt32(sides + 1)
                indices.append(contentsOf: [p, q, p + 1, p + 1, q, q + 1])
            }
        }
    }

    // A second skin over the trunk, a finger's width off the body and moving with it: a sheet tied over one
    // shoulder, or worn over both.
    private mutating func addShell(oneShoulder: Bool, cloth: Cloth) {
        let shoulderL = rest[joint("L UpperArm")], shoulderR = rest[joint("R UpperArm")]
        let hip = rest[joint("L Thigh")].z, armpit = shoulderL.z - 9, across = max(abs(shoulderL.x - shoulderR.x) / 2, 1)
        let trunk: Set<Int> = Set(["Pelvis", "Spine", "Spine1", "Spine2", "L Clavicle", "R Clavicle", "Neck"].map { joint($0) })
        var copy: [Int: UInt32] = [:]
        let stride = Cast.vertexFloats
        func worn(_ v: Int) -> Bool {
            let p = position(v)
            var best = 0
            for k in 1..<4 where vertices[v * stride + 12 + k] > vertices[v * stride + 12 + best] { best = k }
            if !trunk.contains(Int(vertices[v * stride + 8 + best])) || p.z < hip { return false }
            if !oneShoulder { return p.z < shoulderL.z + 4 }
            // The edge runs from the top of one shoulder down under the other arm.
            let side = smoothstep(-0.25, 0.55, p.x / across)
            return p.z < armpit + (shoulderL.z + 7 - armpit) * side
        }
        let start = indices.count
        var k = 0
        while k + 2 < start {
            let tri = [Int(indices[k]), Int(indices[k + 1]), Int(indices[k + 2])]
            k += 3
            if !body.contains(tri[0]) || !tri.allSatisfy(worn) { continue }
            for v in tri {
                if copy[v] == nil {
                    copy[v] = UInt32(vertices.count / stride)
                    let p = position(v), n = V3(vertices[v * stride + 3], vertices[v * stride + 4], vertices[v * stride + 5])
                    let w = (0..<4).map { (Int(vertices[v * stride + 8 + $0]), vertices[v * stride + 12 + $0]) }
                    add(p + n * 1.5, n, V2(atan2(p.y, p.x) * 0.17, p.z * 0.01), w, cloth)
                }
                indices.append(copy[v]!)
            }
        }
    }

    // Cloth wound over the hair: part of an ellipsoid sized from the skull, tipped back so it sits above the brow and low on the nape.
    private mutating func addHeadwrap(cloth: Cloth, height: Float) {
        var top: Float = -.greatestFiniteMagnitude
        for v in head { top = max(top, position(v).z) }
        var lo = V2(repeating: .greatestFiniteMagnitude), hi = -lo
        for v in head {
            let p = position(v)
            if p.z > top - 13 && p.z < top - 3 {
                lo = simd_min(lo, V2(p.x, p.y))
                hi = simd_max(hi, V2(p.x, p.y))
            }
        }
        if lo.x > hi.x { return }
        let forward: Float = rest[joint("L Toe0")].y > rest[joint("L Foot")].y ? 1 : -1
        let c = V3((lo.x + hi.x) / 2, (lo.y + hi.y) / 2 - forward * 0.8, top - 10.5)
        let r = V3((hi.x - lo.x) / 2 + 1.3, (hi.y - lo.y) / 2 + 1.5, 11.6 * height)
        let tilt = simd_quatf(angle: -0.33 * forward, axis: V3(1, 0, 0))
        let headJoint = joint("Head"), sides = 22, rings = 9
        let base = UInt32(vertices.count / Cast.vertexFloats)
        for j in 0...rings {
            let phi = Float(j) / Float(rings) * 1.72
            for i in 0...sides {
                let ang = Float(i) / Float(sides) * 2 * .pi
                let unit = V3(sin(phi) * cos(ang), sin(phi) * sin(ang), cos(phi))
                // Folds of the wound cloth, as shallow ridges round the head.
                let ridge = 1 + 0.03 * sin(phi * 9 + ang * 2)
                let p = c + tilt.act(unit * r * ridge)
                add(p, tilt.act(normalize(unit / r)), V2(ang * 0.09, phi * 0.11), [(headJoint, 1)], cloth)
            }
        }
        for j in 0..<rings {
            for i in 0..<sides {
                let p = base + UInt32(j * (sides + 1) + i), q = p + UInt32(sides + 1)
                indices.append(contentsOf: [p, q, p + 1, p + 1, q, q + 1])
            }
        }
    }
}
