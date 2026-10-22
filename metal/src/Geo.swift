// Real geography. `Njia --bake` downloads open elevation and satellite tiles for each stage and stores
// them under data/stages; the game loads those files and falls back to an invented landscape without them.
//   Elevation: Mapzen/AWS Terrain Tiles ("terrarium"), built from SRTM, GEBCO and other open sources.
//   Imagery:   Sentinel-2 cloudless 2016 by EOX IT Services GmbH (contains modified Copernicus Sentinel data), CC BY 4.0.
import Foundation
import ImageIO
import simd

enum Geo {
    static let innerN = 257          // 8 m posts over the 2 km walkable square
    static let innerSpacing: Float = 8
    static let outerN = 257          // 125 m posts over 32 km
    static let outerSpacing: Float = 125
    static let imageSize = 1024
    static let farHalf: Float = 16000
    static let horizonN = 257        // 1 km posts over 256 km, for mountains on the skyline
    static let horizonSpacing: Float = 1000
    static let horizonHalf: Float = 128_000

    // World axes: +z north, -x east. Metres from the stage origin to latitude/longitude.
    static func latLon(_ stage: Stage, x: Float, z: Float) -> (Double, Double) {
        let lat = stage.lat + Double(z) / 110_574
        let lon = stage.lon + Double(-x) / (111_320 * cos(stage.lat * .pi / 180))
        return (lat, lon)
    }

    static func metres(_ stage: Stage, lat: Double, lon: Double) -> (x: Float, z: Float) {
        (Float(-(lon - stage.lon) * 111_320 * cos(stage.lat * .pi / 180)), Float((lat - stage.lat) * 110_574))
    }
}

// Decoded RGBA tiles of one slippy-map source at one zoom, sampled by latitude/longitude.
final class TileMosaic {
    private let urlFor: (Int, Int, Int) -> String
    private let ext: String
    private let zoom: Int
    private let cacheDir: String
    private var tiles: [SIMD2<Int32>: [UInt8]] = [:]
    private(set) var failures = 0

    init(zoom: Int, ext: String, cacheDir: String, url: @escaping (Int, Int, Int) -> String) {
        self.zoom = zoom
        self.ext = ext
        self.cacheDir = cacheDir
        urlFor = url
    }

    private func tile(_ x: Int, _ y: Int) -> [UInt8] {
        let key = SIMD2(Int32(x), Int32(y))
        if let t = tiles[key] { return t }
        let path = "\(cacheDir)/\(ext)_\(zoom)_\(x)_\(y).\(ext)"
        var data = FileManager.default.contents(atPath: path)
        if data == nil, let url = URL(string: urlFor(zoom, x, y)) {
            let done = DispatchSemaphore(value: 0)
            var request = URLRequest(url: url, timeoutInterval: 40)
            request.setValue("Njia/0.2 (personal project)", forHTTPHeaderField: "User-Agent")
            URLSession.shared.dataTask(with: request) { body, response, _ in
                if (response as? HTTPURLResponse)?.statusCode == 200 { data = body }
                done.signal()
            }.resume()
            done.wait()
            if let d = data { FileManager.default.createFile(atPath: path, contents: d) }
        }
        var pixels = [UInt8](repeating: 0, count: 256 * 256 * 4)
        if let d = data, let src = CGImageSourceCreateWithData(d as CFData, nil),
           let image = CGImageSourceCreateImageAtIndex(src, 0, nil),
           let ctx = CGContext(data: &pixels, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 1024,
                               space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: 256, height: 256))
        } else {
            failures += 1
        }
        tiles[key] = pixels
        return pixels
    }

    private func pixel(_ px: Int, _ py: Int) -> V3 {
        let n = 256 << zoom
        let x = ((px % n) + n) % n, y = min(max(py, 0), n - 1)
        let t = tile(x / 256, y / 256)
        let o = ((y % 256) * 256 + (x % 256)) * 4
        return V3(Float(t[o]), Float(t[o + 1]), Float(t[o + 2]))
    }

    // Bilinear sample; `decode` turns a pixel into the quantity being interpolated.
    func sample(lat: Double, lon: Double, decode: (V3) -> V3 = { $0 }) -> V3 {
        let n = Double(256 << zoom)
        let fx = (lon + 180) / 360 * n - 0.5
        let fy = (1 - asinh(tan(lat * .pi / 180)) / .pi) / 2 * n - 0.5
        let x0 = Int(fx.rounded(.down)), y0 = Int(fy.rounded(.down))
        let tx = Float(fx - Double(x0)), ty = Float(fy - Double(y0))
        let a = decode(pixel(x0, y0)), b = decode(pixel(x0 + 1, y0))
        let c = decode(pixel(x0, y0 + 1)), d = decode(pixel(x0 + 1, y0 + 1))
        return (a + (b - a) * tx) * (1 - ty) + (c + (d - c) * tx) * ty
    }
}

