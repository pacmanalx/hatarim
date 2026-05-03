import Foundation
import Metal
import MetalKit
import simd

final class ParticlesScene: GPUBenchScene {
    let name = "Particles"
    let loadRange: ClosedRange<Int> = 1_000...2_000_000
    let loadDefault: Int = 200_000
    let loadLabel = "particles"
    var load: Int

    private let device: MTLDevice
    private let updatePipeline: MTLComputePipelineState
    private let renderPipeline: MTLRenderPipelineState

    private var particleBuffer: MTLBuffer?
    private var particleCount: Int = 0
    private var viewportSize: simd_float2 = .init(1, 1)
    private var lastFrameTime: CFTimeInterval = 0

    init?(device: MTLDevice) {
        self.device = device
        self.load = 200_000

        let src = """
        #include <metal_stdlib>
        using namespace metal;

        struct Particle {
            float2 pos;
            float2 vel;
            float4 color;
        };

        kernel void particles_update(device Particle* particles [[buffer(0)]],
                                     constant float& dt          [[buffer(1)]],
                                     constant float2& bounds     [[buffer(2)]],
                                     constant uint& count        [[buffer(3)]],
                                     uint id                     [[thread_position_in_grid]]) {
            if (id >= count) return;
            Particle p = particles[id];
            p.pos += p.vel * dt;
            if (p.pos.x < -bounds.x) { p.pos.x = -bounds.x; p.vel.x = -p.vel.x; }
            if (p.pos.x >  bounds.x) { p.pos.x =  bounds.x; p.vel.x = -p.vel.x; }
            if (p.pos.y < -bounds.y) { p.pos.y = -bounds.y; p.vel.y = -p.vel.y; }
            if (p.pos.y >  bounds.y) { p.pos.y =  bounds.y; p.vel.y = -p.vel.y; }
            particles[id] = p;
        }

        struct VOut {
            float4 position [[position]];
            float  pointSize [[point_size]];
            float4 color;
        };

        vertex VOut particles_vert(uint vid                              [[vertex_id]],
                                   const device Particle* particles      [[buffer(0)]],
                                   constant float2& viewport             [[buffer(1)]]) {
            Particle p = particles[vid];
            VOut o;
            o.position = float4(p.pos / viewport, 0.0, 1.0);
            o.pointSize = 2.0;
            o.color = p.color;
            return o;
        }

        fragment float4 particles_frag(VOut in [[stage_in]]) {
            return in.color;
        }
        """

        guard let lib = try? device.makeLibrary(source: src, options: nil),
              let updateFn = lib.makeFunction(name: "particles_update"),
              let vertFn = lib.makeFunction(name: "particles_vert"),
              let fragFn = lib.makeFunction(name: "particles_frag"),
              let updatePS = try? device.makeComputePipelineState(function: updateFn) else {
            return nil
        }
        let rpd = MTLRenderPipelineDescriptor()
        rpd.vertexFunction = vertFn
        rpd.fragmentFunction = fragFn
        rpd.colorAttachments[0].pixelFormat = .bgra8Unorm
        rpd.colorAttachments[0].isBlendingEnabled = true
        rpd.colorAttachments[0].rgbBlendOperation = .add
        rpd.colorAttachments[0].alphaBlendOperation = .add
        rpd.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        rpd.colorAttachments[0].destinationRGBBlendFactor = .one
        rpd.colorAttachments[0].sourceAlphaBlendFactor = .one
        rpd.colorAttachments[0].destinationAlphaBlendFactor = .one
        rpd.depthAttachmentPixelFormat = .depth32Float
        guard let renderPS = try? device.makeRenderPipelineState(descriptor: rpd) else { return nil }

        self.updatePipeline = updatePS
        self.renderPipeline = renderPS
    }

    func resize(to size: CGSize) {
        viewportSize = .init(Float(max(size.width, 1)), Float(max(size.height, 1)))
    }

    private func ensureBuffer() {
        if particleCount == load, particleBuffer != nil { return }
        let n = load
        let stride = MemoryLayout<Float>.size * 8
        let length = n * stride
        guard let buf = device.makeBuffer(length: length, options: [.storageModeShared]) else { return }
        let ptr = buf.contents().bindMemory(to: Float.self, capacity: n * 8)
        let bx = viewportSize.x
        let by = viewportSize.y
        for i in 0..<n {
            let base = i * 8
            ptr[base + 0] = Float.random(in: -bx...bx)
            ptr[base + 1] = Float.random(in: -by...by)
            ptr[base + 2] = Float.random(in: -200...200)
            ptr[base + 3] = Float.random(in: -200...200)
            ptr[base + 4] = Float.random(in: 0.4...1.0)
            ptr[base + 5] = Float.random(in: 0.4...1.0)
            ptr[base + 6] = Float.random(in: 0.4...1.0)
            ptr[base + 7] = 0.6
        }
        particleBuffer = buf
        particleCount = n
    }

    func encode(view: MTKView, commandBuffer: MTLCommandBuffer) {
        ensureBuffer()
        guard let buffer = particleBuffer,
              let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor else { return }

        let now = CACurrentMediaTime()
        let dt: Float
        if lastFrameTime > 0 {
            dt = Float(min(now - lastFrameTime, 1.0 / 30.0))
        } else {
            dt = 1.0 / 60.0
        }
        lastFrameTime = now

        var dtVar = dt
        var bounds = viewportSize
        var countVar = UInt32(particleCount)

        if let cenc = commandBuffer.makeComputeCommandEncoder() {
            cenc.setComputePipelineState(updatePipeline)
            cenc.setBuffer(buffer, offset: 0, index: 0)
            cenc.setBytes(&dtVar, length: MemoryLayout<Float>.size, index: 1)
            cenc.setBytes(&bounds, length: MemoryLayout<simd_float2>.size, index: 2)
            cenc.setBytes(&countVar, length: MemoryLayout<UInt32>.size, index: 3)
            let tew = updatePipeline.threadExecutionWidth
            let groupSize = MTLSize(width: tew, height: 1, depth: 1)
            let groups = MTLSize(width: (particleCount + tew - 1) / tew, height: 1, depth: 1)
            cenc.dispatchThreadgroups(groups, threadsPerThreadgroup: groupSize)
            cenc.endEncoding()
        }

        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0.02, green: 0.02, blue: 0.04, alpha: 1)
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        if let renc = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) {
            renc.setRenderPipelineState(renderPipeline)
            renc.setVertexBuffer(buffer, offset: 0, index: 0)
            renc.setVertexBytes(&bounds, length: MemoryLayout<simd_float2>.size, index: 1)
            renc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: particleCount)
            renc.endEncoding()
        }
        commandBuffer.present(drawable)
    }
}
