// The people of each stop: who they are, how they move, and what they say. Their bodies come from Avatars.swift.
import Foundation
import simd

extension MeshData {
    // A tube through elliptical rings (centre, half-width across, half-depth), with smooth normals.
    // uv is in metres: around the ring, and along the tube. Ends close to a point when their radii are small.
    mutating func loft(_ rings: [(c: V3, rx: Float, rz: Float)], sides: Int, extra: V4) {
        guard rings.count >= 2 else { return }
        var pts: [[V3]] = []
        var run: Float = 0
        var runs: [Float] = []
        for (i, r) in rings.enumerated() {
            let t = normalize(rings[min(i + 1, rings.count - 1)].c - rings[max(i - 1, 0)].c)
            let ref = abs(t.z) > 0.9 ? V3(0, 1, 0) : V3(0, 0, 1)
            let bx = abs(t.z) > 0.9 ? normalize(cross(ref, t)) : normalize(cross(t, ref))
            let bz = abs(t.z) > 0.9 ? cross(t, bx) : cross(bx, t)
            pts.append((0...sides).map { k in
                let a = Float(k) / Float(sides) * 2 * .pi
                return r.c + bx * (cos(a) * r.rx) + bz * (sin(a) * r.rz)
            })
            if i > 0 { run += simd_distance(r.c, rings[i - 1].c) }
            runs.append(run)
        }
        let base = vertexCount
        for i in 0..<rings.count {
            for k in 0...sides {
                let around = pts[i][(k + 1) % sides] - pts[i][(k + sides - 1) % sides]
                let along = pts[min(i + 1, rings.count - 1)][k] - pts[max(i - 1, 0)][k]
                var n = cross(around, along)
                let out = pts[i][k] - rings[i].c
                if simd_length(n) < 1e-9 || simd_length(out) < 1e-5 {
                    n = i == 0 ? rings[0].c - rings[1].c : rings[i].c - rings[i - 1].c
                } else if simd_dot(n, out) < 0 {
                    n = -n
                }
                add(pts[i][k], normalize(n), V2(Float(k) / Float(sides) * 2 * .pi * (rings[i].rx + rings[i].rz) / 2, runs[i]), extra)
            }
        }
        for i in 0..<UInt32(rings.count - 1) {
            for k in 0..<UInt32(sides) {
                let a = base + i * UInt32(sides + 1) + k, b = a + UInt32(sides + 1)
                indices.append(contentsOf: [a, b, a + 1, a + 1, b, b + 1])
            }
        }
    }

    mutating func ball(_ c: V3, _ r: V3, sides: Int = 10, rings: Int = 6, extra: V4) {
        loft((0...rings).map { i in
            let a = Float(i) / Float(rings) * .pi
            return (c + V3(0, -cos(a) * r.y, 0), max(sin(a), 0.02) * r.x, max(sin(a), 0.02) * r.z)
        }, sides: sides, extra: extra)
    }
}

// A market stall: a table of goods under a cloth awning. The trader stands behind it as one of the people.
func makeStall() -> MeshData {
    var m = MeshData()
    let wood = V4(3, 5, 0, 0), cloth = V4(3, 1, 0, 0), white = V4(3, 2, 0, 0), dark = V4(3, 3, 0, 0)
    m.box(center: V3(0, 0.78, 0.9), half: V3(1.0, 0.03, 0.4), extra: wood)
    for x in [-0.92, 0.92] as [Float] {
        for z in [0.55, 1.25] as [Float] { m.tube(V3(x, 0, z), V3(x, 0.78, z), 0.03, 0.03, sides: 6, extra: wood) }
        m.tube(V3(x, -0.2, -0.5), V3(x, 2.3, -0.5), 0.035, 0.035, sides: 6, extra: wood)
        m.tube(V3(x, -0.2, 1.3), V3(x, 2.05, 1.3), 0.035, 0.035, sides: 6, extra: wood)
    }
    for z in [-0.5, 1.3] as [Float] { m.tube(V3(-0.92, z < 0 ? 2.28 : 2.03, z), V3(0.92, z < 0 ? 2.28 : 2.03, z), 0.025, 0.025, sides: 5, extra: wood) }
    let i = m.vertexCount
    for (p, uv) in [(V3(-1.1, 2.32, -0.62), V2(0, 0)), (V3(1.1, 2.32, -0.62), V2(1, 0)), (V3(1.1, 2.04, 1.45), V2(1, 1)), (V3(-1.1, 2.04, 1.45), V2(0, 1))] {
        m.add(p, normalize(V3(0, 1, 0.13)), uv, cloth)
    }
    m.indices.append(contentsOf: [i, i + 1, i + 2, i, i + 2, i + 3])
    for (x, c) in [(-0.62, white), (-0.12, cloth), (0.42, dark)] as [(Float, V4)] { m.box(center: V3(x, 0.9, 0.95), half: V3(0.17, 0.09, 0.15), extra: c) }
    for (x, z) in [(-0.3, 0.7), (0.72, 0.8), (0.1, 0.68)] as [(Float, Float)] {
        m.ball(V3(x, 0.89, z), V3(0.1, 0.08, 0.1), sides: 9, rings: 5, extra: wood)
    }
    return m
}

