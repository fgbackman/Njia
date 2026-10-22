// Metal renderer: sky LUT → two shadow cascades → grass placement (compute) → HDR scene (4x MSAA) → tone map.
import Foundation
import Metal
import simd

// Mirrors `U` in Shaders.metal.
struct Uniforms {
    var viewProj = matrix_identity_float4x4
    var shadowVP0 = matrix_identity_float4x4
    var shadowVP1 = matrix_identity_float4x4
    var camPos = V4()
    var camRight = V4()
    var camUp = V4()
    var camFwd = V4()
    var sunDir = V4()
    var sunColor = V4()
    var world = V4()
    var grassOrigin = V4()
    var frustum0 = V4()
    var frustum1 = V4()
    var frustum2 = V4()
    var frustum3 = V4()
    var soilA = V4()
    var soilB = V4()
    var grassDry = V4()
    var biome = V4()
    var real = V4()
}

struct Camera {
    var eye: V3
    var yaw: Float
    var pitch: Float
    var fovY: Float = 60 * .pi / 180

    var forward: V3 { V3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)) }
}

struct RenderError: Error, CustomStringConvertible {
    let description: String
}

private struct GPUMesh {
    let vertices: MTLBuffer
    let indices: MTLBuffer
    let indexCount: Int
}

private struct TerrainChunk {
    let indexStart: Int
    let indexCount: Int
    let center: V3
    let radius: Float
}

private struct InstanceGPU {
    var a: V4
    var b: V4
    var c: V4
    var d: V4
}

// The people's meshes, textures and pose table. They are the same at every stop, so they are uploaded once.
private struct CastGPU {
    let meshes: [GPUMesh]
    let palette: MTLBuffer
    let colour: MTLTexture
    let normals: MTLTexture
    static var kept: CastGPU?
}

final class Renderer {
    static let shadowSize = 4096
    static let cascadeRadius: [Float] = [48, 420]
    static let grassRadius: Float = 70
    // Two grass grids: dense fine tufts underfoot, sparser coarse ones out to grassRadius.
    static let grassGrids: [(cell: Float, n: Int, fade: V4, blades: Int, levels: Int, spread: Float, width: Float)] = [
        (0.27, 128, V4(-1, 0, 17, 22), 12, 4, 0.2, 1),
        (0.5, 208, V4(15, 20, 49, 70), 6, 3, 0.36, 2.2),
    ]
    static let farShadowInterval = 6
    static let slots = 3
    // Development aid: NJIA_SKIP=grass,shadows,meshes,terrain leaves those out, to see what each costs.
    static let skip = Set((ProcessInfo.processInfo.environment["NJIA_SKIP"] ?? "").split(separator: ",").map(String.init))

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let world: World
    private let inflight = DispatchSemaphore(value: Renderer.slots)
    private var slot = 0

    private let skyLUTPipeline: MTLRenderPipelineState
    private let skyPipeline: MTLRenderPipelineState
    private let terrainPipeline: MTLRenderPipelineState
    private let meshPipeline: MTLRenderPipelineState
    private let grassPipeline: MTLRenderPipelineState
    private let waterPipeline: MTLRenderPipelineState
    private let terrainShadowPipeline: MTLRenderPipelineState
    private let meshShadowPipeline: MTLRenderPipelineState
    private let skinPipeline: MTLRenderPipelineState
    private let skinShadowPipeline: MTLRenderPipelineState
    private let postPipeline: MTLRenderPipelineState
    private let grassCompute: MTLComputePipelineState

    private let sceneDepth: MTLDepthStencilState
    private let skyDepth: MTLDepthStencilState
    private let shadowDepth: MTLDepthStencilState
    private let linearClamp: MTLSamplerState
    private let skySampler: MTLSamplerState
    private let shadowSampler: MTLSamplerState
    private let skinSampler: MTLSamplerState

    private let terrainVertices: MTLBuffer
    private let terrainIndices: MTLBuffer
    private var chunks: [TerrainChunk] = []
    private var skirt = TerrainChunk(indexStart: 0, indexCount: 0, center: V3(), radius: 0)
    private let outerVertices: MTLBuffer
    private let outerIndices: MTLBuffer
    private let outerIndexCount: Int
    private var horizonRing: (vertices: MTLBuffer, indices: MTLBuffer, count: Int)?

    private var meshes: [GPUMesh] = []
    private var cast: CastGPU?
    private var grassTufts: [GPUMesh] = []
    private var grassInstances: [MTLBuffer] = []
    private var grassParams: [[MTLBuffer]] = []       // [slot][grid]
    private var frameIndex = 0
    private var shadowVP = [matrix_identity_float4x4, matrix_identity_float4x4]
    private var lutHour: Float = -100
    private let dayOfYear = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 180
    var renderScale: Float = 1
    private let heightTexture: MTLTexture
    private let skyLUT: MTLTexture
    private let nearSat: MTLTexture
    private let farSat: MTLTexture
    private let mapMask: MTLTexture
    private let shadowMap: MTLTexture

