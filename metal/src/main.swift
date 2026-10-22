// Njia: a walk through an East African savanna.
//   Njia                        run the game
//   Njia --shot out.png [--stage i] [--hour h] [--pos x z] [--yaw deg] [--pitch deg] [--eye m] [--size w h] [--person n --dist d]
//                               [--lineup [--row r] [--tone t]]
//                               render one frame to a PNG and exit
//   Njia --audio-test           render the sound synth offline and print its levels
//   Njia --bake <n|all> <dir>   download real elevation, imagery and OpenStreetMap data into <dir>/stages
//   Njia --verify <dir>         cross-check the baked data against independent sources
import AppKit
import ImageIO
import MetalKit

func loadShaderSource() -> String? {
    let candidates = [Bundle.main.resourcePath.map { $0 + "/Shaders.metal" },
                      CommandLine.arguments.first.map { ($0 as NSString).deletingLastPathComponent + "/../Resources/Shaders.metal" }]
    for path in candidates.compactMap({ $0 }) {
        if let s = try? String(contentsOfFile: path, encoding: .utf8) { return s }
    }
    return nil
}

func renderShot(args: [String]) -> Int32 {
    func values(_ flag: String, _ count: Int) -> [Float]? {
        guard let i = args.firstIndex(of: flag), i + count < args.count else { return nil }
        let v = args[(i + 1)...(i + count)].compactMap { Float($0) }
        return v.count == count ? v : nil
    }
    guard let i = args.firstIndex(of: "--shot"), i + 1 < args.count else { return 2 }
    let out = args[i + 1]
    guard let device = MTLCreateSystemDefaultDevice(), let source = loadShaderSource() else {
        print("no Metal device or shader source")
        return 1
    }
    let size = values("--size", 2) ?? [1600, 900]
    let width = Int(size[0]), height = Int(size[1])
    let world = World(stageIndex: Int(values("--stage", 1)?[0] ?? 10))
    do {
        let renderer = try Renderer(device: device, world: world, shaderSource: source, targetFormat: .bgra8Unorm_srgb)
        let player = Player(world: world)
        if let p = values("--pos", 2) { player.pos = V3(p[0], world.height(p[0], p[1]), p[1]) }
        if let y = values("--yaw", 1) { player.yaw = y[0] * .pi / 180 }
        if let p = values("--pitch", 1) { player.pitch = p[0] * .pi / 180 }
        if let t = values("--tree", 1), let inst = world.instances.filter({ $0.mesh == Int(t[0]) }).first {
            let d = values("--dist", 1)?[0] ?? 12
            player.pos = V3(inst.pos.x + d * 0.7, world.height(inst.pos.x + d * 0.7, inst.pos.z + d * 0.7), inst.pos.z + d * 0.7)
            player.yaw = atan2(-1, -1)
        }
        var camera = player.camera
        if let e = values("--eye", 1) { camera.eye.y += e[0] }
        for _ in 0..<80 { world.update(dt: 0.05, walker: V2(1e6, 1e6)) }   // let the people get into their stride
        if args.contains("--lineup") {
            world.lineUp(tone: values("--tone", 1)?[0], row: Int(values("--row", 1)?[0] ?? 0), turned: args.contains("--turned"))
            let d = values("--dist", 1)?[0] ?? 7
            camera = Camera(eye: V3(world.spawn.x, world.height(world.spawn.x, world.spawn.y) + 1.3, world.spawn.y + d), yaw: .pi, pitch: -0.05)
        }
        if args.contains("--pair"), let p = world.people.first(where: { $0.chat != nil }) {
            // Stand to one side of two people talking.
            let d = values("--dist", 1)?[0] ?? 3.5
            let mid = p.pos + V2(sin(p.yaw), cos(p.yaw)) * 0.55, at = mid + V2(cos(p.yaw), -sin(p.yaw)) * d
            camera = Camera(eye: V3(at.x, world.height(mid.x, mid.y) + 1.45, at.y), yaw: atan2(mid.x - at.x, mid.y - at.y), pitch: -0.08)
        }
        if let n = values("--person", 1), Int(n[0]) < world.people.count {
            // Stand in front of one of the people and look at them.
            let p = world.people[Int(n[0])], d = values("--dist", 1)?[0] ?? 3
            let at = p.pos + V2(sin(p.yaw), cos(p.yaw)) * d
            camera = Camera(eye: V3(at.x, world.height(p.pos.x, p.pos.y) + 1.45, at.y), yaw: p.yaw + .pi, pitch: -0.08)
        }

        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        guard let target = device.makeTexture(descriptor: d) else { return 1 }
        var gpuMs = 0.0
        let frames = 13   // two far-shadow intervals; the first frame warms up and is not timed
        for f in 0..<frames {
            guard let cb = renderer.render(to: target, camera: camera, time: 12, hour: values("--hour", 1)?[0] ?? 16.4) else { return 1 }
            cb.commit()
            cb.waitUntilCompleted()
            if let e = cb.error { print("GPU error: \(e)") }
            if f > 0 { gpuMs += (cb.gpuEndTime - cb.gpuStartTime) * 1000 / Double(frames - 1) }
        }

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info, provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, "public.png" as CFString, 1, nil) else { return 1 }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return 1 }
        print(String(format: "wrote %@ · %d×%d · GPU %.1f ms · %d instances · %d people · ground lowered up to %.0f m under buildings",
                     out, width, height, gpuMs, world.instances.count, world.people.count, world.levelled))
        return 0
    } catch {
        print("renderer failed: \(error)")
        return 1
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var view: GameView?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit Njia", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        menu.addItem(appItem)
        NSApp.mainMenu = menu

        guard let device = MTLCreateSystemDefaultDevice(), let source = loadShaderSource() else {
            log.line("no Metal device or shader source")
            NSApp.terminate(nil)
            return
        }
        let t0 = CACurrentMediaTime()
        let rect = NSRect(x: 0, y: 0, width: 1280, height: 800)
        let view: GameView
        do {
            view = try GameView(frame: rect, device: device, shaderSource: source,
                                stageIndex: UserDefaults.standard.integer(forKey: "stage"))
        } catch {
            log.line("renderer failed: \(error)")
            NSApp.terminate(nil)
            return
        }
        log.line(String(format: "world ready in %.2f s · stage %d · %@", CACurrentMediaTime() - t0, view.stageIndex + 1, device.name))

        let journeyItem = NSMenuItem()
        let journeyMenu = NSMenu(title: "Journey")
        for (i, s) in Route.stages.enumerated() {
            let item = NSMenuItem(title: "\(i + 1). \(s.name), \(s.country)", action: #selector(selectStage(_:)), keyEquivalent: "")
            item.tag = i
            item.target = self
            journeyMenu.addItem(item)
        }
        journeyItem.submenu = journeyMenu
        menu.addItem(journeyItem)

        let window = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Njia"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = view
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior = [.fullScreenPrimary]
        window.center()
        window.makeFirstResponder(view)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
        self.view = view
        log.line("window up; macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
    }

    @objc func selectStage(_ sender: NSMenuItem) {
        view?.travel(to: sender.tag)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func windowDidResignKey(_ notification: Notification) {
        view?.releaseInput()
    }

    func windowWillClose(_ notification: Notification) {
        view?.releaseInput()
        log.line("windowWillClose")
    }
}

if CommandLine.arguments.contains("--verify") {
    exit(verifyStages(args: CommandLine.arguments))
}
if CommandLine.arguments.contains("--probe") {
    // Njia --probe <stage> <x> <z>: what the terrain data says at one spot.
    let a = CommandLine.arguments, i = a.firstIndex(of: "--probe")!
    let w = World(stageIndex: Int(a[i + 1]) ?? 0)
    print(w.describe(Float(a[i + 2]) ?? 0, Float(a[i + 3]) ?? 0))
    exit(0)
}
if CommandLine.arguments.contains("--talk") {
    // Njia --talk <stage>: what the first person met at a stop says.
    let a = CommandLine.arguments, i = a.firstIndex(of: "--talk")!
    let w = World(stageIndex: Int(a[i + 1]) ?? 0)
    print(w.people.last.flatMap { w.greeting(near: $0.pos) } ?? "nobody here")
    exit(0)
}
if CommandLine.arguments.contains("--bake") {
    exit(bakeStages(args: CommandLine.arguments))
}
if CommandLine.arguments.contains("--audio-test") {
    exit(audioSelfTest())
}
if CommandLine.arguments.contains("--shot") {
    exit(renderShot(args: CommandLine.arguments))
}

log.line("starting")
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