struct Person {
    var pos: V2
    var yaw: Float
    var avatar: Int            // index into the cast
    var female: Bool
    var scale: Float
    var seed: Float
    var skin: Float            // 0 darkest to 1 lightest
    var name: String
    var path = -1              // index into the stage's walkable roads; -1 stands still
    var along: Float = 0       // metres along that road
    var heading: Float = 1     // +1 or -1 along it
    var speed: Float = 1.0
    var stroll = false         // which of the two walks they have
    var phase: Float = 0       // 0 to 1 through the walk cycle
    var walk: Float = 0        // 0 standing to 1 striding
    var met: Float = 0         // 0 minding their own business to 1 talking to the walker
    var homeYaw: Float = 0
    var look: Float = 0        // how far the head is turned from straight ahead, radians
    var aside: Float = 0       // metres stepped out of their lane to pass someone
    var chat: Float? = nil     // standing in talk with someone: where in the turn-taking they are
}

enum Locals {
    // A greeting each stop's people would use, with its language and meaning.
    static let greetings: [(String, String, String)] = [
        ("Goeie dag", "Afrikaans", "good day"), ("Molo", "isiXhosa", "hello"), ("Goeie dag", "Afrikaans", "good day"),
        ("Dumela", "Setswana", "hello"), ("Sawubona", "isiZulu", "hello"), ("Dumela", "Setswana", "hello"),
        ("Dumela", "Setswana", "hello"), ("Salibonani", "isiNdebele", "hello"), ("Muli bwanji", "Chinyanja", "how are you"),
        ("Habari", "Swahili", "how are things"), ("Karibu", "Swahili", "welcome"), ("Sopa", "Maa", "hello"),
        ("Habari yako", "Swahili", "how are you"), ("Selam", "Amharic", "hello"), ("Tena yistilign", "Amharic", "may you be given health"),
        ("As-salamu alaykum", "Arabic", "peace be upon you"), ("As-salamu alaykum", "Arabic", "peace be upon you"),
        ("Ahlan wa sahlan", "Arabic", "welcome"), ("Ahlan wa sahlan", "Arabic", "welcome"), ("Ahlan wa sahlan", "Arabic", "welcome"),
    ]

    static let names: [String: (men: [String], women: [String])] = [
        "South Africa": (["Sipho", "Pieter", "Thabo", "Bongani"], ["Lerato", "Nomsa", "Zanele", "Anneke"]),
        "Botswana": (["Kagiso", "Tebogo", "Mpho", "Thabo"], ["Neo", "Boitumelo", "Lesedi", "Keletso"]),
        "Zimbabwe": (["Tendai", "Farai", "Sibusiso", "Tatenda"], ["Nokuthula", "Rudo", "Chipo", "Thandiwe"]),
        "Zambia": (["Chanda", "Mutale", "Bwalya", "Mulenga"], ["Mwila", "Natasha", "Chileshe", "Mwaka"]),
        "Tanzania": (["Juma", "Baraka", "Hamisi", "Emmanuel"], ["Neema", "Rehema", "Zawadi", "Upendo"]),
        "Kenya": (["Kamau", "Otieno", "Lemayian", "Kiprop"], ["Wanjiru", "Akinyi", "Naserian", "Chebet"]),
        "Ethiopia": (["Abebe", "Dawit", "Tesfaye", "Yonas"], ["Tigist", "Selam", "Meseret", "Hiwot"]),
        "Sudan": (["Osman", "Ahmed", "Ibrahim", "Khalid"], ["Amira", "Fatima", "Hanan", "Salma"]),
        "Egypt": (["Youssef", "Mahmoud", "Mostafa", "Karim"], ["Mona", "Nour", "Heba", "Dina"]),
    ]

    // Which of the cast's five regions a stop draws its people from, and how light their skin runs (lowest, spread).
    static func mix(_ stage: Stage, index: Int) -> (region: Int, skin: (Float, Float)) {
        switch stage.country {
        case "Ethiopia": return (2, (0.15, 0.3))
        case "Sudan": return (3, (0.05, 0.4))
        case "Egypt": return (4, (0.35, 0.45))
        case "South Africa": return (0, (0.02, index <= 2 ? 0.75 : 0.4))
        case "Botswana", "Zimbabwe": return (0, (0.02, 0.22))
        case "Kenya": return (1, (index == 11 ? 0.0 : 0.02, index == 11 ? 0.18 : 0.22))
        default: return (1, (0.02, 0.22))
        }
    }

    static func compass(_ offset: V2) -> String {
        // World axes: +z north, -x east.
        let deg = atan2(-offset.x, offset.y) * 180 / .pi
        let names = ["north", "north-east", "east", "south-east", "south", "south-west", "west", "north-west"]
        return names[Int(((deg + 360 + 22.5).truncatingRemainder(dividingBy: 360)) / 45) % 8]
    }
}
