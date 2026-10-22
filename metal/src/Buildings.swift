// Buildings from their OpenStreetMap footprints and tags. What is mapped is used as mapped: height, storeys,
// roof shape, wall and roof materials and colours. What is not mapped is filled in from the stage's regional
// style, and roofs take their colour from the satellite image where the footprint is big enough to show in it.
import Foundation
import simd

struct Building {
    var ring: [V2]
    var kind = "yes"
    var height: Float?        // mapped total height in metres
    var levels: Float?        // mapped storeys
    var minHeight: Float = 0
    var roofShape: String?
    var wallMaterial: String?
    var roofMaterial: String?
    var wallColour: V3?       // linear RGB
    var roofColour: V3?
    var open = false          // a roof on posts: carports, shelters, market roofs

    init(ring: [V2], tags: [String: String]) {
        self.ring = ring
        kind = tags["building"] ?? "yes"
        height = Building.metres(tags["height"])
        levels = Float(tags["building:levels"] ?? "")
        minHeight = Building.metres(tags["min_height"]) ?? 0
        roofShape = tags["roof:shape"]
        wallMaterial = tags["building:material"]
        roofMaterial = tags["roof:material"] ?? tags["building:roof"]
        wallColour = Building.colour(tags["building:colour"])
        roofColour = Building.colour(tags["roof:colour"])
        open = ["roof", "carport"].contains(kind) || tags["wall"] == "no" || tags["amenity"] == "shelter"
    }

    static func metres(_ s: String?) -> Float? {
        guard let s = s else { return nil }
        return Float(s.replacingOccurrences(of: "m", with: "").trimmingCharacters(in: .whitespaces))
    }

    static func linear(_ hex: UInt32) -> V3 {
        let c = V3(Float((hex >> 16) & 255), Float((hex >> 8) & 255), Float(hex & 255)) / 255
        return c * c * (c * 0.305 + 0.695)
    }

    static let named: [String: UInt32] = [
        "white": 0xf2f0ea, "black": 0x222222, "grey": 0x8c8c8c, "gray": 0x8c8c8c, "red": 0xa33a2c, "brown": 0x7a5238,
        "blue": 0x4a6f9c, "green": 0x4f7a4f, "yellow": 0xe0c860, "beige": 0xd9c8a5, "cream": 0xe8dcc0, "orange": 0xd0803c,
        "tan": 0xc9ad86, "pink": 0xdba8a0, "maroon": 0x6e2a26, "silver": 0xb4b8bc, "lightgrey": 0xc4c4c4, "lightgray": 0xc4c4c4,
        "darkgrey": 0x555555, "darkgray": 0x555555,
    ]

    static func colour(_ s: String?) -> V3? {
        guard var s = s?.lowercased().trimmingCharacters(in: .whitespaces) else { return nil }
        if let hex = named[s.replacingOccurrences(of: "_", with: "")] { return linear(hex) }
        guard s.hasPrefix("#") else { return nil }
        s.removeFirst()
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return linear(v)
    }
}

// How unmapped detail is filled in for a stage. These are generalisations about each region's ordinary
// buildings, not surveys: plastered block and corrugated iron across the south and east, stone and mud in the
// Ethiopian highlands, flat-roofed mud and brick along the Nile.
struct BuildStyle {
    var walls: [UInt32]
    var roofs: [UInt32]         // sheet-metal colours for pitched roofs
    var pitched: Float          // share of small unmapped buildings given a pitched roof
    var tiled: Float            // share of those roofed in tile instead of sheet metal
    var cityLevels: Float       // storeys assumed for large unmapped footprints

