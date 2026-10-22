// Player movement, input and the game view.
import AppKit
import MetalKit
import simd

final class DiagLog {
    private let handle: FileHandle?

    init() {
        var h: FileHandle?
        if let res = Bundle.main.resourcePath,
           let raw = try? String(contentsOfFile: res + "/diagnostics.path", encoding: .utf8) {
            let dir = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let path = dir + "/njia.log"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil)
            }
            h = FileHandle(forWritingAtPath: path)
            h?.seekToEndOfFile()
        }
        handle = h
    }

    func line(_ s: String) {
        handle?.write(Data((s + "\n").utf8))
    }
}

let log = DiagLog()

final class Player {
    static let eyeHeight: Float = 1.68
    static let walkSpeed: Float = 1.7
    static let runSpeed: Float = 5.4

    var pos: V3
    var yaw: Float
    var pitch: Float = 0
    private var vel = V2()
    private var vy: Float = 0
    var walkSpeed = Player.walkSpeed   // set from the current mode of transport
    var runSpeed = Player.runSpeed
    private var bob: Float = 0
    private(set) var steps = 0
    private(set) var running = false
    // Fly mode: the camera leaves the ground and goes anywhere, through anything. `pos` is then the eye itself.
    private(set) var flying = false
    var flySpeed: Float = 40

    static let startZ: Float = -900
    static let endZ: Float = 920

    // Each stage is walked south to north along its path.
    init(world: World) {
        let p = world.spawn
        pos = V3(p.x, world.height(p.x, p.y), p.y)
        yaw = world.real != nil ? 0 : atan2(pathX(p.y + 6) - p.x, 6)
    }

    // Whether the walker has reached the way out of this stage.
    func atExit(_ world: World) -> Bool {
        world.real != nil ? simd_distance(V2(pos.x, pos.z), world.exit) < 60 : pos.z > Player.endZ
    }

    var camera: Camera {
        let speed = min(length(vel) / Player.walkSpeed, 1.6)
        let lift = -abs(sin(bob)) * 0.035 * speed
        return Camera(eye: flying ? pos : pos + V3(0, Player.eyeHeight + lift, 0), yaw: yaw, pitch: pitch)
    }

    private func groundHeight(_ world: World, _ x: Float, _ z: Float) -> Float {
        max(abs(x), abs(z)) < World.half ? world.height(x, z) : world.terrain(x, z)
    }

    // Takes off, or comes back down. Landing needs dry ground inside the walkable square; returns why not otherwise.
    func toggleFlying(_ world: World) -> String {
        if !flying {
            flying = true
            pos.y += Player.eyeHeight + 3
            return "Flying. WASD moves where you look, Space up, C down, Shift fast, scroll to change speed, G to land."
        }
        if max(abs(pos.x), abs(pos.z)) > World.walkLimit { return "Fly back over the stop itself to land." }
        if world.real != nil && world.height(pos.x, pos.z) < world.seaLevel - 0.5 { return "That is water. Fly over land to come down." }
        let p = world.footprints.resolve(V2(pos.x, pos.z), margin: 0.4)
        pos = V3(p.x, world.height(p.x, p.y), p.y)
        pitch = max(pitch, -0.3)
        flying = false
        vel = V2()
        vy = 0
        return "On foot again."
    }