    private var uniformBuffers: [[MTLBuffer]] = []    // [slot][main, cascade 0, cascade 1]
    private var instanceBuffers: [[MTLBuffer]] = []   // [slot][main, cascade 0, cascade 1]

    private var colorMS: MTLTexture?
    private var depthMS: MTLTexture?
    private var hdr: MTLTexture?

    init(device: MTLDevice, world: World, shaderSource: String, targetFormat: MTLPixelFormat) throws {
        self.device = device
        self.world = world
        guard let queue = device.makeCommandQueue() else { throw RenderError(description: "no command queue") }
        self.queue = queue
        let library = try device.makeLibrary(source: shaderSource, options: nil)

        let terrainVD = MTLVertexDescriptor()
        terrainVD.attributes[0].format = .float3
        terrainVD.attributes[1].format = .float3
        terrainVD.attributes[1].offset = 12
        terrainVD.layouts[0].stride = 24

        let meshVD = MTLVertexDescriptor()
        meshVD.attributes[0].format = .float3
        meshVD.attributes[1].format = .float3
        meshVD.attributes[1].offset = 12
        meshVD.attributes[2].format = .float2
        meshVD.attributes[2].offset = 24
        meshVD.attributes[3].format = .float4
        meshVD.attributes[3].offset = 32
        meshVD.layouts[0].stride = 48

        let skinVD = MTLVertexDescriptor()
        for (k, format) in [MTLVertexFormat.float3, .float3, .float2, .float4, .float4, .float4].enumerated() {
            skinVD.attributes[k].format = format
            skinVD.attributes[k].offset = [0, 12, 24, 32, 48, 64][k]
        }
        skinVD.layouts[0].stride = Cast.vertexFloats * 4

        func pipeline(_ vs: String, _ fs: String?, _ vd: MTLVertexDescriptor?, color: MTLPixelFormat,
                      depth: MTLPixelFormat, samples: Int = 1, alphaToCoverage: Bool = false) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.label = vs
            d.vertexFunction = library.makeFunction(name: vs)
            if let fs = fs { d.fragmentFunction = library.makeFunction(name: fs) }
            d.vertexDescriptor = vd
            d.colorAttachments[0].pixelFormat = color
            d.depthAttachmentPixelFormat = depth
            d.rasterSampleCount = samples
            d.isAlphaToCoverageEnabled = alphaToCoverage
            return try device.makeRenderPipelineState(descriptor: d)
        }

        skyLUTPipeline = try pipeline("quad_vs", "skylut_fs", nil, color: .rgba16Float, depth: .invalid)
        skyPipeline = try pipeline("quad_vs", "sky_fs", nil, color: .rgba16Float, depth: .depth32Float, samples: 4)
        terrainPipeline = try pipeline("terrain_vs", "terrain_fs", terrainVD, color: .rgba16Float, depth: .depth32Float, samples: 4)
        meshPipeline = try pipeline("mesh_vs", "mesh_fs", meshVD, color: .rgba16Float, depth: .depth32Float,
                                    samples: 4, alphaToCoverage: true)
        grassPipeline = try pipeline("grass_vs", "grass_fs", meshVD, color: .rgba16Float, depth: .depth32Float, samples: 4)
        waterPipeline = try pipeline("water_vs", "water_fs", nil, color: .rgba16Float, depth: .depth32Float, samples: 4)
        terrainShadowPipeline = try pipeline("terrain_shadow_vs", nil, terrainVD, color: .invalid, depth: .depth32Float)
        meshShadowPipeline = try pipeline("mesh_shadow_vs", "mesh_shadow_fs", meshVD, color: .invalid, depth: .depth32Float)
        skinPipeline = try pipeline("skin_vs", "skin_fs", skinVD, color: .rgba16Float, depth: .depth32Float, samples: 4, alphaToCoverage: true)
        skinShadowPipeline = try pipeline("skin_shadow_vs", "skin_shadow_fs", skinVD, color: .invalid, depth: .depth32Float)
        postPipeline = try pipeline("quad_vs", "post_fs", nil, color: targetFormat, depth: .invalid)
        guard let placeFn = library.makeFunction(name: "grass_place") else { throw RenderError(description: "grass_place missing") }
        grassCompute = try device.makeComputePipelineState(function: placeFn)

        func depthState(_ compare: MTLCompareFunction, write: Bool) throws -> MTLDepthStencilState {
            let d = MTLDepthStencilDescriptor()
            d.depthCompareFunction = compare
            d.isDepthWriteEnabled = write
            guard let s = device.makeDepthStencilState(descriptor: d) else { throw RenderError(description: "no depth state") }
            return s
        }
        sceneDepth = try depthState(.greater, write: true)
        skyDepth = try depthState(.greaterEqual, write: false)
        shadowDepth = try depthState(.lessEqual, write: true)