// What a baked stage holds in memory.
struct RealTerrain {
    let inner: [Float]
    let outer: [Float]
    let horizon: [Float]
    let nearRGBA: [UInt8]   // imageSize², rows run south to north, columns east to west (+x)
    let farRGBA: [UInt8]

    static func path(_ dir: String, _ index: Int, _ suffix: String) -> String {
        String(format: "%@/%02d%@", dir, index, suffix)
    }

    static func load(dir: String, index: Int) -> RealTerrain? {
        let a = Geo.innerN * Geo.innerN, b = a + Geo.outerN * Geo.outerN
        let count = b + Geo.horizonN * Geo.horizonN
        guard let raw = FileManager.default.contents(atPath: path(dir, index, ".terrain")),
              raw.count == count * 4,
              let near = decodeImage(path(dir, index, "_near.jpg")),
              let far = decodeImage(path(dir, index, "_far.jpg")) else { return nil }
        let all = raw.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        return RealTerrain(inner: Array(all[0..<a]), outer: Array(all[a..<b]), horizon: Array(all[b...]), nearRGBA: near, farRGBA: far)
    }

    private static func decodeImage(_ path: String) -> [UInt8]? {
        let s = Geo.imageSize
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil), image.width == s, image.height == s else { return nil }
        var pixels = [UInt8](repeating: 255, count: s * s * 4)
        guard let ctx = CGContext(data: &pixels, width: s, height: s, bitsPerComponent: 8, bytesPerRow: s * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: s, height: s))
        return pixels
    }
}

