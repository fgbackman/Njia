// OpenStreetMap features for a stage: roads, buildings and inland water, as mapped by its contributors.
// Data © OpenStreetMap contributors, ODbL. Downloaded by `Njia --bake` through the Overpass API.
import Foundation
import simd

struct OSMData {
    var roads: [(points: [V2], width: Float, paved: Bool)] = []
    var rivers: [(points: [V2], width: Float)] = []
    var water: [[V2]] = []
    var buildings: [Building] = []

    static func query(_ stage: Stage) -> String {
        let dLat = 1150.0 / 110_574, dLon = 1150.0 / (111_320 * cos(stage.lat * .pi / 180))
        let box = String(format: "(%.6f,%.6f,%.6f,%.6f)", stage.lat - dLat, stage.lon - dLon, stage.lat + dLat, stage.lon + dLon)
        return "[out:json][timeout:90];(way[\"highway\"]\(box);way[\"building\"]\(box);way[\"natural\"=\"water\"]\(box);"
            + "way[\"waterway\"]\(box);way[\"aeroway\"=\"runway\"]\(box);relation[\"natural\"=\"water\"]\(box););out geom;"
    }

    static func load(path: String, stage: Stage) -> OSMData? {
        guard let raw = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let elements = json["elements"] as? [[String: Any]] else { return nil }
        var data = OSMData()

        func points(_ geometry: Any?) -> [V2] {
            ((geometry as? [[String: Any]]) ?? []).compactMap { node in
                guard let lat = node["lat"] as? Double, let lon = node["lon"] as? Double else { return nil }
                let m = Geo.metres(stage, lat: lat, lon: lon)
                return V2(m.x, m.z)
            }
        }
        for element in elements {
            let tags = (element["tags"] as? [String: String]) ?? [:]
            if element["type"] as? String == "relation" {
                for member in (element["members"] as? [[String: Any]]) ?? [] where member["role"] as? String == "outer" {
                    let ring = points(member["geometry"])
                    if ring.count >= 3 { data.water.append(ring) }
                }
                continue
            }
            let pts = points(element["geometry"])
            if pts.count < 2 { continue }
            if let kind = tags["highway"] {
                let unpavedKinds: Set<String> = ["track", "path", "footway", "bridleway", "cycleway", "steps", "pedestrian"]
                let unpavedSurfaces: Set<String> = ["unpaved", "dirt", "gravel", "sand", "ground", "earth", "compacted", "grass"]
                let width: Float
                switch kind {
                case "motorway", "trunk", "primary": width = 10
                case "secondary", "tertiary": width = 8
                case "track": width = 3
                case "path", "footway", "bridleway", "cycleway", "steps": width = 1.6
                default: width = 6
                }
                let paved = !unpavedKinds.contains(kind) && !unpavedSurfaces.contains(tags["surface"] ?? "")
                data.roads.append((pts, width, paved))
            } else if tags["aeroway"] == "runway" {
                data.roads.append((pts, 30, ["asphalt", "concrete", "paved"].contains(tags["surface"] ?? "")))
            } else if tags["building"] != nil, pts.count >= 4 {
                data.buildings.append(Building(ring: pts, tags: tags))
            } else if tags["natural"] == "water", pts.count >= 3 {
                data.water.append(pts)
            } else if let kind = tags["waterway"] {
                data.rivers.append((pts, kind == "river" ? 24 : (kind == "canal" ? 10 : 3)))
            }
        }
        return data
    }

    // Ground mask over the walkable square, 2 m per pixel: R paved road, G dirt road or path, B water, A building.
    func mask() -> [UInt8] {
        let s = Geo.imageSize
        var px = [UInt8](repeating: 0, count: s * s * 4)
        let scale = Float(s) / (2 * World.half)

        func line(_ pts: [V2], _ width: Float, _ channel: Int) {
            let r = width / 2
            for k in 0..<pts.count - 1 {
                let a = pts[k], b = pts[k + 1], ab = b - a
                let len2 = max(simd_length_squared(ab), 1e-6)
                let i0 = Int((min(a.x, b.x) - r - 1 + World.half) * scale), i1 = Int((max(a.x, b.x) + r + 1 + World.half) * scale)
                let j0 = Int((min(a.y, b.y) - r - 1 + World.half) * scale), j1 = Int((max(a.y, b.y) + r + 1 + World.half) * scale)
                if i1 < 0 || j1 < 0 || i0 >= s || j0 >= s { continue }
                for j in max(j0, 0)...min(j1, s - 1) {
                    for i in max(i0, 0)...min(i1, s - 1) {
                        let p = V2((Float(i) + 0.5) / scale - World.half, (Float(j) + 0.5) / scale - World.half)
                        let t = min(max(simd_dot(p - a, ab) / len2, 0), 1)
                        let v = UInt8(min(max((r - simd_distance(p, a + ab * t)) * 0.7 + 0.5, 0), 1) * 255)
                        let o = (j * s + i) * 4 + channel
                        if v > px[o] { px[o] = v }
                    }
                }
            }
        }
        func fill(_ ring: [V2], _ channel: Int) {
            let zs = ring.map { $0.y }
            let j0 = max(Int((zs.min()! + World.half) * scale), 0), j1 = min(Int((zs.max()! + World.half) * scale), s - 1)
            if j0 > j1 { return }
            for j in j0...j1 {
                let z = (Float(j) + 0.5) / scale - World.half
                var xs: [Float] = []
                for k in 0..<ring.count {
                    let a = ring[k], b = ring[(k + 1) % ring.count]
                    if (a.y <= z) != (b.y <= z) { xs.append(a.x + (z - a.y) / (b.y - a.y) * (b.x - a.x)) }
                }
                xs.sort()
                var k = 0
                while k + 1 < xs.count {
                    let i0 = max(Int((xs[k] + World.half) * scale + 0.5), 0), i1 = min(Int((xs[k + 1] + World.half) * scale - 0.5), s - 1)
                    if i0 <= i1 { for i in i0...i1 { px[(j * s + i) * 4 + channel] = 255 } }
                    k += 2
                }
            }
        }
        for r in roads { line(r.points, r.width, r.paved ? 0 : 1) }
        for r in rivers { line(r.points, r.width, 2) }
        for w in water { fill(w, 2) }
        for b in buildings { fill(b.ring, 3) }
        return px
    }
}