        func sampler(_ configure: (MTLSamplerDescriptor) -> Void) throws -> MTLSamplerState {
            let d = MTLSamplerDescriptor()
            d.minFilter = .linear
            d.magFilter = .linear
            configure(d)
            guard let s = device.makeSamplerState(descriptor: d) else { throw RenderError(description: "no sampler") }
            return s
        }
        linearClamp = try sampler { $0.mipFilter = .linear }
        skySampler = try sampler { $0.sAddressMode = .repeat }
        shadowSampler = try sampler { $0.compareFunction = .lessEqual }
        skinSampler = try sampler {
            $0.mipFilter = .linear
            $0.maxAnisotropy = 8
        }

        func buffer<T>(_ data: [T], _ label: String) throws -> MTLBuffer {
            guard let b = device.makeBuffer(bytes: data, length: MemoryLayout<T>.stride * data.count, options: .storageModeShared) else {
                throw RenderError(description: "could not allocate \(label)")
            }
            b.label = label
            return b
        }
        func upload(_ m: MeshData, _ label: String) throws -> GPUMesh {
            GPUMesh(vertices: try buffer(m.vertices, label), indices: try buffer(m.indices, label + " indices"),
                    indexCount: m.indices.count)
        }
        func texture(_ format: MTLPixelFormat, _ w: Int, _ h: Int, _ usage: MTLTextureUsage, _ configure: (MTLTextureDescriptor) -> Void = { _ in }) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
            d.usage = usage
            d.storageMode = .private
            configure(d)
            guard let t = device.makeTexture(descriptor: d) else { throw RenderError(description: "could not allocate texture") }
            return t
        }

        // Inner terrain: the walkable height field, split into chunks for culling, plus a skirt hiding its edge.
        let n = World.n
        var tv = [Float]()
        tv.reserveCapacity(n * n * 6 + n * 4 * 6)
        for j in 0..<n {
            for i in 0..<n {
                let x = -World.half + Float(i) * World.spacing, z = -World.half + Float(j) * World.spacing
                let h = world.heights[j * n + i]
                let hl = world.heights[j * n + max(i - 1, 0)], hr = world.heights[j * n + min(i + 1, n - 1)]
                let hd = world.heights[max(j - 1, 0) * n + i], hu = world.heights[min(j + 1, n - 1) * n + i]
                let nrm = normalize(V3(hl - hr, 2 * World.spacing, hd - hu))
                tv.append(contentsOf: [x, h, z, nrm.x, nrm.y, nrm.z])
            }
        }
        var ti = [UInt32]()
        ti.reserveCapacity((n - 1) * (n - 1) * 6 + n * 4 * 6)
        let chunkCells = 64
        for cj in stride(from: 0, to: n - 1, by: chunkCells) {
            for ci in stride(from: 0, to: n - 1, by: chunkCells) {
                let start = ti.count
                var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
                for j in cj..<cj + chunkCells {
                    for i in ci..<ci + chunkCells {
                        let a = UInt32(j * n + i), b = a + 1, c = a + UInt32(n), d = c + 1
                        ti.append(contentsOf: [a, c, b, b, c, d])
                        lo = min(lo, world.heights[j * n + i])
                        hi = max(hi, world.heights[j * n + i])
                    }
                }
                let size = Float(chunkCells) * World.spacing
                let center = V3(-World.half + Float(ci) * World.spacing + size / 2, (lo + hi) / 2,
                                -World.half + Float(cj) * World.spacing + size / 2)
                chunks.append(TerrainChunk(indexStart: start, indexCount: ti.count - start, center: center,
                                           radius: size * 0.7072 + (hi - lo) / 2 + 2))
            }
        }
        let skirtStart = ti.count
        var border: [Int] = []
        border += (0..<n).map { $0 }
        border += (0..<n).map { (n - 1) * n + $0 }
        border += (0..<n).map { $0 * n }
        border += (0..<n).map { $0 * n + n - 1 }
        for side in 0..<4 {
            let base = UInt32(tv.count / 6)
            for k in 0..<n {
                let v = border[side * n + k] * 6
                tv.append(contentsOf: [tv[v], tv[v + 1] - 60, tv[v + 2], tv[v + 3], tv[v + 4], tv[v + 5]])
            }
            for k in 0..<n - 1 {
                let a = UInt32(border[side * n + k]), b = UInt32(border[side * n + k + 1])
                let c = base + UInt32(k), d = c + 1
                ti.append(contentsOf: [a, c, b, b, c, d])
            }
        }
        skirt = TerrainChunk(indexStart: skirtStart, indexCount: ti.count - skirtStart, center: V3(), radius: 4000)
        terrainVertices = try buffer(tv, "terrain")
        terrainIndices = try buffer(ti, "terrain indices")

        // Coarser rings around the walkable square: 125 m posts to 16 km, then 1 km posts to the skyline.
        func ring(posts: Int, spacing: Float, hole: Float, drop: Float, step e: Float) throws -> (MTLBuffer, MTLBuffer, Int) {
            let half = spacing * Float(posts - 1) / 2
            var v = [Float]()
            v.reserveCapacity(posts * posts * 6)
            for j in 0..<posts {
                for i in 0..<posts {
                    let x = -half + Float(i) * spacing, z = -half + Float(j) * spacing
                    let nrm = normalize(V3(world.terrain(x - e, z) - world.terrain(x + e, z), 2 * e,
                                           world.terrain(x, z - e) - world.terrain(x, z + e)))
                    let inside = abs(x) < hole && abs(z) < hole
                    v.append(contentsOf: [x, world.terrain(x, z) - (inside ? drop : 0), z, nrm.x, nrm.y, nrm.z])
                }
            }
            var idx = [UInt32]()
            for j in 0..<posts - 1 {
                for i in 0..<posts - 1 {
                    let x0 = -half + Float(i) * spacing, z0 = -half + Float(j) * spacing
                    if x0 > -hole && x0 + spacing < hole && z0 > -hole && z0 + spacing < hole { continue }
                    let a = UInt32(j * posts + i), b = a + 1, c = a + UInt32(posts), d = c + 1
                    idx.append(contentsOf: [a, c, b, b, c, d])
                }
            }
            return (try buffer(v, "terrain ring"), try buffer(idx, "terrain ring indices"), idx.count)
        }
        (outerVertices, outerIndices, outerIndexCount) = try ring(posts: 257, spacing: 125, hole: World.half, drop: 3, step: 60)
        if world.real != nil {
            let h = try ring(posts: Geo.horizonN, spacing: Geo.horizonSpacing, hole: Geo.farHalf, drop: 150, step: 400)
            horizonRing = (h.0, h.1, h.2)
        }

        for seed in 0..<3 { meshes.append(try upload(makeAcacia(seed: UInt64(11 + seed * 7)), "acacia")) }
        for seed in 0..<2 { meshes.append(try upload(makeShrub(seed: UInt64(101 + seed * 5)), "shrub")) }
        for seed in 0..<2 { meshes.append(try upload(makeRock(seed: UInt64(201 + seed * 3)), "rock")) }
        meshes.append(try upload(makeLighthouse(), "lighthouse"))
        var placeholder = MeshData()
        for _ in 0..<3 { placeholder.add(V3(), V3(0, 1, 0), V2(), V4()) }
        placeholder.indices = [0, 1, 2]
        meshes.append(try upload(world.buildings ?? placeholder, "buildings"))
        meshes.append(try upload(makeStall(), "stall"))
        if CastGPU.kept == nil, let c = Cast.shared {
            func array(_ files: [String], size: Int, format: MTLPixelFormat) throws -> MTLTexture {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: size, height: size, mipmapped: true)
                d.textureType = .type2DArray
                d.arrayLength = max(files.count, 1)
                d.usage = .shaderRead
                guard let t = device.makeTexture(descriptor: d) else { throw RenderError(description: "could not allocate people textures") }
                var loaded = [[UInt8]?](repeating: nil, count: files.count)
                loaded.withUnsafeMutableBufferPointer { out in
                    let slots = UnsafeMutableBufferPointer(rebasing: out[...])
                    DispatchQueue.concurrentPerform(iterations: files.count) { k in slots[k] = Cast.pixels(files[k], size: size) }
                }
                for (k, px) in loaded.enumerated() {
                    guard let px = px else { continue }
                    px.withUnsafeBytes {
                        t.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0, slice: k, withBytes: $0.baseAddress!,
                                  bytesPerRow: size * 4, bytesPerImage: 0)
                    }
                }
                return t
            }
            let colour = try array(c.colourFiles, size: 1024, format: .rgba8Unorm_srgb)
            let normals = try array(c.normalFiles, size: 512, format: .rgba8Unorm)
            if let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() {
                blit.generateMipmaps(for: colour)
                blit.generateMipmaps(for: normals)
                blit.endEncoding()
                cb.commit()
            }
            CastGPU.kept = CastGPU(meshes: try c.avatars.map { GPUMesh(vertices: try buffer($0.vertices, "person"), indices: try buffer($0.indices, "person indices"),
                                                                      indexCount: $0.indices.count) },
                                   palette: try buffer(c.palette, "poses"), colour: colour, normals: normals)
        }
        cast = CastGPU.kept
        for (k, g) in Renderer.grassGrids.enumerated() {
            grassTufts.append(try upload(makeGrassTuft(seed: UInt64(5 + k), blades: g.blades, levels: g.levels,
                                                       spread: g.spread, widthScale: g.width), "grass tuft"))
            guard let gi = device.makeBuffer(length: g.n * g.n * 48, options: .storageModePrivate) else {
                throw RenderError(description: "could not allocate grass instances")
            }
            grassInstances.append(gi)
        }

        let heightMap = try texture(.r32Float, n, n, .shaderRead) { $0.storageMode = .shared }
        world.heights.withUnsafeBytes {
            heightMap.replace(region: MTLRegionMake2D(0, 0, n, n), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: n * 4)
        }
        heightTexture = heightMap
        skyLUT = try texture(.rgba16Float, 256, 128, [.renderTarget, .shaderRead])

        // Satellite imagery for stages that have it; a single grey texel otherwise.
        func satellite(_ rgba: [UInt8]?) throws -> MTLTexture {
            let size = rgba == nil ? 1 : Geo.imageSize
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: size, height: size, mipmapped: size > 1)
            d.usage = .shaderRead
            guard let t = device.makeTexture(descriptor: d) else { throw RenderError(description: "could not allocate imagery") }
            (rgba ?? [128, 128, 128, 255]).withUnsafeBytes {
                t.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: size * 4)
            }
            return t
        }
        let near = try satellite(world.real?.nearRGBA), far = try satellite(world.real?.farRGBA)
        if world.real != nil, let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: near)
            blit.generateMipmaps(for: far)
            blit.endEncoding()
            cb.commit()
        }
        nearSat = near
        farSat = far
        let maskSize = world.mask == nil ? 1 : Geo.imageSize
        let md = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: maskSize, height: maskSize, mipmapped: false)
        md.usage = .shaderRead
        guard let mt = device.makeTexture(descriptor: md) else { throw RenderError(description: "could not allocate map mask") }
        (world.mask ?? [0, 0, 0, 0]).withUnsafeBytes {
            mt.replace(region: MTLRegionMake2D(0, 0, maskSize, maskSize), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: maskSize * 4)
        }
        mapMask = mt
        shadowMap = try texture(.depth32Float, Renderer.shadowSize, Renderer.shadowSize, [.renderTarget, .shaderRead]) {
            $0.textureType = .type2DArray
            $0.arrayLength = 2
        }

        let instanceBytes = max(world.instances.count + world.people.count, 1) * MemoryLayout<InstanceGPU>.stride
        for _ in 0..<Renderer.slots {
            var ub: [MTLBuffer] = [], ib: [MTLBuffer] = []
            for _ in 0..<3 {
                guard let u = device.makeBuffer(length: MemoryLayout<Uniforms>.stride, options: .storageModeShared),
                      let i = device.makeBuffer(length: instanceBytes, options: .storageModeShared) else {
                    throw RenderError(description: "could not allocate frame buffers")
                }
                ub.append(u)
                ib.append(i)
            }
            uniformBuffers.append(ub)
            instanceBuffers.append(ib)
            grassParams.append(try Renderer.grassGrids.map { _ in
                guard let b = device.makeBuffer(length: 32, options: .storageModeShared) else {
                    throw RenderError(description: "could not allocate grass params")
                }
                return b
            })
        }
    }

    // Sunlight reaching the ground: the atmosphere model in Shaders.metal, integrated along the sun ray.
    static func sunIrradiance(_ dir: V3) -> V3 {
        let rP = 6371e3, rA = 6471e3
        let dy = Double(max(dir.y, 0.0))
        let o = rP + 100
        let b = 2 * o * dy
        let c = o * o - rA * rA
        let tEnd = (-b + (b * b - 4 * c).squareRoot()) / 2
        let steps = 48
        var odR = 0.0, odM = 0.0
        for i in 0..<steps {
            let t = (Double(i) + 0.5) / Double(steps) * tEnd
            let h = (o * o + t * t + 2 * o * t * dy).squareRoot() - rP
            odR += exp(-h / 8000) * tEnd / Double(steps)
            odM += exp(-h / 1200) * tEnd / Double(steps)
        }
        let beta = SIMD3<Double>(5.5e-6, 13.0e-6, 22.4e-6)
        let tr = SIMD3<Double>(exp(-(beta.x * odR + 21e-6 * odM)), exp(-(beta.y * odR + 21e-6 * odM)), exp(-(beta.z * odR + 21e-6 * odM)))
        return V3(Float(tr.x), Float(tr.y), Float(tr.z)) * 22
    }

    private func ensureTargets(_ w: Int, _ h: Int) {
        if let c = colorMS, c.width == w, c.height == h { return }
        func make(_ format: MTLPixelFormat, samples: Int, usage: MTLTextureUsage) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
            d.usage = usage
            d.storageMode = .private
            if samples > 1 {
                d.textureType = .type2DMultisample
                d.sampleCount = samples
            }
            return device.makeTexture(descriptor: d)
        }
        colorMS = make(.rgba16Float, samples: 4, usage: .renderTarget)
        depthMS = make(.depth32Float, samples: 4, usage: .renderTarget)
        hdr = make(.rgba16Float, samples: 1, usage: [.renderTarget, .shaderRead])
    }

    // Encodes one frame into `target`. The caller presents (if needed) and commits the returned buffer.
    func render(to target: MTLTexture, camera cam: Camera, time: Float, hour: Float) -> MTLCommandBuffer? {
        inflight.wait()
        guard let cb = queue.makeCommandBuffer() else {
            inflight.signal()
            return nil
        }
        cb.addCompletedHandler { [inflight] _ in inflight.signal() }
        slot = (slot + 1) % Renderer.slots
        let scale = min(max(renderScale, 0.4), 1)
        ensureTargets(max(Int(Float(target.width) * scale), 16), max(Int(Float(target.height) * scale), 16))
        frameIndex += 1
        guard let colorMS = colorMS, let depthMS = depthMS, let hdr = hdr else { return cb }

        // Camera.
        let fwd = cam.forward
        let right = normalize(cross(fwd, V3(0, 1, 0)))
        let up = cross(right, fwd)
        let aspect = Float(target.width) / Float(target.height)
        let tanY = tan(cam.fovY / 2)
        let viewProj = perspectiveReversedZ(fovY: cam.fovY, aspect: aspect, near: 0.15, far: 180_000)
            * lookAt(eye: cam.eye, center: cam.eye + fwd, up: V3(0, 1, 0))

        func row(_ m: M4, _ i: Int) -> V4 { V4(m.columns.0[i], m.columns.1[i], m.columns.2[i], m.columns.3[i]) }
        let r0 = row(viewProj, 0), r1 = row(viewProj, 1), r3 = row(viewProj, 3)
        let planes = [r3 + r0, r3 - r0, r3 + r1, r3 - r1].map { $0 / length(V3($0.x, $0.y, $0.z)) }

        // Sun and shadow cascades.
        let sun = Route.sunDirection(lat: world.stage.lat, dayOfYear: dayOfYear, hour: hour)
        let lightView = lookAt(eye: sun * 100, center: V3(), up: V3(0, 1, 0))
        let flat = normalize(V3(sin(cam.yaw), 0, cos(cam.yaw)))
        let cascadeCenter = [cam.eye + flat * 30, cam.eye + flat * 250]
        let cascadeDepth: [Float] = [140, 460]
        // The far cascade is only redrawn every few frames; it keeps the matrix it was drawn with.
        let drawCascade = [true, frameIndex % Renderer.farShadowInterval == 1]
        for c in 0..<2 where drawCascade[c] {
            let r = Renderer.cascadeRadius[c]
            let texel = 2 * r / Float(Renderer.shadowSize)
            var ls = lightView * V4(cascadeCenter[c], 1)
            ls.x = (ls.x / texel).rounded() * texel
            ls.y = (ls.y / texel).rounded() * texel
            shadowVP[c] = ortho(l: ls.x - r, r: ls.x + r, b: ls.y - r, t: ls.y + r,
                                near: -ls.z - cascadeDepth[c], far: -ls.z + cascadeDepth[c]) * lightView
        }

        // Grass grids: centred ahead of the camera so most of each lands in view.
        for (k, g) in Renderer.grassGrids.enumerated() {
            let gc = V2(cam.eye.x, cam.eye.z) + V2(flat.x, flat.z) * (g.fade.w * 0.5)
            let origin = V2((gc.x / g.cell).rounded(.down), (gc.y / g.cell).rounded(.down)) - V2(repeating: Float(g.n / 2))
            var params = (V4(origin.x, origin.y, g.cell, Float(g.n)), g.fade)
            grassParams[slot][k].contents().copyMemory(from: &params, byteCount: 32)
        }

        let elevation = max(sun.y, 0)
        var u = Uniforms()
        u.viewProj = viewProj
        u.shadowVP0 = shadowVP[0]
        u.shadowVP1 = shadowVP[1]
        u.camPos = V4(cam.eye, time)
        u.camRight = V4(right * tanY * aspect, 0)
        u.camUp = V4(up * tanY, 0)
        u.camFwd = V4(fwd, 0)
        u.sunDir = V4(sun, 0)
        u.sunColor = V4(Renderer.sunIrradiance(sun), 0.70 / (0.55 + 2.2 * elevation))
        u.world = V4(World.half, Renderer.grassRadius, 0, 0)
        let biome = world.stage.biome
        u.grassOrigin = V4(0, 0, biome.haze, 0)
        u.soilA = V4(biome.soilA, 0)
        u.soilB = V4(biome.soilB, 0)
        u.grassDry = V4(biome.grassDry, 0)
        u.biome = V4(biome.grassCover, biome.grassHeight, biome.green, biome.clouds)
        u.real = V4(world.real == nil ? 0 : 1, world.seaLevel, biome.bareAbove, 0)
        u.frustum0 = planes[0]
        u.frustum1 = planes[1]
        u.frustum2 = planes[2]
        u.frustum3 = planes[3]

        let ub = uniformBuffers[slot]
        for pass in 0..<3 {
            var copy = u
            if pass > 0 { copy.viewProj = shadowVP[pass - 1] }
            ub[pass].contents().copyMemory(from: &copy, byteCount: MemoryLayout<Uniforms>.stride)
        }

        // Cull instances into per-pass, per-mesh runs.
        let castCount = cast?.meshes.count ?? 0
        var lists = [[[InstanceGPU]]](repeating: [[InstanceGPU]](repeating: [], count: World.meshCount + castCount), count: 3)
        func place(_ inst: Instance) {
            let gpu = InstanceGPU(a: V4(inst.pos, inst.scale), b: V4(cos(inst.yaw), sin(inst.yaw), inst.seed, 0), c: inst.anim, d: inst.look)
            let center = inst.pos + V3(0, inst.boundRadius * 0.5, 0)
            if distance(center, cam.eye) < inst.maxDistance {
                var visible = true
                for p in planes where dot(V3(p.x, p.y, p.z), center) + p.w < -inst.boundRadius { visible = false }
                if visible { lists[0][inst.mesh].append(gpu) }
            }
            for c in 0..<2 where drawCascade[c] {
                let d = V2(center.x - cascadeCenter[c].x, center.z - cascadeCenter[c].z)
                if length(d) < Renderer.cascadeRadius[c] * 1.45 + inst.boundRadius + (c == 0 ? 60 : 0) {
                    lists[c + 1][inst.mesh].append(gpu)
                }
            }
        }
        for inst in world.instances { place(inst) }
        if castCount > 0 {
            for var inst in world.peopleInstances {
                inst.mesh += World.meshCount   // people follow the fixed meshes in the instance buffer
                place(inst)
            }
        }
        var runs = [[(offset: Int, count: Int)]](repeating: [], count: 3)
        for pass in 0..<3 {
            let dst = instanceBuffers[slot][pass].contents().bindMemory(to: InstanceGPU.self, capacity: world.instances.count + world.people.count)
            var offset = 0
            for m in 0..<World.meshCount + castCount {
                let list = lists[pass][m]
                for (k, g) in list.enumerated() { dst[offset + k] = g }
                runs[pass].append((offset, list.count))
                offset += list.count
            }
        }

        func drawMeshes(_ enc: MTLRenderCommandEncoder, pass: Int) {
            for m in 0..<World.meshCount where runs[pass][m].count > 0 {
                let mesh = meshes[m]
                enc.setVertexBuffer(mesh.vertices, offset: 0, index: 0)
                enc.setVertexBuffer(instanceBuffers[slot][pass], offset: runs[pass][m].offset * MemoryLayout<InstanceGPU>.stride, index: 2)
                enc.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indexCount, indexType: .uint32,
                                          indexBuffer: mesh.indices, indexBufferOffset: 0, instanceCount: runs[pass][m].count)
            }
        }
        func drawPeople(_ enc: MTLRenderCommandEncoder, pass: Int) {
            guard let cast = cast else { return }
            enc.setVertexBuffer(cast.palette, offset: 0, index: 3)
            enc.setFragmentTexture(cast.colour, index: 6)
            enc.setFragmentTexture(cast.normals, index: 7)
            enc.setFragmentSamplerState(skinSampler, index: 3)
            for (k, mesh) in cast.meshes.enumerated() where runs[pass][World.meshCount + k].count > 0 {
                let run = runs[pass][World.meshCount + k]
                enc.setVertexBuffer(mesh.vertices, offset: 0, index: 0)
                enc.setVertexBuffer(instanceBuffers[slot][pass], offset: run.offset * MemoryLayout<InstanceGPU>.stride, index: 2)
                enc.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indexCount, indexType: .uint32,
                                          indexBuffer: mesh.indices, indexBufferOffset: 0, instanceCount: run.count)
            }
        }
        func drawChunk(_ enc: MTLRenderCommandEncoder, _ chunk: TerrainChunk) {
            enc.drawIndexedPrimitives(type: .triangle, indexCount: chunk.indexCount, indexType: .uint32,
                                      indexBuffer: terrainIndices, indexBufferOffset: chunk.indexStart * 4)
        }

        // 1. Sky lookup texture.
        let lutPass = MTLRenderPassDescriptor()
        lutPass.colorAttachments[0].texture = skyLUT
        lutPass.colorAttachments[0].loadAction = .dontCare
        lutPass.colorAttachments[0].storeAction = .store
        if abs(hour - lutHour) > 0.0005, let enc = cb.makeRenderCommandEncoder(descriptor: lutPass) {
            lutHour = hour
            enc.setRenderPipelineState(skyLUTPipeline)
            enc.setFragmentBuffer(ub[0], offset: 0, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }

        // 2. Shadow cascades.
        for c in 0..<2 where drawCascade[c] {
            let sp = MTLRenderPassDescriptor()
            sp.depthAttachment.texture = shadowMap
            sp.depthAttachment.slice = c
            sp.depthAttachment.loadAction = .clear
            sp.depthAttachment.clearDepth = 1
            sp.depthAttachment.storeAction = .store
            guard let enc = cb.makeRenderCommandEncoder(descriptor: sp) else { continue }
            enc.setDepthStencilState(shadowDepth)
            enc.setCullMode(.none)
            enc.setVertexBuffer(ub[c + 1], offset: 0, index: 1)
            if Renderer.skip.contains("shadows") {
                enc.endEncoding()
                continue
            }
            enc.setRenderPipelineState(terrainShadowPipeline)
            enc.setVertexBuffer(terrainVertices, offset: 0, index: 0)
            let reach = Renderer.cascadeRadius[c] * 1.45 + (c == 0 ? 250 : 150)
            for chunk in chunks {
                let d = V2(chunk.center.x - cascadeCenter[c].x, chunk.center.z - cascadeCenter[c].z)
                if length(d) < reach + chunk.radius { drawChunk(enc, chunk) }
            }
            enc.setRenderPipelineState(meshShadowPipeline)
            drawMeshes(enc, pass: c + 1)
            enc.setRenderPipelineState(skinShadowPipeline)
            drawPeople(enc, pass: c + 1)
            enc.endEncoding()
        }

        // 3. Place grass tufts around the camera.
        if let enc = cb.makeComputeCommandEncoder() {
            enc.setComputePipelineState(grassCompute)
            enc.setBuffer(ub[0], offset: 0, index: 0)
            enc.setTexture(heightTexture, index: 0)
            enc.setTexture(shadowMap, index: 1)
            enc.setTexture(nearSat, index: 2)
            enc.setTexture(mapMask, index: 3)
            enc.setSamplerState(linearClamp, index: 0)
            enc.setSamplerState(shadowSampler, index: 1)
            let w = grassCompute.threadExecutionWidth
            let h = max(1, grassCompute.maxTotalThreadsPerThreadgroup / w)
            for (k, g) in Renderer.grassGrids.enumerated() {
                enc.setBuffer(grassInstances[k], offset: 0, index: 1)
                enc.setBuffer(grassParams[slot][k], offset: 0, index: 2)
                enc.dispatchThreads(MTLSize(width: g.n, height: g.n, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
            }
            enc.endEncoding()
        }

        // 4. Scene, HDR with 4x MSAA.
        let scene = MTLRenderPassDescriptor()
        scene.colorAttachments[0].texture = colorMS
        scene.colorAttachments[0].resolveTexture = hdr
        scene.colorAttachments[0].loadAction = .clear
        scene.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        scene.colorAttachments[0].storeAction = .multisampleResolve
        scene.depthAttachment.texture = depthMS
        scene.depthAttachment.loadAction = .clear
        scene.depthAttachment.clearDepth = 0
        scene.depthAttachment.storeAction = .dontCare
        if let enc = cb.makeRenderCommandEncoder(descriptor: scene) {
            enc.setCullMode(.none)
            enc.setVertexBuffer(ub[0], offset: 0, index: 1)
            enc.setFragmentBuffer(ub[0], offset: 0, index: 1)
            enc.setFragmentTexture(skyLUT, index: 0)
            enc.setFragmentTexture(shadowMap, index: 1)
            enc.setFragmentSamplerState(skySampler, index: 0)
            enc.setFragmentSamplerState(shadowSampler, index: 1)
            enc.setFragmentSamplerState(linearClamp, index: 2)
            enc.setFragmentTexture(nearSat, index: 2)
            enc.setFragmentTexture(farSat, index: 3)
            enc.setFragmentTexture(heightTexture, index: 4)
            enc.setFragmentTexture(mapMask, index: 5)
            enc.setDepthStencilState(sceneDepth)

            enc.setRenderPipelineState(terrainPipeline)
            enc.setVertexBuffer(terrainVertices, offset: 0, index: 0)
            for chunk in chunks where !Renderer.skip.contains("terrain") {
                var visible = true
                for p in planes where dot(V3(p.x, p.y, p.z), chunk.center) + p.w < -chunk.radius { visible = false }
                if visible { drawChunk(enc, chunk) }
            }
            drawChunk(enc, skirt)
            enc.setVertexBuffer(outerVertices, offset: 0, index: 0)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: outerIndexCount, indexType: .uint32,
                                      indexBuffer: outerIndices, indexBufferOffset: 0)
            if let h = horizonRing {
                enc.setVertexBuffer(h.vertices, offset: 0, index: 0)
                enc.drawIndexedPrimitives(type: .triangle, indexCount: h.count, indexType: .uint32, indexBuffer: h.indices, indexBufferOffset: 0)
            }

            enc.setRenderPipelineState(meshPipeline)
            if !Renderer.skip.contains("meshes") { drawMeshes(enc, pass: 0) }
            enc.setRenderPipelineState(skinPipeline)
            if !Renderer.skip.contains("people") { drawPeople(enc, pass: 0) }

            enc.setRenderPipelineState(grassPipeline)
            for (k, g) in Renderer.grassGrids.enumerated() where !Renderer.skip.contains("grass") {
                enc.setVertexBuffer(grassTufts[k].vertices, offset: 0, index: 0)
                enc.setVertexBuffer(grassInstances[k], offset: 0, index: 2)
                enc.drawIndexedPrimitives(type: .triangle, indexCount: grassTufts[k].indexCount, indexType: .uint32,
                                          indexBuffer: grassTufts[k].indices, indexBufferOffset: 0, instanceCount: g.n * g.n)
            }

            if world.real != nil {
                enc.setRenderPipelineState(waterPipeline)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            }

            enc.setRenderPipelineState(skyPipeline)
            enc.setDepthStencilState(skyDepth)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }

        // 5. Tone map into the target.
        let post = MTLRenderPassDescriptor()
        post.colorAttachments[0].texture = target
        post.colorAttachments[0].loadAction = .dontCare
        post.colorAttachments[0].storeAction = .store
        if let enc = cb.makeRenderCommandEncoder(descriptor: post) {
            enc.setRenderPipelineState(postPipeline)
            enc.setFragmentBuffer(ub[0], offset: 0, index: 1)
            enc.setFragmentTexture(hdr, index: 0)
            enc.setFragmentSamplerState(linearClamp, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
        return cb
    }
}
