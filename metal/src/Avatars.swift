// The people: modelled, rigged and textured figures from Microsoft's Rocketbox avatar library (MIT licence,
// © 2020 Microsoft), moved by its motion-capture clips. `tools/fetch_people.sh` downloads and converts them to glTF.
// Each figure's clips are baked here into one table of joint matrices that the skin shaders read.
import CoreGraphics
import Foundation
import ImageIO
import simd

// Just enough of glTF 2.0 to read a skinned mesh and its animation.
struct GLTF {
    let nodes: [[String: Any]]
    let root: [String: Any]
    private let accessors: [[String: Any]]
    private let views: [[String: Any]]
    private let bin: Data

    init?(path: String) {
        guard let raw = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let buffers = json["buffers"] as? [[String: Any]], let uri = buffers.first?["uri"] as? String,
              let bin = FileManager.default.contents(atPath: (path as NSString).deletingLastPathComponent + "/" + uri) else { return nil }
        root = json
        nodes = json["nodes"] as? [[String: Any]] ?? []
        accessors = json["accessors"] as? [[String: Any]] ?? []
        views = json["bufferViews"] as? [[String: Any]] ?? []
        self.bin = bin
    }

    static func vector(_ any: Any?) -> [Float]? { (any as? [NSNumber])?.map { $0.floatValue } }

    // An accessor's numbers as floats, and how many make up one element.
    func floats(_ index: Int) -> (values: [Float], width: Int) {
        let a = accessors[index]
        guard let view = a["bufferView"] as? Int, let count = a["count"] as? Int, let comp = a["componentType"] as? Int,
              let width = ["SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16][a["type"] as? String ?? ""] else { return ([], 1) }
        let size = comp == 5126 || comp == 5125 ? 4 : (comp == 5123 || comp == 5122 ? 2 : 1)
        let start = (views[view]["byteOffset"] as? Int ?? 0) + (a["byteOffset"] as? Int ?? 0)
        let stride = views[view]["byteStride"] as? Int ?? size * width
        var out = [Float](repeating: 0, count: count * width)
        guard start + (count - 1) * stride + size * width <= bin.count else { return ([], width) }
        bin.withUnsafeBytes { raw in
            for k in 0..<count {
                for c in 0..<width {
                    let o = start + k * stride + c * size
                    switch comp {
                    case 5126: out[k * width + c] = raw.loadUnaligned(fromByteOffset: o, as: Float.self)
                    case 5125: out[k * width + c] = Float(raw.loadUnaligned(fromByteOffset: o, as: UInt32.self))
                    case 5123: out[k * width + c] = Float(raw.loadUnaligned(fromByteOffset: o, as: UInt16.self))
                    default: out[k * width + c] = Float(raw[o])
                    }
                }
            }
        }
        return (out, width)
    }
}

// One of the library's people: who they can stand in for along the route.
struct CastMember {
    let name: String
    let female: Bool
    let tone: Float        // how light the modelled skin is, 0 darkest to 1 lightest
    let bare: String       // skin showing on the body mesh: f forearm, u upper arm, c calf and foot, t thigh, n neckline
    var share: [Float]     // how common they are: southern Africa, eastern Africa, Ethiopia, Sudan, Egypt
    var maasai = false     // dressed as the Maasai of Amboseli and the Serengeti do
}

// A motion-capture clip, read once and applied to every figure of its sex.
private struct Motion {
    var duration: Float = 0
    var rotations: [String: [simd_quatf]] = [:]
    var rootName = ""
    var root: [V3] = []

    init?(path: String, limit: Float) {
        guard let g = GLTF(path: path), let anim = (g.root["animations"] as? [[String: Any]])?.first,
              let channels = anim["channels"] as? [[String: Any]], let samplers = anim["samplers"] as? [[String: Any]] else { return nil }
        var full: Float = 0
        for c in channels {
            guard let target = c["target"] as? [String: Any], let node = target["node"] as? Int, let path = target["path"] as? String,
                  let s = c["sampler"] as? Int, let input = samplers[s]["input"] as? Int, let output = samplers[s]["output"] as? Int,
                  let name = g.nodes[node]["name"] as? String else { continue }
            let times = g.floats(input).values
            full = max(full, times.last ?? 0)
            let v = g.floats(output).values
            if path == "rotation" {
                rotations[name] = stride(from: 0, to: v.count - 3, by: 4).map { simd_quatf(ix: v[$0], iy: v[$0 + 1], iz: v[$0 + 2], r: v[$0 + 3]) }
            } else if path == "translation", name.hasSuffix("$AssimpFbx$_Translation"), name.hasPrefix("Bip01") {
                rootName = name
                root = stride(from: 0, to: v.count - 2, by: 3).map { V3(v[$0], v[$0 + 1], v[$0 + 2]) }
            }
        }
        guard full > 0, root.count > 1 else { return nil }
        // Keys are evenly spaced. A long clip is cut to its first `limit` seconds.
        let cut = min(full, limit)
        duration = cut
        let keep = { (n: Int) -> Int in n < 3 ? n : max(2, Int((Float(n - 1) * cut / full).rounded()) + 1) }
        for (name, keys) in rotations { rotations[name] = Array(keys.prefix(keep(keys.count))) }
        root = Array(root.prefix(keep(root.count)))
    }