    static func of(_ stage: Stage, index: Int) -> BuildStyle {
        let metal: [UInt32] = [0x8d9093, 0xa9adb0, 0x7b5440, 0x7d3a2c, 0x4c6650, 0x46607c]
        switch stage.country {
        case "South Africa":
            return BuildStyle(walls: [0xf2efe6, 0xe3d6b8, 0x9a5a3c, 0xcfcac0, 0xd9c39a], roofs: metal, pitched: 0.85, tiled: 0.35,
                              cityLevels: index == 1 || index == 4 ? 3 : 1)
        case "Botswana":
            return BuildStyle(walls: [0xe6d9bd, 0xf0ece2, 0xb4b0a6, 0xc9ad86], roofs: metal, pitched: 0.85, tiled: 0.1, cityLevels: 1)
        case "Zimbabwe":
            return BuildStyle(walls: [0xe6d9bd, 0xf0ece2, 0xb4b0a6, 0x94573a], roofs: metal, pitched: 0.85, tiled: 0.15, cityLevels: 1)
        case "Zambia":
            return BuildStyle(walls: [0xaaa69c, 0xe3d8bf, 0x8f5237, 0xeeeae0], roofs: metal, pitched: 0.7, tiled: 0.05, cityLevels: 2)
        case "Tanzania":
            return BuildStyle(walls: [0xaaa69c, 0xe3d8bf, 0x94573a, 0x8a6a4e], roofs: [0xa9adb0, 0x8d9093, 0x7b5440, 0x6f4a3a],
                              pitched: 0.9, tiled: 0, cityLevels: 1)
        case "Kenya":
            return BuildStyle(walls: [0xb9b5ab, 0xe3d8bf, 0x8e9093, 0xeeeae0], roofs: [0x9b4a35, 0x8d9093, 0x7b5440, 0x4c6650],
                              pitched: 0.6, tiled: 0.3, cityLevels: index == 12 ? 4 : 1)
        case "Ethiopia":
            return index == 13
                ? BuildStyle(walls: [0xb4b0a6, 0xd8cdb4, 0xc7b9a0, 0x9fa9a8], roofs: [0x8d9093, 0xa9adb0, 0x7b5440], pitched: 0.7, tiled: 0, cityLevels: 2)
                : BuildStyle(walls: [0x8c6f55, 0x9a8468, 0x7d6a58, 0xb4a58c], roofs: [0xa9adb0, 0x8d9093, 0x7b5440], pitched: 0.9, tiled: 0, cityLevels: 1)
        case "Sudan":
            return BuildStyle(walls: [0xc2a67e, 0xb89a70, 0xd6c3a0, 0xa98c66], roofs: [0xb89a70], pitched: 0, tiled: 0, cityLevels: index == 15 ? 2 : 1)
        default:   // Egypt
            return index == 17
                ? BuildStyle(walls: [0xd2bf9c, 0xc7ae84, 0x9c5b42, 0xe0d2b4], roofs: [0xb8a888], pitched: 0, tiled: 0, cityLevels: 3)
                : BuildStyle(walls: [0xd8c9a3, 0xc9b68f, 0x9c5b42, 0xbdb3a0, 0xd6c8ae], roofs: [0xb0a590], pitched: 0, tiled: 0, cityLevels: 6)
        }
    }
}

private func hash(_ n: Int, _ salt: Int) -> Float {
    var z = UInt64(truncatingIfNeeded: n &* 0x9E37 &+ salt) &* 0x9E37_79B9_7F4A_7C15
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z ^= z >> 27
    return Float(z >> 40) / Float(1 << 24)
}

private func signedArea(_ r: [V2]) -> Float {
    var a: Float = 0
    for k in 0..<r.count {
        let p = r[k], q = r[(k + 1) % r.count]
        a += p.x * q.y - q.x * p.y
    }
    return a / 2
}