    func fly(dt: Float, move: V2, rise: Float, fast: Bool, world: World) {
        let fwd = V3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)), right = V3(-cos(yaw), 0, sin(yaw))
        var wish = fwd * move.y + right * move.x + V3(0, rise, 0)
        if length(wish) > 1 { wish = normalize(wish) }
        pos += wish * flySpeed * (fast ? 6 : 1) * dt
        pos.x = min(max(pos.x, -120_000), 120_000)
        pos.z = min(max(pos.z, -120_000), 120_000)
        pos.y = min(max(pos.y, groundHeight(world, pos.x, pos.z) + 0.6), 30_000)
    }

    func update(dt: Float, move: V2, run: Bool, jump: Bool, world: World) {
        let fwd = V2(sin(yaw), cos(yaw)), right = V2(-cos(yaw), sin(yaw))
        var wish = fwd * move.y + right * move.x
        if length(wish) > 1 { wish = normalize(wish) }
        vel += (wish * (run ? runSpeed : walkSpeed) - vel) * min(1, dt * 9)

        var p = V2(pos.x, pos.z) + vel * dt
        for c in world.colliders {
            let d = p - V2(c.x, c.y)
            if abs(d.x) > 6 || abs(d.y) > 6 { continue }
            let dist = length(d), reach = c.z + 0.3
            if dist < reach && dist > 1e-4 { p = V2(c.x, c.y) + d / dist * reach }
        }
        p = world.footprints.resolve(p, margin: 0.35)
        p = simd_clamp(p, V2(repeating: -World.walkLimit), V2(repeating: World.walkLimit))
        if world.real != nil && world.height(p.x, p.y) < world.seaLevel - 0.7 { p = V2(pos.x, pos.z) }   // no wading out to sea

        let ground = world.height(p.x, p.y)
        let grounded = pos.y - ground < 0.25 && vy <= 0
        if grounded {
            pos.y = ground
            vy = jump ? 3.6 : 0
            let before = Int(bob / .pi)
            bob += length(vel) * dt / 0.75 * .pi
            if Int(bob / .pi) != before { steps += 1 }
            running = run && length(vel) > Player.walkSpeed * 1.3
        } else {
            vy -= 9.8 * dt
            pos.y = max(ground, pos.y + vy * dt)
        }
        pos.x = p.x
        pos.z = p.y
    }
}

final class GameView: MTKView, MTKViewDelegate {
    private var world: World
    private var renderer: Renderer
    private var player: Player
    private let shaderSource: String
    private let hud = NSTextField(labelWithString: "")
    private let sound = Soundscape()
    private let journey = Journey()
    private let compass = CompassView(frame: NSRect(x: 0, y: 0, width: 190, height: 190))
    private var notice = ""
    private var said = ""              // what the last person spoken to said
    private var saidUntil = 0.0
    private var atStall: Bool { simd_distance(V2(player.pos.x, player.pos.z), world.trader) < 5 }
    private var stepsHeard = 0
    private var keys = Set<UInt16>()
    private var captured = false
    private var look = V2()
    private var hour: Float = 16.4
    private var lastFrame = CACurrentMediaTime()
    private let start = CACurrentMediaTime()
    private var frames = 0
    private var fps = 0.0
    private var fpsMark = CACurrentMediaTime()
    private var gpuMs = 0.0   // smoothed GPU time per frame, written on the main queue