    // Where along its keys time `t` falls, and how far the pose has faded back to the start so the clip loops.
    private func place(_ t: Float, _ count: Int) -> (Int, Float, Float) {
        let x = min(max(t / duration, 0), 1) * Float(count - 1)
        let k = min(Int(x), max(count - 2, 0))
        return (k, x - Float(k), smoothstep(duration - min(0.6, duration * 0.2), duration, t))
    }

    func rotation(_ name: String, _ t: Float) -> simd_quatf? {
        guard let keys = rotations[name], !keys.isEmpty else { return nil }
        if keys.count == 1 { return keys[0] }
        let (k, f, fade) = place(t, keys.count)
        return simd_slerp(simd_slerp(keys[k], keys[k + 1], f), keys[0], fade)
    }

    // The hips: height as recorded, and sideways sway with the travel taken out (the game moves the figure itself).
    func hips(_ t: Float) -> V3 {
        let (k, f, fade) = place(t, root.count)
        let travel = root[root.count - 1] - root[0]
        var p = root[k] + (root[k + 1] - root[k]) * f - travel * (t / duration)
        p += (root[0] - p) * fade
        return V3(p.x - root[0].x, p.y, p.z - root[0].z)
    }

    var travel: V3 { root[root.count - 1] - root[0] }
}

final class Cast {
    static let joints = 80
    static let vertexFloats = 20   // position 3, normal 3, uv 2, joints 4, weights 4, extra 4 (colour slice, normal slice, skin 1 or head 2, alpha)
    static let members: [CastMember] = [
        CastMember(name: "Male_Adult_04", female: false, tone: 0.22, bare: "", share: [3, 3, 2, 1, 0.5]),
        CastMember(name: "Male_Adult_12", female: false, tone: 0.15, bare: "n", share: [3, 3, 2, 1, 0.5]),
        CastMember(name: "Male_Adult_18", female: false, tone: 0.1, bare: "", share: [2, 2, 1, 0.5, 0.3]),
        CastMember(name: "Business_Male_05", female: false, tone: 0.3, bare: "", share: [2, 2, 2, 1, 1.5]),
        CastMember(name: "Construction_Male_03", female: false, tone: 0.15, bare: "", share: [1, 1, 1, 0.5, 0.5]),
        CastMember(name: "Sports_Male_03", female: false, tone: 0.3, bare: "fut", share: [1.5, 1.5, 1, 0.5, 1]),
        CastMember(name: "Male_Adult_08", female: false, tone: 0.8, bare: "fn", share: [2, 2, 2, 1.5, 3]),
        CastMember(name: "Male_Adult_01", female: false, tone: 0.8, bare: "fuc", share: [1.5, 1.5, 0.5, 0.2, 1]),
        CastMember(name: "Male_Adult_11", female: false, tone: 0.8, bare: "fun", share: [2, 2, 2, 1.5, 3]),
        CastMember(name: "Business_Male_07", female: false, tone: 0.8, bare: "", share: [1, 1, 1.5, 1, 2]),
        CastMember(name: "Wood_Male_01", female: false, tone: 0.6, bare: "n", share: [1.5, 1.5, 1.5, 1, 2]),
        CastMember(name: "Male_Adult_15", female: false, tone: 0.55, bare: "", share: [0.3, 0.3, 0.5, 5, 2]),
        CastMember(name: "Business_Female_01", female: true, tone: 0.2, bare: "n", share: [2.5, 2.5, 2, 0.5, 1]),
        CastMember(name: "Female_Party_02", female: true, tone: 0.4, bare: "fuctn", share: [2.5, 2.5, 1.5, 0.2, 0.5]),
        CastMember(name: "Female_Adult_02", female: true, tone: 0.8, bare: "cn", share: [2, 2, 2, 0.3, 1]),
        CastMember(name: "Female_Adult_15", female: true, tone: 0.8, bare: "cn", share: [2, 2, 2, 0.5, 1.5]),
        CastMember(name: "Female_Adult_17", female: true, tone: 0.8, bare: "fun", share: [2, 2, 1, 0.2, 1]),
        CastMember(name: "Female_Adult_11", female: true, tone: 0.8, bare: "tn", share: [1.5, 1.5, 1.5, 0.3, 1]),
        CastMember(name: "Female_Adult_01", female: true, tone: 0.8, bare: "fn", share: [1.5, 1.5, 1, 0.2, 1.5]),
        CastMember(name: "Female_Adult_06", female: true, tone: 0.75, bare: "", share: [0.4, 0.4, 1, 4, 4]),
        CastMember(name: "Female_Adult_10", female: true, tone: 0.75, bare: "", share: [0.1, 0.1, 0.3, 3, 2.5]),
        CastMember(name: "Female_Adult_03", female: true, tone: 0.8, bare: "fun", share: [1.5, 1.5, 1, 0.1, 1]),
        CastMember(name: "Male_Adult_02", female: false, tone: 0.8, bare: "", share: [1, 1, 1.5, 1, 2]),
        CastMember(name: "Female_Adult_14", female: true, tone: 0.8, bare: "n", share: [1.5, 1.5, 1.5, 0.3, 1.5]),
        CastMember(name: "Male_Adult_17", female: false, tone: 0.45, bare: "", share: [1, 1, 1, 1, 1.5]),
        // Only ever seen dressed: see `costumes`.
        CastMember(name: "Sports_Male_01", female: false, tone: 0.8, bare: "fuctn", share: [0, 0, 0, 0, 0]),
    ]
    // People of the library dressed in cloth the library lacks, cut to fit each of them (Garments.swift).
    static let costumes: [Costume] = [
        Costume(base: "Sports_Male_01", wear: [.shuka, .wrap(toAnkle: false, cloth: .check)], share: [0, 0, 0, 0, 0], maasai: true),
        Costume(base: "Female_Adult_17", wear: [.wrap(toAnkle: true, cloth: .check), .cape(cloth: .check)], share: [0, 0, 0, 0, 0], maasai: true),
        Costume(base: "Female_Adult_17", wear: [.wrap(toAnkle: true, cloth: .print), .headwrap(cloth: .print, height: 1.25)], share: [1.5, 3.5, 0.5, 0.3, 0]),
        Costume(base: "Female_Adult_03", wear: [.wrap(toAnkle: true, cloth: .print), .headwrap(cloth: .print, height: 1.1)], share: [1.5, 3.5, 0.5, 0.3, 0]),
        Costume(base: "Female_Party_02", wear: [.wrap(toAnkle: true, cloth: .print)], share: [1.5, 3, 0.5, 0.2, 0]),
        Costume(base: "Female_Adult_14", wear: [.wrap(toAnkle: true, cloth: .print), .headwrap(cloth: .print, height: 1.15)], share: [1, 3, 0.5, 0.2, 0]),
        Costume(base: "Male_Adult_15", wear: [.wrap(toAnkle: true, cloth: .white), .headwrap(cloth: .white, height: 1.0)], share: [0, 0.1, 1, 6, 1.5]),
    ]
    // Clips every figure has, in this order; `m_` or `f_` is put in front. Walks are sampled at 30 frames a second.
    static let clipNames = ["walk_neutral_01", "walk_stroll_01", "idle_neutral_01", "idle_neutral_02", "gestic_talk_neutral_01"]
    enum Clip: Int { case walk, stroll, idle, idleTwo, talk }

