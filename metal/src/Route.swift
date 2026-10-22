// The journey: real places from Cape Agulhas to Alexandria, the landscape each one gets, and the real sun.
import Foundation
import simd

struct Biome {
    var relief: Float = 1        // scale of the rolling ground
    var kopjes: Float = 1        // rocky outcrops
    var dunes: Float = 0
    var mountains: Float = 1     // distant ranges
    var trees: Float = 1         // density multipliers
    var shrubs: Float = 1
    var rocks: Float = 1
    var grassCover: Float = 0    // bias: negative is barer
    var grassHeight: Float = 1
    var green: Float = 0         // bias: positive is lusher
    var soilA = V3(0.26, 0.12, 0.055)
    var soilB = V3(0.34, 0.20, 0.10)
    var grassDry = V3(0.40, 0.31, 0.13)
    var haze: Float = 1.0 / 11000
    var clouds: Float = 0        // bias: negative is clearer sky
    var bareAbove: Float = 0.14  // satellite brightness above which ground is bare; grasslands dry to a pale straw, so theirs is high

    static let fynbos = Biome(relief: 0.8, kopjes: 0.6, mountains: 0.8, trees: 0, shrubs: 3.0, rocks: 2.5,
                              grassCover: 0.03, grassHeight: 0.5, green: 0.12,
                              soilA: V3(0.30, 0.25, 0.17), soilB: V3(0.42, 0.36, 0.26), grassDry: V3(0.30, 0.28, 0.14))
    static let karoo = Biome(relief: 0.5, kopjes: 1.6, mountains: 0.7, trees: 0.03, shrubs: 3.2, rocks: 2.2,
                             grassCover: -0.06, grassHeight: 0.4, green: -0.2,
                             soilA: V3(0.25, 0.14, 0.08), soilB: V3(0.36, 0.23, 0.14), grassDry: V3(0.36, 0.31, 0.17),
                             haze: 1.0 / 16000, clouds: -0.07)
    static let highveld = Biome(relief: 0.7, kopjes: 0.5, mountains: 0.3, trees: 0.1, shrubs: 0.5, rocks: 0.6,
                                grassCover: 0.2, grassHeight: 0.8, green: -0.02,
                                soilA: V3(0.27, 0.11, 0.05), soilB: V3(0.35, 0.18, 0.09), grassDry: V3(0.42, 0.33, 0.14),
                                bareAbove: 0.35)
    static let kalahari = Biome(relief: 0.35, kopjes: 0.2, dunes: 0.3, mountains: 0.1, trees: 0.5, shrubs: 1.6, rocks: 0.3,
                                grassCover: -0.05, grassHeight: 0.7, green: -0.15,
                                soilA: V3(0.40, 0.16, 0.065), soilB: V3(0.50, 0.24, 0.11), grassDry: V3(0.45, 0.36, 0.16),
                                clouds: -0.05, bareAbove: 0.35)
    static let miombo = Biome(relief: 0.8, kopjes: 0.7, mountains: 0.6, trees: 2.4, shrubs: 2.0, rocks: 0.8,
                              grassCover: 0.1, grassHeight: 1.0, green: 0.15,
                              soilA: V3(0.25, 0.11, 0.05), soilB: V3(0.33, 0.17, 0.08), grassDry: V3(0.36, 0.29, 0.12),
                              haze: 1.0 / 8000, bareAbove: 0.35)
    // Dry-season savanna grass shows pale straw in the imagery, so only very bright ground (pans, gravel) is bare.
    static let savanna = Biome(grassCover: 0.15, bareAbove: 0.6)
    static let highlands = Biome(relief: 3.0, kopjes: 1.2, mountains: 1.5, trees: 0.6, shrubs: 1.2, rocks: 2.0,
                                 grassCover: 0.15, grassHeight: 0.55, green: 0.3,
                                 soilA: V3(0.22, 0.12, 0.07), soilB: V3(0.30, 0.19, 0.11), grassDry: V3(0.34, 0.30, 0.13),
                                 haze: 1.0 / 14000, bareAbove: 0.35)
    static let sahara = Biome(relief: 0.5, kopjes: 0.4, dunes: 1, mountains: 0.25, trees: 0, shrubs: 0.03, rocks: 0.6,
                              grassCover: -1, grassHeight: 0.4, green: -0.5,
                              soilA: V3(0.50, 0.35, 0.19), soilB: V3(0.60, 0.46, 0.27), grassDry: V3(0.45, 0.38, 0.20),
                              haze: 1.0 / 7000, clouds: -0.12)
    static let nile = Biome(relief: 0.25, kopjes: 0.1, dunes: 0.15, mountains: 0.1, trees: 0.4, shrubs: 1.2, rocks: 0.3,
                            grassCover: 0.12, grassHeight: 0.7, green: 0.3,
                            soilA: V3(0.24, 0.17, 0.10), soilB: V3(0.38, 0.30, 0.19), grassDry: V3(0.34, 0.31, 0.14),
                            haze: 1.0 / 7000, clouds: -0.1)
}

