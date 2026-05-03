import SwiftUI
import MetalKit
import QuartzCore

struct MetalCanvasView: NSViewRepresentable {
    let engine: GPUBenchEngine
    let vsync: Bool

    func makeNSView(context: Context) -> MTKView {
        let v = MTKView(frame: .zero, device: engine.device)
        v.delegate = engine
        v.framebufferOnly = false
        v.colorPixelFormat = .bgra8Unorm
        v.depthStencilPixelFormat = .depth32Float
        v.preferredFramesPerSecond = 120
        v.isPaused = false
        v.enableSetNeedsDisplay = false
        v.clearColor = MTLClearColor(red: 0.04, green: 0.04, blue: 0.06, alpha: 1)
        v.layer?.isOpaque = true
        applyVsync(view: v)
        return v
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        applyVsync(view: nsView)
    }

    private func applyVsync(view: MTKView) {
        if let layer = view.layer as? CAMetalLayer {
            layer.displaySyncEnabled = vsync
        }
    }
}
