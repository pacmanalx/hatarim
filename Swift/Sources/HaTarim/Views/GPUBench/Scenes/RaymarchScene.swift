import Foundation
import Metal
import MetalKit
import simd

/// Fragment-bound: Julia 2D fractal com iterações controláveis. Saturar fillrate × cost por pixel.
final class RaymarchScene: GPUBenchScene {
    let name = "Julia (fragment-heavy)"
    let loadRange: ClosedRange<Int> = 32...16_000
    let loadDefault: Int = 3_000
    let loadLabel = "iterations"
    var load: Int

    private let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    private var startTime: CFTimeInterval = CACurrentMediaTime()

    init?(device: MTLDevice) {
        self.device = device
        self.load = 3_000

        let src = """
        #include <metal_stdlib>
        using namespace metal;

        struct V2F {
            float4 pos [[position]];
            float2 uv;
        };

        struct Uniforms {
            float2 c;
            float  zoom;
            int    maxIter;
        };

        vertex V2F julia_vert(uint vid [[vertex_id]]) {
            float2 verts[3] = { float2(-1,-1), float2(3,-1), float2(-1,3) };
            float2 p = verts[vid];
            V2F o;
            o.pos = float4(p, 0, 1);
            o.uv = (p + 1.0) * 0.5;
            return o;
        }

        float3 inferno_palette(float t) {
            // Approx. matplotlib inferno: black → purple → red → orange → yellow → near-white.
            float3 a = float3(0.001, 0.000, 0.014);
            float3 b = float3(0.258, 0.039, 0.408);
            float3 c = float3(0.731, 0.214, 0.330);
            float3 d = float3(0.987, 0.600, 0.024);
            float3 e = float3(0.988, 0.998, 0.645);
            t = clamp(t, 0.0, 1.0);
            if (t < 0.25) return mix(a, b, t / 0.25);
            if (t < 0.50) return mix(b, c, (t - 0.25) / 0.25);
            if (t < 0.75) return mix(c, d, (t - 0.50) / 0.25);
            return mix(d, e, (t - 0.75) / 0.25);
        }

        fragment float4 julia_frag(V2F in [[stage_in]],
                                   constant Uniforms& u [[buffer(0)]]) {
            float2 z = (in.uv - 0.5) * u.zoom;
            int i = 0;
            float r2 = 0.0;
            for (i = 0; i < u.maxIter; i++) {
                float x = z.x*z.x - z.y*z.y + u.c.x;
                float y = 2.0 * z.x * z.y + u.c.y;
                z = float2(x, y);
                r2 = dot(z, z);
                if (r2 > 256.0) break;
            }
            if (i >= u.maxIter) {
                return float4(0.0, 0.0, 0.0, 1.0);
            }
            // Smooth iteration count — remove banding, dá detalhe contínuo
            float nu = log2(max(log2(r2) * 0.5, 1e-6));
            float si = float(i) + 1.0 - nu;
            float t = pow(clamp(si / float(u.maxIter), 0.0, 1.0), 0.4);
            return float4(inferno_palette(t), 1.0);
        }
        """

        guard let lib = try? device.makeLibrary(source: src, options: nil),
              let vfn = lib.makeFunction(name: "julia_vert"),
              let ffn = lib.makeFunction(name: "julia_frag") else {
            return nil
        }
        let rpd = MTLRenderPipelineDescriptor()
        rpd.vertexFunction = vfn
        rpd.fragmentFunction = ffn
        rpd.colorAttachments[0].pixelFormat = .bgra8Unorm
        rpd.depthAttachmentPixelFormat = .depth32Float
        guard let ps = try? device.makeRenderPipelineState(descriptor: rpd) else { return nil }
        self.pipeline = ps
    }

    func resize(to size: CGSize) {}

    func encode(view: MTKView, commandBuffer: MTLCommandBuffer) {
        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor else { return }

        let t = Float(CACurrentMediaTime() - startTime)
        var u = Uniforms(
            c: .init(0.7885 * cosf(t * 0.3), 0.7885 * sinf(t * 0.3)),
            zoom: 3.0,
            maxIter: Int32(load)
        )

        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        if let renc = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) {
            renc.setRenderPipelineState(pipeline)
            renc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.size, index: 0)
            renc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            renc.endEncoding()
        }
        commandBuffer.present(drawable)
    }

    private struct Uniforms {
        var c: simd_float2
        var zoom: Float
        var maxIter: Int32
    }
}
