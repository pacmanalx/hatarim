import Foundation
import Combine
import Metal
import MetalKit
import QuartzCore

final class GPUBenchEngine: NSObject, ObservableObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private(set) var scenes: [GPUBenchScene] = []

    @Published var sceneIndex: Int = 0 {
        didSet { resetMetrics() }
    }
    @Published var load: Int = 0 {
        didSet {
            guard !scenes.isEmpty else { return }
            scenes[sceneIndex].load = load
        }
    }
    @Published var running: Bool = false {
        didSet { resetMetrics() }
    }
    @Published var vsync: Bool = true

    @Published var fps: Double = 0
    @Published var frameMS: Double = 0
    @Published var p50MS: Double = 0
    @Published var p99MS: Double = 0
    @Published var fpsHistory: [Double] = []

    private var lastFrameTime: CFTimeInterval = 0
    private var frameSamplesMS: [Double] = []
    private var fpsAccumStart: CFTimeInterval = 0
    private var fpsAccumCount: Int = 0
    private var lastSize: CGSize = .zero

    var currentScene: GPUBenchScene? {
        scenes.indices.contains(sceneIndex) ? scenes[sceneIndex] : nil
    }

    override init() {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let q = dev.makeCommandQueue() else {
            fatalError("Metal device unavailable")
        }
        self.device = dev
        self.queue = q
        super.init()

        if let s = ParticlesScene(device: dev) { scenes.append(s) }
        if let s = RaymarchScene(device: dev) { scenes.append(s) }
        if let s = MandelbulbScene(device: dev) { scenes.append(s) }
        if let s = GeometryStormScene(device: dev) { scenes.append(s) }
        if let s = BlurStackScene(device: dev) { scenes.append(s) }

        if let s = scenes.first {
            self.load = s.loadDefault
        }
    }

    func selectScene(_ index: Int) {
        guard scenes.indices.contains(index) else { return }
        sceneIndex = index
        load = scenes[index].loadDefault
    }

    func report() -> String {
        guard let s = currentScene else { return "" }
        let date = ISO8601DateFormatter().string(from: Date())
        return """
        HaTarim GPU Bench
        timestamp: \(date)
        scene:     \(s.name)
        load:      \(s.load) \(s.loadLabel)
        fps:       \(String(format: "%.1f", fps))
        frameMS:   \(String(format: "%.2f", frameMS))
        p50MS:     \(String(format: "%.2f", p50MS))
        p99MS:     \(String(format: "%.2f", p99MS))
        """
    }

    private func resetMetrics() {
        fps = 0
        frameMS = 0
        p50MS = 0
        p99MS = 0
        fpsHistory.removeAll()
        frameSamplesMS.removeAll()
        lastFrameTime = 0
        fpsAccumStart = 0
        fpsAccumCount = 0
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        lastSize = size
        for s in scenes { s.resize(to: size) }
    }

    func draw(in view: MTKView) {
        if view.drawableSize != lastSize {
            lastSize = view.drawableSize
            for s in scenes { s.resize(to: view.drawableSize) }
        }

        guard running, let scene = currentScene else {
            renderIdle(view: view)
            lastFrameTime = 0
            return
        }

        guard let buf = queue.makeCommandBuffer() else { return }
        scene.encode(view: view, commandBuffer: buf)
        buf.commit()

        let now = CACurrentMediaTime()
        if lastFrameTime > 0 {
            let dt = (now - lastFrameTime) * 1000.0
            frameSamplesMS.append(dt)
            if frameSamplesMS.count > 240 {
                frameSamplesMS.removeFirst(frameSamplesMS.count - 240)
            }
            fpsAccumCount += 1
            if fpsAccumStart == 0 { fpsAccumStart = now }
            if now - fpsAccumStart >= 0.5 {
                let elapsed = now - fpsAccumStart
                let measured = Double(fpsAccumCount) / elapsed
                let sorted = frameSamplesMS.sorted()
                let p50Val = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
                let p99Idx = sorted.isEmpty ? 0 : min(sorted.count - 1, Int(Double(sorted.count) * 0.99))
                let p99Val = sorted.isEmpty ? 0 : sorted[p99Idx]
                var newHistory = fpsHistory
                newHistory.append(measured)
                if newHistory.count > 120 {
                    newHistory.removeFirst(newHistory.count - 120)
                }
                DispatchQueue.main.async {
                    self.fps = measured
                    self.frameMS = 1000.0 / max(measured, 1)
                    self.p50MS = p50Val
                    self.p99MS = p99Val
                    self.fpsHistory = newHistory
                }
                fpsAccumStart = now
                fpsAccumCount = 0
            }
        }
        lastFrameTime = now
    }

    private func renderIdle(view: MTKView) {
        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let buf = queue.makeCommandBuffer() else { return }
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0.04, green: 0.04, blue: 0.06, alpha: 1)
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        if let enc = buf.makeRenderCommandEncoder(descriptor: rpd) {
            enc.endEncoding()
        }
        buf.present(drawable)
        buf.commit()
    }
}