func fetchOSM(stage: Stage, to path: String) -> Bool {
    if FileManager.default.fileExists(atPath: path) { return true }
    guard let url = URL(string: "https://overpass-api.de/api/interpreter") else { return false }
    var request = URLRequest(url: url, timeoutInterval: 120)
    request.httpMethod = "POST"
    request.setValue("Njia/0.2 (personal project)", forHTTPHeaderField: "User-Agent")
    let encoded = OSMData.query(stage).addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    request.httpBody = Data(("data=" + encoded).utf8)
    for attempt in 0..<3 {
        var body: Data?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200 { body = data }
            done.signal()
        }.resume()
        done.wait()
        if let body = body, (try? JSONSerialization.jsonObject(with: body)) != nil {
            return FileManager.default.createFile(atPath: path, contents: body)
        }
        Thread.sleep(forTimeInterval: Double(attempt + 1) * 8)   // the public server asks clients to back off
    }
    return false
}

// Cross-checks the baked data against sources it was not built from, and prints one line per stage.
func verifyStages(args: [String]) -> Int32 {
    guard let i = args.firstIndex(of: "--verify"), i + 1 < args.count else { return 2 }
    let dir = args[i + 1] + "/stages"
    // Second opinion on elevation: SRTM 30 m through the Open Topo Data public API.
    let list = Route.stages.map { String(format: "%.5f,%.5f", $0.lat, $0.lon) }.joined(separator: "|")
    var second: [Double?] = Array(repeating: nil, count: Route.stages.count)
    if let url = URL(string: "https://api.opentopodata.org/v1/srtm30m?locations=" + (list.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")) {
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: URLRequest(url: url, timeoutInterval: 60)) { data, _, _ in
            if let data = data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let results = json["results"] as? [[String: Any]], results.count == second.count {
                second = results.map { $0["elevation"] as? Double }
            }
            done.signal()
        }.resume()
        done.wait()
    }
    // Second opinion on position: where OpenStreetMap's gazetteer (Nominatim) puts each named place.
    func gazetteer(_ stage: Stage) -> Double? {
        let name = stage.name.components(separatedBy: ",")[0] + ", " + stage.country
        guard let q = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let url = URL(string: "https://nominatim.openstreetmap.org/search?format=json&limit=1&q=" + q) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("Njia/0.2 (personal project)", forHTTPHeaderField: "User-Agent")
        var km: Double?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data = data, let hits = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], let hit = hits.first,
               let lat = Double(hit["lat"] as? String ?? ""), let lon = Double(hit["lon"] as? String ?? "") {
                km = Route.distance(stage, Stage(name: "", country: "", lat: lat, lon: lon, biome: stage.biome))
            }
            done.signal()
        }.resume()
        done.wait()
        Thread.sleep(forTimeInterval: 1.1)   // the service allows one request a second
        return km
    }
    var problems = 0
    for (index, stage) in Route.stages.enumerated() {
        guard let real = RealTerrain.load(dir: dir, index: index) else {
            print(String(format: "%2d %-15@ NO BAKED DATA", index + 1, stage.name))
            problems += 1
            continue
        }
        let ours = Double(real.inner[(Geo.innerN / 2) * Geo.innerN + Geo.innerN / 2])
        let osm = OSMData.load(path: RealTerrain.path(dir, index, "_osm.json"), stage: stage)
        var notes: [String] = []
        if let other = second[index] {
            if abs(other - ours) > 15 { notes.append(String(format: "ELEVATION DISAGREES (SRTM %.0f m)", other)) }
        } else {
            notes.append("no second elevation")
        }
        if osm == nil { notes.append("NO OSM DATA") }
        let off = gazetteer(stage)
        if let off = off, off > 5 { notes.append(String(format: "POSITION %.1f km from gazetteer", off)) }
        if off == nil { notes.append("no gazetteer match") }
        if !notes.isEmpty { problems += 1 }
        print(String(format: "%2d %-15@ elevation %5.0f m, SRTM %@ · OSM roads %4d, buildings %5d, water %3d · %@",
                     index + 1, stage.name, ours, second[index].map { String(format: "%5.0f m", $0) } ?? "    ?",
                     osm?.roads.count ?? 0, osm?.buildings.count ?? 0, (osm?.water.count ?? 0) + (osm?.rivers.count ?? 0),
                     notes.isEmpty ? "ok" : notes.joined(separator: "; ")))
    }
    return problems == 0 ? 0 : 1
}
