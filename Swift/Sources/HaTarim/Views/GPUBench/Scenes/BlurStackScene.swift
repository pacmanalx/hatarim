import Foundation
import Metal
import MetalKit
import simd

/// Bandwidth/fillrate: gera padrão animado em offscreen e ping-pong blur N passes.
/// Load = quantidade de passes (cada passe lê + escreve textura inteira).
final class BlurStackScene: GPUBenchScene {
    let name = "Blur Stack (bandwidth)"
    let loadRange: ClosedRange<Int> = 1...512
    let loadDefault: Int = 64
    let loadLabel = "passes"
    var load: Int

    private let device: MTLDevice
    private let patternPipeline: MTLRenderPipelineState
    private let blurPipeline: MTLRenderPipelineState
    private let presentPipeline: MTLRenderPipelineState

    private var texA: MTLTexture?
    private var texB: MTLTexture?
    private var currentSize: CGSize = .zero

    private var startTime: CFTimeInterval = CACurrentMediaTime()

    init?(device: MTLDevice) {
        self.device = device
        self.load = 64

        let src = """
        #include <metal_stdlib>
        using namespace metal;

        struct V2F {
            float4 pos [[position]];
            float2 uv;
        };

        vertex V2F fs_vert(uint vid [[vertex_id]]) {
            float2 verts[3] = { float2(-1,-1), float2(3,-1), float2(-1,3) };
            float2 p = verts[vid];
            V2F o;
            o.pos = float4(p, 0, 1);
            o.uv = (p + 1.0) * 0.5;
            return o;
        }

        fragment float4 pattern_frag(V2F in [[stage_in]],
                                     constant float& t [[buffer(0)]]) {
            float2 q = in.uv * 8.0 + float2(t, t * 0.7);
            float v = sin(q.x) * cos(q.y) + sin(q.x * 0.5 + q.y);
            float3 col = float3(0.5 + 0.5 * sin(v + float3(0.0, 2.1, 4.2)));
            return float4(col, 1.0);
        }

        struct BlurUniforms {
            float2 dir;
            float2 texel;
        };

        fragment float4 blur_frag(V2F in [[stage_in]],
                                  texture2d<float, access::sample> src [[texture(0)]],
                                  constant BlurUniforms& u [[buffer(0)]]) {
            constexpr sampler s(filter::linear, address::clamp_to_edge);
            float w[5] = { 0.227027, 0.194594, 0.121622, 0.0540541, 0.0162162 };
            float3 acc = src.sample(s, in.uv).rgb * w[0];
            for (int i = 1; i < 5; i++) {
                float2 off = u.dir * u.texel * float(i);
                acc += src.sample(s, in.uv + off).rgb * w[i];
                acc += src.sample(s, in.uv - off).rgb * w[i];
            }
            return float4(acc, 1.0);
        }

        fragment float4 present_frag(V2F in [[stage_in]],
                                     texture2d<float, access::sample> src [[texture(0)]]) {
            constexpr sampler s(filter::linear, address::clamp_to_edge);
            return src.sample(s, in.uv);
        }
        """

        guard let lib = try? device.makeLibrary(source: src, options: nil),
              let vfn = lib.makeFunction(name: "fs_vert"),
              let pfn = lib.makeFunction(name: "pattern_frag"),
              let bfn = lib.makeFunction(name: "blur_frag"),
              let prfn = lib.makeFunction(name: "present_frag") else {
            return nil
        }

        func makePipe(_ frag: MTLFunction, format: MTLPixelFormat, withDepth: Bool = false) -> MTLRenderPipelineState? {
            let rpd = MTLRenderPipelineDescriptor()
            rpd.vertexFunction = vfn
            rpd.fragmentFunction = frag
            rpd.colorAttachments[0].pixelFormat = format
            if withDepth {
                rpd.depthAttachmentPixelFormat = .depth32Float
            }
            return try? device.makeRenderPipelineState(descriptor: rpd)
        }

        guard let p1 = makePipe(pfn, format: .bgra8Unorm),
              let p2 = makePipe(bfn, format: .bgra8Unorm),
              let p3 = makePipe(prfn, format: .bgra8Unorm, withDepth: true) else { return nil }

        self.patternPipeline = p1
        self.blurPipeline = p2
        self.presentPipeline = p3
    }

    func resize(to size: CGSize) {
        let w = max(Int(size.width), 1)
        let h = max(Int(size.height), 1)
        if Int(currentSize.width) == w && Int(currentSize.height) == h, texA != nil, texB != nil { return }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                            width: w, height: h,
                                                            mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        texA = device.makeTexture(descriptor: desc)
        texB = device.makeTexture(descriptor: desc)
        currentSize = .init(width: w, height: h)
    }

    func encode(view: MTKView, commandBuffer: MTLCommandBuffer) {
        resize(to: view.drawableSize)
        guard let a = texA, let b = texB,
              let drawable = view.currentDrawable,
              let finalRPD = view.currentRenderPassDescriptor else { return }

        // 1) Pattern → A
        var t = Float(CACurrentMediaTime() - startTime)
        let patternRPD = MTLRenderPassDescriptor()
        patternRPD.colorAttachments[0].texture = a
        patternRPD.colorAttachments[0].loadAction = .dontCare
        patternRPD.colorAttachments[0].storeAction = .store
        if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: patternRPD) {
            enc.setRenderPipelineState(patternPipeline)
            enc.setFragmentBytes(&t, length: MemoryLayout<Float>.size, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }

        // 2) Ping-pong blur passes
        var src = a
        var dst = b
        let texel = simd_float2(1.0 / Float(currentSize.width), 1.0 / Float(currentSize.height))
        for i in 0..<load {
            let dir: simd_float2 = (i % 2 == 0) ? .init(1, 0) : .init(0, 1)
            var u = BlurUniforms(dir: dir, texel: texel)
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = dst
            rpd.colorAttachments[0].loadAction = .dontCare
            rpd.colorAttachments[0].storeAction = .store
            if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) {
                enc.setRenderPipelineState(blurPipeline)
                enc.setFragmentTexture(src, index: 0)
                enc.setFragmentBytes(&u, length: MemoryLayout<BlurUniforms>.size, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                enc.endEncoding()
            }
            swap(&src, &dst)
        }

        // 3) Present
        finalRPD.colorAttachments[0].loadAction = .dontCare
        finalRPD.colorAttachments[0].storeAction = .store
        if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: finalRPD) {
            enc.setRenderPipelineState(presentPipeline)
            enc.setFragmentTexture(src, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
        commandBuffer.present(drawable)
    }

    private struct BlurUniforms {
        var dir: simd_float2
        var texel: simd_float2
    }
}