    struct Baked {
        let start: Int          // first frame in the palette
        let frames: Int         // frames in one loop; one more follows, a copy of the first
        let rate: Float         // frames a second
        let distance: Float     // metres walked in one loop
    }

    struct Avatar {
        var member: CastMember
        var vertices: [Float] = []
        var indices: [UInt32] = []
        var clips: [Baked] = []
        // For fitting clothes: which vertices are the body and which the head, the joints' names, and where each
        // joint sits in the mesh's own space (centimetres, z up) with the figure at rest.
        var body = 0..<0
        var head = 0..<0
        var jointNames: [String] = []
        var rest: [V3] = []
        // For turning the head to look at someone: the head's joint, and how far each joint follows it (the neck part-way).
        var headJoint = 0
        var headShare: [Float] = []

        // Each vertex carries how far it turns with the head in the fraction of its third extra value.
        mutating func markHead() {
            let n = Cast.vertexFloats
            for v in 0..<vertices.count / n {
                var w: Float = 0
                for k in 0..<4 { w += vertices[v * n + 12 + k] * headShare[min(Int(vertices[v * n + 8 + k]), Cast.joints - 1)] }
                vertices[v * n + 18] = vertices[v * n + 18].rounded(.down) + 0.49 * min(w, 1)
            }
        }
    }