    init(frame: CGRect, device: MTLDevice, shaderSource: String, stageIndex: Int) throws {
        self.shaderSource = shaderSource
        world = World(stageIndex: stageIndex)
        renderer = try Renderer(device: device, world: world, shaderSource: shaderSource, targetFormat: .bgra8Unorm_srgb)
        player = Player(world: world)
        super.init(frame: frame, device: device)
        colorPixelFormat = .bgra8Unorm_srgb
        depthStencilPixelFormat = .invalid
        framebufferOnly = true
        preferredFramesPerSecond = 60
        delegate = self

        hud.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        hud.textColor = .white
        hud.shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.8)
            s.shadowBlurRadius = 3
            return s
        }()
        hud.maximumNumberOfLines = 16
        hud.frame = NSRect(x: 14, y: frame.height - 236, width: frame.width - 28, height: 226)
        hud.autoresizingMask = [.width, .minYMargin]
        addSubview(hud)
        compass.frame.origin = CGPoint(x: frame.width - 206, y: 16)
        compass.autoresizingMask = [.minXMargin, .maxYMargin]
        addSubview(compass)
    }

    var stageIndex: Int { world.index }

    // Moves the journey to another stage: a new landscape, entered at the south end of its path.
    func travel(to index: Int) {
        guard let device = device else { return }
        let next = World(stageIndex: index)
        do {
            let r = try Renderer(device: device, world: next, shaderSource: shaderSource, targetFormat: colorPixelFormat)
            r.renderScale = renderer.renderScale
            world = next
            renderer = r
            player = Player(world: next)
            stepsHeard = 0
            UserDefaults.standard.set(next.index, forKey: "stage")
            log.line("stage \(next.index + 1): \(next.stage.name), \(next.stage.country)")
        } catch {
            log.line("could not build stage \(index): \(error)")
        }
    }

    private func hudText() -> String {
        let s = world.stage
        let h = Int(hour), m = Int((hour - Float(h)) * 60)
        var text = String(format: "%@, %@ · %.2f°%@ %.2f°%@ · stage %d of %d · %.0f km to Alexandria · %02d:%02d\n",
                          s.name, s.country, abs(s.lat), s.lat < 0 ? "S" : "N", abs(s.lon), s.lon < 0 ? "W" : "E",
                          world.index + 1, Route.stages.count, Route.remaining(from: world.index), h, m)
        // Where the walker actually is on the Earth.
        let lat = s.lat + Double(player.pos.z) / 110_574, lon = s.lon - Double(player.pos.x) / (111_320 * cos(s.lat * .pi / 180))
        if player.flying {
            text += String(format: "%.0f fps · FLYING %.4f°%@ %.4f°%@ · %.0f m above sea level, %.0f m above ground · %.0f m/s · WASD, Space up, C down, Shift fast, scroll speed · G land · , . previous/next stop · [ ] time",
                           fps, abs(lat), lat < 0 ? "S" : "N", abs(lon), lon < 0 ? "W" : "E",
                           world.real != nil ? player.pos.y - world.seaLevel : player.pos.y,
                           player.pos.y - (max(abs(player.pos.x), abs(player.pos.z)) < World.half ? world.height(player.pos.x, player.pos.z) : world.terrain(player.pos.x, player.pos.z)),
                           player.flySpeed)
            return text + (notice.isEmpty ? "" : "\n" + notice)
        }
        text += String(format: "%.0f fps · WASD walk · Shift run · Space jump · E talk · G fly · [ ] time of day · M mute · F full screen · %@",
                       fps, captured ? "Esc frees the mouse" : "click to look around")
        if CACurrentMediaTime() < saidUntil { text += "\n" + said }
        if atStall {
            text += "\n" + journey.stall(at: world.index) + (notice.isEmpty ? "" : "\n  " + notice)
        } else {
            let d = simd_distance(V2(player.pos.x, player.pos.z), world.trader)
            text += String(format: "\n%@ has a stall %.0f m away · money %d · carrying %d/%d · %@", Economy.trader(at: world.index), d, journey.money, journey.carried, journey.vehicle.capacity, journey.vehicle.name)
        }
        if !player.flying && player.atExit(world) {
            if world.index + 1 < Route.stages.count {
                let next = Route.stages[world.index + 1]
                text += String(format: "\nThe path leaves %@. Press Return to travel on to %@ (%.0f km).",
                               s.name, next.name, Route.distance(s, next))
            } else {
                text += "\nThe Mediterranean. You have walked the length of Africa."
            }
        }
        return text
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = Float(min(now - lastFrame, 0.1))
        lastFrame = now

        func down(_ code: UInt16) -> Bool { keys.contains(code) }
        let move = V2((down(2) ? 1 : 0) - (down(0) ? 1 : 0),
                      (down(13) || down(126) ? 1 : 0) - (down(1) || down(125) ? 1 : 0))
        player.yaw += ((down(123) ? 1 : 0) - (down(124) ? 1 : 0)) * 1.8 * dt - look.x * 0.0022
        player.pitch = min(max(player.pitch - look.y * 0.0022, -1.45), 1.45)
        look = V2()
        hour = min(max(hour + ((down(30) ? 1 : 0) - (down(33) ? 1 : 0)) * 1.5 * dt, 5.6), 18.4)
        player.walkSpeed = journey.vehicle.walk
        player.runSpeed = journey.vehicle.run
        if player.flying {
            player.fly(dt: dt, move: move, rise: (down(49) ? 1 : 0) - (down(8) ? 1 : 0), fast: NSEvent.modifierFlags.contains(.shift), world: world)
        } else {
            player.update(dt: dt, move: move, run: NSEvent.modifierFlags.contains(.shift), jump: down(49), world: world)
        }
        world.update(dt: dt, walker: player.flying ? V2(1e6, 1e6) : V2(player.pos.x, player.pos.z))

        if player.steps != stepsHeard {
            stepsHeard = player.steps
            if journey.transport == 0 && !player.flying { sound?.footstep(running: player.running) }
        }

        guard let drawable = currentDrawable,
              let cb = renderer.render(to: drawable.texture, camera: player.camera, time: Float(now - start), hour: hour) else { return }
        cb.addCompletedHandler { [weak self] done in
            let ms = (done.gpuEndTime - done.gpuStartTime) * 1000
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.gpuMs = self.gpuMs == 0 ? ms : self.gpuMs * 0.9 + ms * 0.1
            }
        }
        cb.present(drawable)
        cb.commit()

        frames += 1
        if frames % 30 == 0 {
            fps = 30 / (now - fpsMark)
            fpsMark = now
            // Hold 60 fps by trading resolution: drop quickly when over budget, creep back up when under.
            if gpuMs > 14 {
                renderer.renderScale = max(0.55, renderer.renderScale - 0.08)
            } else if gpuMs < 10.5 {
                renderer.renderScale = min(1, renderer.renderScale + 0.04)
            }
            hud.stringValue = hudText()
        }
        if frames % 4 == 0 {
            let here = V2(player.pos.x, player.pos.z)
            let last = world.index + 1 >= Route.stages.count
            compass.heading = -player.yaw
            compass.targets = [
                (world.exit - here, last ? "Journey's end" : "Road to " + Route.stages[world.index + 1].name, NSColor.systemGreen),
                (world.trader - here, Economy.trader(at: world.index), NSColor.systemOrange),
            ]
            compass.needsDisplay = true
        }
        if frames % 600 == 0 {
            log.line(String(format: "frame %d · %.1f fps · GPU %.1f ms · %d×%d px at %.0f%% · pos %.0f,%.0f · hour %.2f",
                            frames, fps, gpuMs, drawable.texture.width, drawable.texture.height, renderer.renderScale * 100,
                            player.pos.x, player.pos.z, hour))
        }
    }

    private func setCaptured(_ on: Bool) {
        if on == captured { return }
        captured = on
        CGAssociateMouseAndMouseCursorPosition(on ? 0 : 1)
        if on { NSCursor.hide() } else { NSCursor.unhide() }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            setCaptured(false)
        } else if event.keyCode == 3 && !event.isARepeat {
            window?.toggleFullScreen(nil)
        } else if event.keyCode == 4 && !event.isARepeat {
            hud.isHidden.toggle()
            compass.isHidden = hud.isHidden
        } else if event.keyCode == 46 && !event.isARepeat {
            sound?.toggleMute()
        } else if event.keyCode == 5 && !event.isARepeat {
            notice = player.toggleFlying(world)
            hud.stringValue = hudText()
        } else if player.flying && (event.keyCode == 43 || event.keyCode == 47) && !event.isARepeat {
            // Fly mode hops between stops and stays in the air.
            let next = world.index + (event.keyCode == 47 ? 1 : -1)
            if next >= 0 && next < Route.stages.count {
                travel(to: next)
                _ = player.toggleFlying(world)
                player.pos.y += 60
                notice = ""
            }
        } else if event.keyCode == 14 && !event.isARepeat && !player.flying {
            said = world.greeting(near: V2(player.pos.x, player.pos.z)) ?? "There is nobody close enough to talk to."
            saidUntil = CACurrentMediaTime() + 9
            hud.stringValue = hudText()
        } else if atStall && !event.isARepeat, let slot = [18, 19, 20, 21, 23, 22].firstIndex(of: Int(event.keyCode)) {
            let offer = Economy.offer(at: world.index)
            if slot < offer.count {
                notice = event.modifierFlags.contains(.shift) ? journey.sell(offer[slot], at: world.index) : journey.buy(offer[slot], at: world.index)
            }
            hud.stringValue = hudText()
        } else if atStall && event.keyCode == 17 && !event.isARepeat {
            notice = journey.upgrade()
            hud.stringValue = hudText()
        } else if event.keyCode == 36 && !event.isARepeat && !player.flying && player.atExit(world) && world.index + 1 < Route.stages.count {
            travel(to: world.index + 1)
        }
        keys.insert(event.keyCode)
    }

    override func keyUp(with event: NSEvent) {
        keys.remove(event.keyCode)
    }

    override func mouseDown(with event: NSEvent) {
        setCaptured(true)
    }

    override func mouseMoved(with event: NSEvent) {
        if captured { look += V2(Float(event.deltaX), Float(event.deltaY)) }
    }

    override func mouseDragged(with event: NSEvent) {
        mouseMoved(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        if player.flying { player.flySpeed = min(max(player.flySpeed * exp(Float(event.scrollingDeltaY) * 0.02), 2), 3000) }
    }

    func releaseInput() {
        setCaptured(false)
        keys.removeAll()
    }
}

