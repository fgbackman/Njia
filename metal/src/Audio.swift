// Synthesized ambience: wind, grass rustle and footsteps. No audio files.
import AVFoundation

struct SoundSynth {
    private var seed: UInt32 = 0x1234_567
    private var windL: Float = 0
    private var windR: Float = 0
    private var rustleLow: Float = 0
    private var clock: Float = 0
    private var stepEnv: Float = 0
    private var stepClock: Float = 0
    private var stepLow: Float = 0
    private var stepGain: Float = 0

    private mutating func noise() -> Float {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        return Float(Int32(bitPattern: seed)) / 2_147_483_648
    }

    mutating func step(gain: Float) {
        stepEnv = 1
        stepClock = 0
        stepGain = gain
    }

    mutating func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int, sampleRate: Float) {
        let dt = 1 / sampleRate
        let stepDecay = exp(-dt / 0.045)
        let rateScale = 48000 / sampleRate
        for i in 0..<count {
            clock += dt
            let gust = 0.5 + 0.3 * sin(clock * 0.23) + 0.2 * sin(clock * 0.71 + 1.7)
            let a = (0.012 + 0.03 * gust) * rateScale
            windL += (noise() - windL) * a
            windR += (noise() - windR) * a
            let windGain = 0.35 + 0.5 * gust

            let n = noise()
            rustleLow += (n - rustleLow) * 0.35
            let rustle = (n - rustleLow) * 0.012 * gust * gust

            var step: Float = 0
            if stepEnv > 0.0005 {
                stepLow += (noise() - stepLow) * 0.18 * rateScale
                stepClock += dt
                step = (stepLow * 0.9 + sin(stepClock * 2 * .pi * 75) * 0.5 * stepEnv) * stepEnv * stepGain
                stepEnv *= stepDecay
            }
            left[i] = windL * windGain + rustle + step
            right[i] = windR * windGain + rustle + step
        }
    }
}

final class Soundscape {
    private let engine = AVAudioEngine()
    private var synth = SoundSynth()
    // Written by the main thread, read by the audio thread.
    private let stepCount = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    private let stepGain = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    private var stepsHeard: Int32 = 0
    private(set) var muted = false

    init?() {
        stepCount.initialize(to: 0)
        stepGain.initialize(to: 0.2)
        let rate = engine.outputNode.inputFormat(forBus: 0).sampleRate
        guard rate > 0, let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { return nil }
        let node = AVAudioSourceNode(format: format) { [unowned self] _, _, frameCount, list -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            guard buffers.count >= 2,
                  let l = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            if self.stepCount.pointee != self.stepsHeard {
                self.stepsHeard = self.stepCount.pointee
                self.synth.step(gain: self.stepGain.pointee)
            }
            self.synth.render(left: l, right: r, count: Int(frameCount), sampleRate: Float(rate))
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0.8
        do { try engine.start() } catch { return nil }
    }

    func footstep(running: Bool) {
        stepGain.pointee = running ? 0.3 : 0.2
        stepCount.pointee &+= 1
    }

    func toggleMute() {
        muted.toggle()
        engine.mainMixerNode.outputVolume = muted ? 0 : 0.8
    }
}

// Renders the synth offline and reports levels, since nothing here can listen to it.
func audioSelfTest() -> Int32 {
    let rate: Float = 48000
    let count = Int(rate) * 6
    var synth = SoundSynth()
    var l = [Float](repeating: 0, count: count), r = [Float](repeating: 0, count: count)
    for block in 0..<(count / 480) {
        if block % 50 == 25 { synth.step(gain: block > 300 ? 0.3 : 0.2) }
        l.withUnsafeMutableBufferPointer { lp in
            r.withUnsafeMutableBufferPointer { rp in
                synth.render(left: lp.baseAddress! + block * 480, right: rp.baseAddress! + block * 480, count: 480, sampleRate: rate)
            }
        }
    }
    let peak = max(l.map { abs($0) }.max() ?? 0, r.map { abs($0) }.max() ?? 0)
    let rms = (l.reduce(0) { $0 + $1 * $1 } / Float(count)).squareRoot()
    let bad = l.contains { !$0.isFinite } || r.contains { !$0.isFinite }
    print(String(format: "audio: peak %.3f (%.1f dBFS) · rms %.4f (%.1f dBFS) · finite %@",
                 peak, 20 * log10(peak), rms, 20 * log10(rms), bad ? "NO" : "yes"))
    return bad || peak >= 1 ? 1 : 0
}