    // Where a figure's head joint is, in its own space in metres, for the mix of poses an instance is drawn with.
    func headPivot(_ avatar: Int, anim: V4) -> V3 {
        let a = avatars[avatar]
        let rest = V4(a.rest[a.headJoint], 1)
        var p = V3()
        func add(_ frame: Float, _ weight: Float) {
            if weight < 0.004 { return }
            let o = (Int(frame) * Cast.joints + a.headJoint) * 12
            if o + 12 > palette.count { return }
            for row in 0..<3 { p[row] += weight * simd_dot(V4(palette[o + row * 4], palette[o + row * 4 + 1], palette[o + row * 4 + 2], palette[o + row * 4 + 3]), rest) }
        }
        let fa = anim.x.rounded(.down), fb = anim.y.rounded(.down), ta = anim.x - fa, tb = anim.y - fb
        add(fa, (1 - ta) * (1 - anim.z)); add(fa + 1, ta * (1 - anim.z))
        add(fb, (1 - tb) * anim.z); add(fb + 1, tb * anim.z)
        return p
    }

    static var directory: String { (Bundle.main.resourcePath ?? ".") + "/people" }
    static let shared: Cast? = Cast(dir: directory)

    private(set) var avatars: [Avatar] = []
    private(set) var palette: [Float] = []        // 12 floats (three rows of a 3×4 matrix) per joint per frame
    private(set) var colourFiles: [String] = []   // one array slice each, 1024 px
    private(set) var normalFiles: [String] = []   // 512 px

    // The darker the skin, the less light it returns: tone 0 to 1 as a share of light reflected.
    static func reflectance(_ tone: Float) -> Float { 0.05 + 0.4 * pow(min(max(tone, 0), 1), 1.4) }

    init?(dir: String) {
        var motions: [[Motion]] = [[], []]
        for (s, prefix) in ["m_", "f_"].enumerated() {
            for (k, name) in Cast.clipNames.enumerated() {
                guard let m = Motion(path: "\(dir)/anim/\(prefix)\(name).gltf", limit: k == Clip.talk.rawValue ? 12 : 30) else { return nil }
                motions[s].append(m)
            }
        }
        // The clips walk towards wherever the library's figures face; the game's figures face +z.
        let ahead = motions[0][0].travel
        let facing = simd_quatf(angle: -atan2(ahead.x, ahead.z), axis: V3(0, 1, 0))
        for member in Cast.members {
            if let a = load(member, dir: dir, motions: motions[member.female ? 1 : 0], facing: facing) { avatars.append(a) }
        }
        if avatars.isEmpty { return nil }
        for costume in Cast.costumes {
            if let base = avatars.first(where: { $0.member.name == costume.base }) { avatars.append(base.dressed(costume)) }
        }
    }