// Corner compass: north turns with the walker, and each target gets an arrow on the rim with its distance.
final class CompassView: NSView {
    var heading: Float = 0   // radians clockwise from north
    var targets: [(offset: V2, label: String, colour: NSColor)] = []

    override func draw(_ dirtyRect: NSRect) {
        let c = CGPoint(x: bounds.midX, y: bounds.height - 62), r: CGFloat = 50
        NSColor.black.withAlphaComponent(0.35).setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)).fill()
        NSColor.white.withAlphaComponent(0.8).setStroke()
        let rim = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        rim.lineWidth = 1.5
        rim.stroke()

        func point(_ angle: Float, _ radius: CGFloat) -> CGPoint {
            CGPoint(x: c.x + CGFloat(sin(angle)) * radius, y: c.y + CGFloat(cos(angle)) * radius)
        }
        func text(_ s: String, at p: CGPoint, _ colour: NSColor, size: CGFloat = 11, centred: Bool = true) {
            let a = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: colour])
            let w = a.size()
            a.draw(at: CGPoint(x: centred ? p.x - w.width / 2 : p.x, y: p.y - w.height / 2))
        }
        for (k, name) in ["N", "E", "S", "W"].enumerated() {
            text(name, at: point(Float(k) * .pi / 2 - heading, r - 11), k == 0 ? .systemRed : .white)
        }

        var line = bounds.height - 128
        for t in targets {
            // World axes: +z north, -x east.
            let rel = atan2(-t.offset.x, t.offset.y) - heading
            let tip = point(rel, r + 9), left = point(rel - 0.16, r - 4), right = point(rel + 0.16, r - 4)
            let arrow = NSBezierPath()
            arrow.move(to: tip)
            arrow.line(to: left)
            arrow.line(to: right)
            arrow.close()
            t.colour.setFill()
            arrow.fill()
            text(String(format: "▲ %@ · %.0f m", t.label, simd_length(t.offset)), at: CGPoint(x: bounds.midX, y: line), t.colour)
            line -= 17
        }
    }
}