struct Stage {
    let name: String
    let country: String
    let lat: Double
    let lon: Double
    let biome: Biome
    var volcano = false
}

enum Route {
    static let stages: [Stage] = [
        Stage(name: "Cape Agulhas", country: "South Africa", lat: -34.8328, lon: 20.0033, biome: .fynbos),
        Stage(name: "Cape Town", country: "South Africa", lat: -33.925, lon: 18.424, biome: .fynbos),
        Stage(name: "Beaufort West, Great Karoo", country: "South Africa", lat: -32.357, lon: 22.583, biome: .karoo),
        Stage(name: "Kimberley", country: "South Africa", lat: -28.728, lon: 24.762, biome: .highveld),
        Stage(name: "Johannesburg", country: "South Africa", lat: -26.204, lon: 28.047, biome: .highveld),
        Stage(name: "Gaborone", country: "Botswana", lat: -24.628, lon: 25.923, biome: .kalahari),
        Stage(name: "Nata", country: "Botswana", lat: -20.210, lon: 26.180, biome: .kalahari),
        Stage(name: "Victoria Falls", country: "Zimbabwe", lat: -17.924, lon: 25.857, biome: .miombo),
        // City centre (Cairo Road); the first coordinates used were about 5.5 km to the north-east.
        Stage(name: "Lusaka", country: "Zambia", lat: -15.4167, lon: 28.2833, biome: .miombo),
        Stage(name: "Mbeya", country: "Tanzania", lat: -8.909, lon: 33.461, biome: .miombo),
        // Seronera, central Serengeti: the airstrip at 2°27′25″S 34°49′17″E, 1,548 m.
        Stage(name: "Seronera, Serengeti", country: "Tanzania", lat: -2.4569, lon: 34.8214, biome: .savanna),
        Stage(name: "Amboseli", country: "Kenya", lat: -2.652, lon: 37.260, biome: .savanna, volcano: true),
        Stage(name: "Nairobi", country: "Kenya", lat: -1.286, lon: 36.817, biome: .savanna),
        Stage(name: "Addis Ababa", country: "Ethiopia", lat: 9.030, lon: 38.740, biome: .highlands),
        Stage(name: "Lalibela", country: "Ethiopia", lat: 12.030, lon: 39.040, biome: .highlands),
        Stage(name: "Khartoum", country: "Sudan", lat: 15.500, lon: 32.560, biome: .sahara),
        Stage(name: "Wadi Halfa", country: "Sudan", lat: 21.800, lon: 31.350, biome: .sahara),
        Stage(name: "Aswan", country: "Egypt", lat: 24.090, lon: 32.900, biome: .nile),
        Stage(name: "Cairo", country: "Egypt", lat: 30.044, lon: 31.236, biome: .nile),
        Stage(name: "Alexandria", country: "Egypt", lat: 31.200, lon: 29.919, biome: .nile),
    ]

    // Great-circle distance in km.
    static func distance(_ a: Stage, _ b: Stage) -> Double {
        let rad = Double.pi / 180
        let dLat = (b.lat - a.lat) * rad, dLon = (b.lon - a.lon) * rad
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(a.lat * rad) * cos(b.lat * rad) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * 6371 * asin(min(1, h.squareRoot()))
    }

    // Initial great-circle bearing from one stop to another, as a unit vector in world axes (+z north, -x east).
    static func direction(from a: Stage, to b: Stage) -> V2 {
        let rad = Double.pi / 180
        let dLon = (b.lon - a.lon) * rad
        let y = sin(dLon) * cos(b.lat * rad)
        let x = cos(a.lat * rad) * sin(b.lat * rad) - sin(a.lat * rad) * cos(b.lat * rad) * cos(dLon)
        let bearing = atan2(y, x)
        return V2(Float(-sin(bearing)), Float(cos(bearing)))
    }

    static func remaining(from index: Int) -> Double {
        (index..<stages.count - 1).reduce(0) { $0 + distance(stages[$1], stages[$1 + 1]) }
    }

    // Direction to the sun for a latitude, day of year and local solar hour. World axes: +z north, -x east, +y up.
    static func sunDirection(lat: Double, dayOfYear: Int, hour: Float) -> V3 {
        let rad = Double.pi / 180
        let decl = -23.44 * rad * cos(2 * .pi * Double(dayOfYear + 10) / 365)
        let H = Double(hour - 12) * 15 * rad
        let phi = lat * rad
        let sinEl = sin(phi) * sin(decl) + cos(phi) * cos(decl) * cos(H)
        let el = asin(max(sinEl, 0.03))   // held just above the horizon so dawn and dusk stay lit
        let az = atan2(-sin(H) * cos(decl), cos(phi) * sin(decl) - sin(phi) * cos(decl) * cos(H))
        return normalize(V3(Float(-sin(az) * cos(el)), Float(sin(el)), Float(cos(az) * cos(el))))
    }
}