    private func load(_ member: CastMember, dir: String, motions: [Motion], facing: simd_quatf) -> Avatar? {
        guard let g = GLTF(path: "\(dir)/\(member.name).gltf"),
              let skin = (g.root["skins"] as? [[String: Any]])?.first, let joints = skin["joints"] as? [Int], joints.count == Cast.joints,
              let bindAccessor = skin["inverseBindMatrices"] as? Int,
              let mesh = (g.root["meshes"] as? [[String: Any]])?.first, let primitives = mesh["primitives"] as? [[String: Any]],
              let materials = g.root["materials"] as? [[String: Any]] else { return nil }
        var avatar = Avatar(member: member)
        let jointNames = joints.map { g.nodes[$0]["name"] as? String ?? "" }
        avatar.jointNames = jointNames

        for p in primitives {
            guard let attributes = p["attributes"] as? [String: Int], let pos = attributes["POSITION"], let nrm = attributes["NORMAL"],
                  let uv = attributes["TEXCOORD_0"], let jn = attributes["JOINTS_0"], let wt = attributes["WEIGHTS_0"],
                  let idx = p["indices"] as? Int, let material = p["material"] as? Int,
                  let part = (materials[material]["name"] as? String)?.components(separatedBy: "_").last else { continue }
            let alpha = part == "opacity"
            let colour = "\(dir)/\(member.name)_\(part)_color." + (part == "body" || part == "head" ? "jpg" : "png")
            guard FileManager.default.fileExists(atPath: colour) else { continue }
            colourFiles.append(colour)
            var normalSlice: Float = -1
            let normal = "\(dir)/\(member.name)_\(part)_normal.jpg"
            if FileManager.default.fileExists(atPath: normal) {
                normalSlice = Float(normalFiles.count)
                normalFiles.append(normal)
            }
            let P = g.floats(pos).values, N = g.floats(nrm).values, T = g.floats(uv).values, J = g.floats(jn).values, W = g.floats(wt).values
            let base = UInt32(avatar.vertices.count / Cast.vertexFloats)
            for v in 0..<P.count / 3 {
                // Skin may be recoloured only where this figure shows any: the head, the hands, and whatever its clothes leave bare.
                var best = 0
                for k in 1..<4 where W[v * 4 + k] > W[v * 4 + best] { best = k }
                let bone = jointNames[min(Int(J[v * 4 + best]), Cast.joints - 1)]
                var skinHere: Float = part == "head" || alpha ? 2 : 0   // 2: hair is here too
                if part == "body" {
                    func has(_ s: String) -> Bool { bone.contains(s) }
                    if has("Hand") || has("Finger") || has("Neck") || has("Head") { skinHere = 1 }
                    if has("Forearm") && member.bare.contains("f") { skinHere = 1 }
                    if has("UpperArm") && member.bare.contains("u") { skinHere = 1 }
                    if (has("Calf") || has("Foot") || has("Toe")) && member.bare.contains("c") { skinHere = 1 }
                    if has("Thigh") && member.bare.contains("t") { skinHere = 1 }
                    if (has("Spine2") || has("Clavicle")) && member.bare.contains("n") { skinHere = 1 }
                }
                avatar.vertices.append(contentsOf: [P[v * 3], P[v * 3 + 1], P[v * 3 + 2], N[v * 3], N[v * 3 + 1], N[v * 3 + 2], T[v * 2], T[v * 2 + 1]])
                avatar.vertices.append(contentsOf: J[v * 4..<v * 4 + 4])
                let sum = max(W[v * 4] + W[v * 4 + 1] + W[v * 4 + 2] + W[v * 4 + 3], 1e-5)
                avatar.vertices.append(contentsOf: W[v * 4..<v * 4 + 4].map { $0 / sum })
                avatar.vertices.append(contentsOf: [Float(colourFiles.count - 1), normalSlice, skinHere, alpha ? 1 : 0])
            }
            avatar.indices.append(contentsOf: g.floats(idx).values.map { base + UInt32($0) })
            let range = Int(base)..<avatar.vertices.count / Cast.vertexFloats
            if part == "body" { avatar.body = range }
            if part == "head" { avatar.head = range }
        }
        if avatar.indices.isEmpty { return nil }

        // The skeleton at rest, parents before children.
        struct Bone {
            var name: String
            var parent = -1
            var t = V3(), s = V3(1, 1, 1)
            var r = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }
        var bones = g.nodes.map { n -> Bone in
            var b = Bone(name: n["name"] as? String ?? "")
            if let t = GLTF.vector(n["translation"]), t.count == 3 { b.t = V3(t[0], t[1], t[2]) }
            if let s = GLTF.vector(n["scale"]), s.count == 3 { b.s = V3(s[0], s[1], s[2]) }
            if let r = GLTF.vector(n["rotation"]), r.count == 4 { b.r = simd_quatf(ix: r[0], iy: r[1], iz: r[2], r: r[3]) }
            return b
        }
        for (i, n) in g.nodes.enumerated() {
            for c in n["children"] as? [Int] ?? [] { bones[c].parent = i }
        }
        var order: [Int] = []
        var stack = bones.indices.filter { bones[$0].parent < 0 }
        while let i = stack.popLast() {
            order.append(i)
            stack.append(contentsOf: g.nodes[i]["children"] as? [Int] ?? [])
        }
        avatar.headShare = joints.map { j in
            if bones[j].name == "Bip01 Neck" { return 0.35 }
            var i = j
            while i >= 0 {
                if bones[i].name == "Bip01 Head" { return 1 }
                i = bones[i].parent
            }
            return 0
        }
        avatar.headJoint = jointNames.firstIndex(of: "Bip01 Head") ?? 0
        avatar.markHead()
        let bindValues = g.floats(bindAccessor).values
        let bind = (0..<Cast.joints).map { j -> M4 in
            let m = Array(bindValues[j * 16..<j * 16 + 16])
            return M4(columns: (V4(m[0], m[1], m[2], m[3]), V4(m[4], m[5], m[6], m[7]), V4(m[8], m[9], m[10], m[11]), V4(m[12], m[13], m[14], m[15])))
        }
        avatar.rest = bind.map { m in
            let p = m.inverse.columns.3
            return V3(p.x, p.y, p.z)
        }
        // Model units are centimetres; the palette turns the figure to face +z and brings it to metres.
        var toGame = M4(facing)
        toGame = M4(diagonal: V4(0.01, 0.01, 0.01, 1)) * toGame

        // Feet: where the ankles and toes sit when the figure stands at rest, to keep every clip's lowest step on the ground.
        var world = [M4](repeating: matrix_identity_float4x4, count: bones.count)
        let feet = ["Bip01 L Foot", "Bip01 R Foot", "Bip01 L Toe0", "Bip01 R Toe0"].compactMap { n in bones.firstIndex { $0.name == n } }
        for i in order {
            let b = bones[i]
            var local = M4(b.r)
            local.columns.3 = V4(b.t, 1)
            world[i] = b.parent < 0 ? local : world[b.parent] * local
        }
        let standing = feet.map { world[$0].columns.3.y }
        for (k, motion) in motions.enumerated() {
            let rate: Float = k < 2 ? 30 : 15
            let frames = max(Int(motion.duration * rate), 2)
            let rootIndex = bones.firstIndex { $0.name == motion.rootName } ?? -1
            let ratio = rootIndex >= 0 ? bones[rootIndex].t.y / max(motion.root[0].y, 1) : 1
            avatar.clips.append(Baked(start: palette.count / (Cast.joints * 12), frames: frames, rate: rate,
                                      distance: simd_length(V2(motion.travel.x, motion.travel.z)) * ratio * 0.01))
            var lowest = Float.greatestFiniteMagnitude
            let first = palette.count
            for f in 0...frames {
                let t = motion.duration * Float(f) / Float(frames)
                for i in order {
                    let b = bones[i]
                    var translation = b.t
                    if i == rootIndex {
                        let h = motion.hips(t)
                        translation = V3(b.t.x + h.x * ratio, h.y * ratio, b.t.z + h.z * ratio)
                    }
                    let rotation = motion.rotation(b.name, t) ?? b.r
                    var local = M4(rotation)
                    local.columns.0 *= b.s.x
                    local.columns.1 *= b.s.y
                    local.columns.2 *= b.s.z
                    local.columns.3 = V4(translation, 1)
                    world[i] = b.parent < 0 ? local : world[b.parent] * local
                }
                for j in 0..<Cast.joints {
                    let m = toGame * world[joints[j]] * bind[j]
                    for row in 0..<3 {
                        palette.append(contentsOf: [m.columns.0[row], m.columns.1[row], m.columns.2[row], m.columns.3[row]])
                    }
                }
                for (k, i) in feet.enumerated() { lowest = min(lowest, world[i].columns.3.y - standing[k]) }
            }
            // The recorded hips belong to another body; shift the clip so its lowest footfall meets the ground.
            if lowest < 1e6 {
                for o in stride(from: first + 7, to: palette.count, by: 12) { palette[o] -= lowest * 0.01 }
            }
        }
        return avatar
    }

    // A picture file as RGBA bytes at `size` pixels square, alpha not premultiplied.
    static func pixels(_ path: String, size: Int) -> [UInt8]? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        var px = [UInt8](repeating: 0, count: size * size * 4)
        let hasAlpha = ![CGImageAlphaInfo.none, .noneSkipLast, .noneSkipFirst].contains(image.alphaInfo)
        let drawn = px.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: (hasAlpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast).rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
            return true
        }
        if !drawn { return nil }
        if hasAlpha {
            for i in stride(from: 0, to: px.count, by: 4) where px[i + 3] > 0 && px[i + 3] < 255 {
                let a = Int(px[i + 3])
                for c in 0..<3 { px[i + c] = UInt8(min(Int(px[i + c]) * 255 / a, 255)) }
            }
        } else {
            for i in stride(from: 3, to: px.count, by: 4) { px[i] = 255 }
        }
        return px
    }
}