// Ear clipping. Returns index triples into the ring; falls back to a fan if the outline is degenerate.
private func triangulate(_ ring: [V2]) -> [Int] {
    var idx = Array(ring.indices)
    if signedArea(ring) < 0 { idx.reverse() }
    var out: [Int] = []
    func cross2(_ o: V2, _ a: V2, _ b: V2) -> Float { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
    var guardCount = 0
    while idx.count > 3 && guardCount < 4000 {
        guardCount += 1
        var clipped = false
        for k in 0..<idx.count {
            let i0 = idx[(k + idx.count - 1) % idx.count], i1 = idx[k], i2 = idx[(k + 1) % idx.count]
            let a = ring[i0], b = ring[i1], c = ring[i2]
            if cross2(a, b, c) <= 1e-7 { continue }
            var empty = true
            for j in idx where j != i0 && j != i1 && j != i2 {
                let p = ring[j]
                if cross2(a, b, p) >= 0 && cross2(b, c, p) >= 0 && cross2(c, a, p) >= 0 {
                    empty = false
                    break
                }
            }
            if !empty { continue }
            out.append(contentsOf: [i0, i1, i2])
            idx.remove(at: k)
            clipped = true
            break
        }
        if !clipped { break }
    }
    if idx.count == 3 {
        out.append(contentsOf: idx)
    } else if idx.count > 3 {
        for k in 1..<idx.count - 1 { out.append(contentsOf: [idx[0], idx[k], idx[k + 1]]) }
    }
    return out
}

extension OSMData {
    // Where a fair number of a stage's buildings have mapped storeys, the rest of the large ones follow their median.
    func typicalLevels(_ style: BuildStyle) -> Float {
        let mapped = buildings.compactMap { $0.levels }.filter { $0 >= 1 }.sorted()
        return mapped.count >= 30 ? mapped[mapped.count / 2] : style.cityLevels
    }

    // Storeys as mapped, else by the kind of building and the size of its footprint.
    static func storeys(_ b: Building, area: Float, small: Bool, typical: Float) -> Float {
        if let l = b.levels, l >= 1 { return l }
        switch b.kind {
        case "apartments", "dormitory", "hotel", "office": return max(typical, 3)
        case "commercial", "retail", "mall", "university", "hospital", "public", "government": return max(typical, 2)
        default: return area > 150 && !small ? max(typical, 1) : 1
        }
    }

    // Each building's centre and approximate height, before any mesh is built.
    func roughHeights(stage: Stage, index: Int) -> [(centre: V2, reach: Float, height: Float)] {
        let typical = typicalLevels(BuildStyle.of(stage, index: index))
        return buildings.filter { !$0.open && $0.ring.count >= 3 }.map { b in
            let c = b.ring.reduce(V2(), +) / Float(b.ring.count)
            let area = abs(signedArea(b.ring))
            let h = b.height ?? OSMData.storeys(b, area: area, small: area < 14, typical: typical) * 3
            return (c, b.ring.map { simd_distance($0, c) }.max()!, h)
        }
    }

    // Vertex materials (extra.x): 5 house wall, 6 commercial wall, 7 roof; extra.yzw is the linear colour.
    // Wall uv is (bay, storey) so the shader can set windows and doors into whole bays; uv.x < 0 is a blank wall.
    // Roof uv.x is the covering: 0 concrete, 1 sheet metal, 2 thatch, 3 tile.
    func buildingMesh(stage: Stage, index: Int, height: (Float, Float) -> Float, imagery: (Float, Float) -> V3)
        -> (mesh: MeshData, footprints: [[V2]]) {
        var m = MeshData()
        var footprints: [[V2]] = []
        let style = BuildStyle.of(stage, index: index)
        // Where a fair number of this stage's buildings have mapped storeys, the rest of the large ones follow their median.
        let typical = typicalLevels(style)

        for (n, b) in buildings.enumerated() {
            var ring = b.ring
            if simd_distance(ring.first!, ring.last!) < 0.01 { ring.removeLast() }
            if ring.count < 3 { continue }
            if signedArea(ring) < 0 { ring.reverse() }
            let area = signedArea(ring)
            if area < 1.5 { continue }
            let centre = ring.reduce(V2(), +) / Float(ring.count)
            if max(abs(centre.x), abs(centre.y)) > World.half - 4 { continue }

            // Shape of the outline: its tightest bounding rectangle, and whether it is round.
            var u = V2(1, 0), obb = Float.greatestFiniteMagnitude
            var lo = V2(), hi = V2()
            for k in 0..<ring.count {
                let e = ring[(k + 1) % ring.count] - ring[k]
                if simd_length(e) < 0.3 { continue }
                let d = simd_normalize(e), p = V2(-d.y, d.x)
                let us = ring.map { simd_dot($0, d) }, vs = ring.map { simd_dot($0, p) }
                let a = (us.max()! - us.min()!) * (vs.max()! - vs.min()!)
                if a < obb {
                    obb = a
                    let long = us.max()! - us.min()! >= vs.max()! - vs.min()!
                    u = long ? d : p
                    let v = V2(-u.y, u.x)
                    let uu = ring.map { simd_dot($0, u) }, vv = ring.map { simd_dot($0, v) }
                    lo = V2(uu.min()!, vv.min()!)
                    hi = V2(uu.max()!, vv.max()!)
                }
            }
            let v = V2(-u.y, u.x)
            let halfW = (hi.y - lo.y) / 2
            let radii = ring.map { simd_distance($0, centre) }
            let meanR = radii.reduce(0, +) / Float(radii.count)
            let round = ring.count >= 7 && meanR < 7 && radii.allSatisfy { abs($0 - meanR) < meanR * 0.14 }
            let small = ["hut", "shed", "toilets", "kitchen", "garage", "garages", "kiosk", "cabin", "shack"].contains(b.kind) || area < 14

            // Storeys and heights.
            var levels = OSMData.storeys(b, area: area, small: small, typical: typical)
            let storey: Float = small ? 2.3 : 3.0
            // Ground under the walls, sampled along them: the floor sits at its highest point and the walls reach down to its lowest.
            var ground: [Float] = []
            for k in 0..<ring.count {
                let a = ring[k], c = ring[(k + 1) % ring.count]
                let steps = max(1, Int(simd_distance(a, c) / 5))
                for t in 0..<steps {
                    let p = a + (c - a) * (Float(t) / Float(steps))
                    ground.append(height(p.x, p.y))
                }
            }
            let floor = ground.max()! + b.minHeight
            let base = b.minHeight > 0 ? floor : ground.min()! - 0.6

            // Roof form: as mapped, else by outline and regional habit.
            enum Roof { case flat, gabled, hipped, cone }
            let regular = ring.count <= 12 && area / max(obb, 0.01) > 0.8 && halfW <= 8 && halfW > 0.8
            var roof = Roof.flat
            switch b.roofShape ?? "" {
            case "gabled", "gambrel", "saltbox", "round": roof = regular ? .gabled : .flat
            case "hipped", "half-hipped", "pyramidal": roof = regular ? .hipped : .flat
            case "flat", "skillion", "dome", "onion": roof = .flat
            default:
                if round || b.kind == "hut" {
                    roof = .cone
                } else if regular && levels <= 2 && hash(n, 1) < style.pitched {
                    roof = hash(n, 2) < 0.25 ? .hipped : .gabled
                }
            }
            if round && roof != .flat { roof = .cone }
            if b.open { roof = .flat }
            let rise: Float = roof == .flat ? 0 : (roof == .cone ? max(1.2, meanR * 0.75) : min(max(halfW * 0.42, 0.5), 3.2))
            var wallH = b.open && b.levels == nil ? 3 : levels * storey
            if let h = b.height, h > b.minHeight + 1 {
                wallH = max(h - b.minHeight - rise, 2.1)
                if b.levels == nil { levels = max(1, (wallH / 3).rounded()) }
            }
            wallH = min(wallH, 300)
            let top = floor + wallH

            // Covering and colours.
            let sat = imagery(centre.x, centre.y)
            let roofTag = (b.roofMaterial ?? "").lowercased()
            var cover: Float = roof == .flat ? 0 : 1
            if roofTag.contains("thatch") || roofTag.contains("grass") {
                cover = 2
            } else if roofTag.contains("tile") {
                cover = 3
            } else if roofTag.contains("metal") || roofTag.contains("zinc") || b.open {
                cover = 1
            } else if roofTag.contains("concrete") {
                cover = 0
            } else if roof == .cone && style.pitched > 0 {
                cover = 2
            } else if roof != .flat && roof != .cone && hash(n, 3) < style.tiled && !small {
                cover = 3
            }
            var roofColour: V3
            if let c = b.roofColour {
                roofColour = c
            } else {
                switch cover {
                case 2: roofColour = Building.linear(hash(n, 4) < 0.5 ? 0x8a7350 : 0x77664a)
                case 3: roofColour = Building.linear(hash(n, 4) < 0.6 ? 0x9b4a35 : 0x6b4034)
                case 1: roofColour = Building.linear(style.roofs[Int(hash(n, 4) * Float(style.roofs.count)) % style.roofs.count])
                default: roofColour = Building.linear(0xa8a296)
                }
                // The imagery shows a roof once it covers a pixel or two; smaller ones only lean towards it.
                if cover != 2 { roofColour = simd_mix(roofColour, simd_clamp(sat * 1.15, V3(repeating: 0.03), V3(repeating: 0.8)), V3(repeating: area > 220 ? 0.75 : 0.3)) }
            }
            var wallColour: V3
            let wallTag = (b.wallMaterial ?? "").lowercased()
            if let c = b.wallColour {
                wallColour = c
            } else if wallTag.contains("mud") || wallTag.contains("loam") || wallTag.contains("adobe") {
                wallColour = Building.linear(hash(n, 5) < 0.5 ? 0x8a6a4e : 0x9a7a5a)
            } else if wallTag.contains("brick") {
                wallColour = Building.linear(0x94573a)
            } else if wallTag.contains("cement") || wallTag.contains("concrete") {
                wallColour = Building.linear(hash(n, 5) < 0.55 ? 0xaaa69c : 0xe3d8bf)
            } else if wallTag.contains("metal") {
                wallColour = Building.linear(0x8d9093)
            } else if wallTag.contains("wood") || wallTag.contains("reed") {
                wallColour = Building.linear(0x7a6248)
            } else if wallTag.contains("stone") {
                wallColour = Building.linear(0x8c8474)
            } else if roof == .cone && style.pitched > 0 {
                wallColour = Building.linear(hash(n, 5) < 0.5 ? 0x8a6a4e : 0xb09a78)
            } else {
                wallColour = Building.linear(style.walls[Int(hash(n, 5) * Float(style.walls.count)) % style.walls.count])
            }
            wallColour *= 0.92 + 0.16 * hash(n, 6)
            let commercial = ["commercial", "retail", "office", "mall", "hotel", "apartments", "public", "government", "university",
                              "hospital", "industrial", "warehouse", "supermarket"].contains(b.kind) || levels >= 3
            let wall = V4(commercial ? 6 : 5, wallColour.x, wallColour.y, wallColour.z)
            let roofX = V4(7, roofColour.x, roofColour.y, roofColour.z)
            let blank = small || roof == .cone

            func quad(_ p0: V3, _ p1: V3, _ p2: V3, _ p3: V3, _ uv: [V2], _ extra: V4, up: Bool = false) {
                var nrm = cross(p1 - p0, p3 - p0)
                if simd_length(nrm) < 1e-6 { nrm = cross(p1 - p0, p2 - p0) }
                if simd_length(nrm) < 1e-6 { return }
                nrm = normalize(nrm)
                let mid = (p0 + p1 + p2 + p3) / 4
                if up ? nrm.y < 0 : simd_dot(V2(nrm.x, nrm.z), V2(mid.x, mid.z) - centre) < 0 { nrm = -nrm }
                let i = m.vertexCount
                m.add(p0, nrm, uv[0], extra)
                m.add(p1, nrm, uv[1], extra)
                m.add(p2, nrm, uv[2], extra)
                m.add(p3, nrm, uv[3], extra)
                m.indices.append(contentsOf: [i, i + 1, i + 2, i, i + 2, i + 3])
            }

            if b.open {
                // A roof on posts.
                let post = V4(3, 3, 0, 0)
                let stepBy = max(1, ring.count / 10)
                for k in stride(from: 0, to: ring.count, by: stepBy) {
                    let p = ring[k] + (centre - ring[k]) * 0.04
                    m.tube(V3(p.x, height(p.x, p.y) - 0.2, p.y), V3(p.x, top, p.y), 0.06, 0.06, sides: 5, extra: post)
                }
            } else {
                let parapet: Float = roof == .flat && !small ? 0.45 : 0
                for k in 0..<ring.count {
                    let a = ring[k], c = ring[(k + 1) % ring.count]
                    let len = simd_distance(a, c)
                    if len < 0.05 { continue }
                    let bays: Float = blank || len < 2.2 ? -1 : max(1, (len / 3.1).rounded())
                    let y0 = (base - floor) / (wallH / levels)
                    // Each wall starts its bays at a different whole number, so doors fall differently on each.
                    let off = bays < 0 ? 0 : Float(((n * 7 + k * 13) % 50) * 8)
                    quad(V3(a.x, base, a.y), V3(c.x, base, c.y), V3(c.x, top, c.y), V3(a.x, top, a.y),
                         [V2(bays < 0 ? -1 : off, y0), V2(bays < 0 ? -1 : off + bays, y0), V2(bays < 0 ? -1 : off + bays, levels), V2(bays < 0 ? -1 : off, levels)], wall)
                    if parapet > 0 {
                        quad(V3(a.x, top, a.y), V3(c.x, top, c.y), V3(c.x, top + parapet, c.y), V3(a.x, top + parapet, a.y),
                             [V2(-1, 0), V2(-1, 0), V2(-1, 0), V2(-1, 0)], wall)
                    }
                }
                footprints.append(ring)
            }

            switch roof {
            case .flat:
                let y = b.open ? top : top + 0.02
                let first = m.vertexCount
                for p in ring { m.add(V3(p.x, y, p.y), V3(0, 1, 0), V2(cover, 0), roofX) }
                for i in triangulate(ring) { m.indices.append(first + UInt32(i)) }
            case .cone:
                let apex = V3(centre.x, top + rise, centre.y)
                for k in 0..<ring.count {
                    let a = centre + (ring[k] - centre) * 1.16, c = centre + (ring[(k + 1) % ring.count] - centre) * 1.16
                    quad(V3(a.x, top - 0.25, a.y), V3(c.x, top - 0.25, c.y), apex, apex, [V2(cover, 0), V2(cover, 0), V2(cover, 1), V2(cover, 1)], roofX, up: true)
                }
            case .gabled, .hipped:
                let inset = roof == .hipped ? min(halfW, (hi.x - lo.x) / 2) : 0
                let r0 = lo.x + inset, r1 = hi.x - inset, mid = (lo.y + hi.y) / 2
                func ridge(_ p: V2) -> V3 {
                    let q = u * min(max(simd_dot(p, u), r0), r1) + v * mid
                    return V3(q.x, top + rise, q.y)
                }
                // Eaves stand a little proud of the walls.
                func eave(_ p: V2) -> V3 {
                    let q = p + v * (simd_dot(p, v) > mid ? 0.3 : -0.3)
                    return V3(q.x, top - 0.12, q.y)
                }
                for k in 0..<ring.count {
                    let a = ring[k], c = ring[(k + 1) % ring.count]
                    if simd_distance(a, c) < 0.05 { continue }
                    let pa = ridge(a), pc = ridge(c)
                    let slope = abs(simd_dot(simd_normalize(c - a), u)) > 0.5 || roof == .hipped
                    if slope {
                        quad(eave(a), eave(c), pc, pa, [V2(cover, 0), V2(cover, 0), V2(cover, 1), V2(cover, 1)], roofX, up: true)
                    } else {
                        quad(V3(a.x, top, a.y), V3(c.x, top, c.y), pc, pa, [V2(-1, 0), V2(-1, 0), V2(-1, 0), V2(-1, 0)], wall)
                    }
                }
            }
        }
        return (m, footprints)
    }
}

// Footprints in a grid, so the walker can be kept outside walls.
struct Footprints {
    private var rings: [[V2]] = []
    private var cells: [SIMD2<Int32>: [Int32]] = [:]
    private static let cell: Float = 32

    init(_ rings: [[V2]] = []) {
        self.rings = rings
        for (i, r) in rings.enumerated() {
            let xs = r.map { $0.x }, zs = r.map { $0.y }
            let c0 = Int32(((xs.min()! - 1) / Footprints.cell).rounded(.down)), c1 = Int32(((xs.max()! + 1) / Footprints.cell).rounded(.down))
            let d0 = Int32(((zs.min()! - 1) / Footprints.cell).rounded(.down)), d1 = Int32(((zs.max()! + 1) / Footprints.cell).rounded(.down))
            for d in d0...d1 { for c in c0...c1 { cells[SIMD2(c, d), default: []].append(Int32(i)) } }
        }
    }

    // Moves a point that is inside a wall, or within `margin` of one, back out to `margin` from it.
    func resolve(_ p: V2, margin: Float) -> V2 {
        var p = p
        let key = SIMD2(Int32((p.x / Footprints.cell).rounded(.down)), Int32((p.y / Footprints.cell).rounded(.down)))
        for i in cells[key] ?? [] {
            let r = rings[Int(i)]
            var inside = false
            var best = Float.greatestFiniteMagnitude, nearest = p
            for k in 0..<r.count {
                let a = r[k], b = r[(k + 1) % r.count]
                if (a.y <= p.y) != (b.y <= p.y), a.x + (p.y - a.y) / (b.y - a.y) * (b.x - a.x) > p.x { inside.toggle() }
                let ab = b - a
                let t = min(max(simd_dot(p - a, ab) / max(simd_length_squared(ab), 1e-6), 0), 1)
                let q = a + ab * t
                let d = simd_distance(p, q)
                if d < best {
                    best = d
                    nearest = q
                }
            }
            if inside {
                let out = best > 1e-4 ? (nearest - p) / best : V2(1, 0)
                p = nearest + out * margin
            } else if best < margin && best > 1e-4 {
                p = nearest + (p - nearest) / best * margin
            }
        }
        return p
    }

    func contains(_ p: V2) -> Bool { simd_distance(resolve(p, margin: 0.01), p) > 0.005 }
}
