import Foundation
import simd

typealias V2 = SIMD2<Float>
typealias V3 = SIMD3<Float>
typealias V4 = SIMD4<Float>
typealias M4 = simd_float4x4

func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
    let t = min(max((x - a) / (b - a), 0), 1)
    return t * t * (3 - 2 * t)
}

// Right-handed, camera looks down -Z, reversed depth (near → 1, far → 0).
func perspectiveReversedZ(fovY: Float, aspect: Float, near: Float, far: Float) -> M4 {
    let ys = 1 / tan(fovY * 0.5)
    let xs = ys / aspect
    let a = near / (far - near)
    let b = near * far / (far - near)
    return M4(columns: (V4(xs, 0, 0, 0), V4(0, ys, 0, 0), V4(0, 0, a, -1), V4(0, 0, b, 0)))
}

func lookAt(eye: V3, center: V3, up: V3) -> M4 {
    let f = normalize(center - eye)
    let s = normalize(cross(f, up))
    let u = cross(s, f)
    return M4(columns: (V4(s.x, u.x, -f.x, 0), V4(s.y, u.y, -f.y, 0), V4(s.z, u.z, -f.z, 0),
                        V4(-dot(s, eye), -dot(u, eye), dot(f, eye), 1)))
}

// Right-handed orthographic, depth 0 at `near` and 1 at `far` (distances along -Z).
func ortho(l: Float, r: Float, b: Float, t: Float, near: Float, far: Float) -> M4 {
    M4(columns: (V4(2 / (r - l), 0, 0, 0), V4(0, 2 / (t - b), 0, 0), V4(0, 0, -1 / (far - near), 0),
                 V4(-(r + l) / (r - l), -(t + b) / (t - b), -near / (far - near), 1)))
}

struct RNG {
    private var s: UInt64

    init(_ seed: UInt64) { s = seed &* 0x9E37_79B9_7F4A_7C15 &+ 0x1234_5678 }

    mutating func next() -> Float {
        s = s &+ 0x9E37_79B9_7F4A_7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Float(z >> 40) / Float(1 << 24)
    }

    mutating func range(_ a: Float, _ b: Float) -> Float { a + (b - a) * next() }

    mutating func unit() -> V3 {
        while true {
            let v = V3(range(-1, 1), range(-1, 1), range(-1, 1))
            let l = length(v)
            if l > 0.05 && l <= 1 { return v / l }
        }
    }
}