func bakeStages(args: [String]) -> Int32 {
    guard let i = args.firstIndex(of: "--bake"), i + 2 < args.count else {
        print("usage: Njia --bake <stage number | all> <data directory>")
        return 2
    }
    let dir = args[i + 2] + "/stages", cache = args[i + 2] + "/cache"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(atPath: cache, withIntermediateDirectories: true)
    let which = args[i + 1] == "all" ? Array(Route.stages.indices) : [Int(args[i + 1]) ?? 0]

    func dem(_ zoom: Int) -> TileMosaic {
        TileMosaic(zoom: zoom, ext: "png", cacheDir: cache) { z, x, y in
            "https://s3.amazonaws.com/elevation-tiles-prod/terrarium/\(z)/\(x)/\(y).png"
        }
    }
    func sat(_ zoom: Int) -> TileMosaic {
        TileMosaic(zoom: zoom, ext: "jpg", cacheDir: cache) { z, x, y in
            "https://tiles.maps.eox.at/wmts/1.0.0/s2cloudless_3857/default/g/\(z)/\(y)/\(x).jpg"
        }
    }
    let height: (V3) -> V3 = { V3($0.x * 256 + $0.y + $0.z / 256 - 32768, 0, 0) }

    func writeJPEG(_ rgba: [UInt8], _ path: String) -> Bool {
        let s = Geo.imageSize
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(width: s, height: s, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: s * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.jpeg" as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }

    var status: Int32 = 0
    for index in which where index >= 0 && index < Route.stages.count {
        let stage = Route.stages[index]
        // The wide area also uses fine elevation tiles: the coarse zoom levels smear land out over the sea.
        let demNear = dem(13), demFar = dem(12), demHorizon = dem(9), satNear = sat(14), satFar = sat(12)

        var heights = [Float]()
        for j in 0..<Geo.innerN {
            for i in 0..<Geo.innerN {
                let (lat, lon) = Geo.latLon(stage, x: -World.half + Float(i) * Geo.innerSpacing, z: -World.half + Float(j) * Geo.innerSpacing)
                heights.append(demNear.sample(lat: lat, lon: lon, decode: height).x)
            }
        }
        let innerRange = (heights.min() ?? 0, heights.max() ?? 0)
        for j in 0..<Geo.outerN {
            for i in 0..<Geo.outerN {
                let (lat, lon) = Geo.latLon(stage, x: -Geo.farHalf + Float(i) * Geo.outerSpacing, z: -Geo.farHalf + Float(j) * Geo.outerSpacing)
                heights.append(demFar.sample(lat: lat, lon: lon, decode: height).x)
            }
        }

        var skyline: Float = 0
        for j in 0..<Geo.horizonN {
            for i in 0..<Geo.horizonN {
                let (lat, lon) = Geo.latLon(stage, x: -Geo.horizonHalf + Float(i) * Geo.horizonSpacing, z: -Geo.horizonHalf + Float(j) * Geo.horizonSpacing)
                heights.append(demHorizon.sample(lat: lat, lon: lon, decode: height).x)
                skyline = max(skyline, heights[heights.count - 1])
            }
        }

        func image(_ mosaic: TileMosaic, half: Float) -> [UInt8] {
            let s = Geo.imageSize
            var out = [UInt8](repeating: 255, count: s * s * 4)
            for j in 0..<s {
                for i in 0..<s {
                    let (lat, lon) = Geo.latLon(stage, x: -half + (Float(i) + 0.5) / Float(s) * 2 * half,
                                                z: -half + (Float(j) + 0.5) / Float(s) * 2 * half)
                    let c = mosaic.sample(lat: lat, lon: lon)
                    // CGImage rows run top to bottom; row 0 here is the south edge, and the loader keeps that order.
                    let o = (j * s + i) * 4
                    out[o] = UInt8(min(max(c.x, 0), 255))
                    out[o + 1] = UInt8(min(max(c.y, 0), 255))
                    out[o + 2] = UInt8(min(max(c.z, 0), 255))
                }
            }
            return out
        }
        let near = image(satNear, half: World.half), far = image(satFar, half: Geo.farHalf)
        let failed = demNear.failures + demFar.failures + demHorizon.failures + satNear.failures + satFar.failures
        let wrote = FileManager.default.createFile(atPath: RealTerrain.path(dir, index, ".terrain"),
                                                   contents: heights.withUnsafeBytes { Data($0) })
            && writeJPEG(near, RealTerrain.path(dir, index, "_near.jpg"))
            && writeJPEG(far, RealTerrain.path(dir, index, "_far.jpg"))
        print(String(format: "stage %2d %@: walkable area %.0f to %.0f m · highest point within 128 km %.0f m · %d tiles failed%@",
                     index + 1, stage.name, innerRange.0, innerRange.1, skyline, failed, wrote ? "" : " · WRITE FAILED"))
        if !fetchOSM(stage: stage, to: RealTerrain.path(dir, index, "_osm.json")) {
            print("         OpenStreetMap download failed for \(stage.name); the stage will have no roads or buildings")
            status = 1
        }
        if failed > 0 || !wrote {
            status = 1
            // A partly downloaded stage would be wrong geography; better none than wrong.
            for suffix in [".terrain", "_near.jpg", "_far.jpg"] where failed > 0 {
                try? FileManager.default.removeItem(atPath: RealTerrain.path(dir, index, suffix))
            }
        }
    }
    return status
}
