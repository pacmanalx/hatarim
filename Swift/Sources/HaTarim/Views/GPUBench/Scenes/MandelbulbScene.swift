import Foundation
import Metal
import MetalKit
import simd

/// Raymarch 3D do Mandelbulb power=8 com distance estimator. Fragment-bound + ALU pesado:
/// cada pixel faz N iterações de DE × até 64 passos de ray-march. Load = iters da DE.
final class MandelbulbScene: GPUBenchScene {
    let name = "Mandelbulb 3D"
    let loadRange: ClosedRange<Int> = 4...32
    let loadDefault: Int = 16
    let loadLabel = "DE iterations"
    var load: Int

    private let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    private var startTime = CACurrentMediaTime()

    init?(device: MTLDevice) {
        self.device = device
        self.load = 16

        let src = """
        #include <metal_stdlib>
        using namespace metal;

        struct V2F { float4 pos [[position]]; float2 uv; };

        struct Uniforms {
            float2 res;
            float  time;
            int    iters;
        };

        vertex V2F mb_vert(uint vid [[vertex_id]]) {
            float2 verts[3] = { float2(-1,-1), float2(3,-1), float2(-1,3) };
            float2 p = verts[vid];
            V2F o;
            o.pos = float4(p, 0, 1);
            o.uv = (p + 1.0) * 0.5;
            return o;
        }

        float DE_mandelbulb(float3 p, int iters) {
            float3 z = p;
            float dr = 1.0;
            float r = 0.0;
            const float power = 8.0;
            for (int i = 0; i < iters; i++) {
                r = length(z);
                if (r > 2.0) break;
                float theta = acos(z.z / max(r, 1e-6));
                float phi = atan2(z.y, z.x);
                dr = pow(r, power - 1.0) * power * dr + 1.0;
                float zr = pow(r, power);
                theta *= power;
                phi *= power;
                z = zr * float3(sin(theta) * cos(phi), sin(phi) * sin(theta), cos(theta));
                z += p;
            }
            return 0.5 * log(max(r, 1e-6)) * r / dr;
        }

        fragment float4 mb_frag(V2F in [[stage_in]],
                                constant Uniforms& u [[buffer(0)]]) {
            float aspect = u.res.x / max(u.res.y, 1.0);
            float2 uv = (in.uv - 0.5) * float2(aspect, 1.0) * 2.5;

            float t = u.time * 0.2;
            float3 ro = float3(2.6 * cos(t), 0.6, 2.6 * sin(t));
            float3 ww = normalize(float3(0) - ro);
            float3 uu = normalize(cross(ww, float3(0, 1, 0)));
            float3 vv = cross(uu, ww);
            float3 rd = normalize(uv.x * uu + uv.y * vv + 1.5 * ww);

            float t_hit = 0.0;
            const float maxT = 6.0;
            const int maxSteps = 96;
            int hitStep = -1;
            for (int i = 0; i < maxSteps; i++) {
                float d = DE_mandelbulb(ro + rd * t_hit, u.iters);
                if (d < 0.001) { hitStep = i; break; }
                if (t_hit > maxT) break;
                t_hit += d;
            }

            if (hitStep < 0) {
                float v = 0.5 - 0.5 * uv.y * 0.4;
                return float4(v * 0.05, v * 0.06, v * 0.10, 1.0);
            }

            float ao = 1.0 - float(hitStep) / float(maxSteps);
            float dist = clamp(t_hit / maxT, 0.0, 1.0);
            float3 col = mix(float3(1.0, 0.55, 0.2), float3(0.1, 0.2, 0.55), dist);
            col *= ao;
            return float4(col, 1.0);
        }
        """

        guard let lib = try? device.makeLibrary(source: src, options: nil),
              let v = lib.makeFunction(name: "mb_vert"),
              let f = lib.makeFunction(name: "mb_frag") else { return nil }
        let rpd = MTLRenderPipelineDescriptor()
        rpd.vertexFunction = v
        rpd.fragmentFunction = f
        rpd.colorAttachments[0].pixelFormat = .bgra8Unorm
        rpd.depthAttachmentPixelFormat = .depth32Float
        guard let ps = try? device.makeRenderPipelineState(descriptor: rpd) else { return nil }
        self.pipeline = ps
    }

    func resize(to size: CGSize) {}

    func encode(view: MTKView, commandBuffer: MTLCommandBuffer) {
        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor else { return }
        var u = Uniforms(
            res: simd_float2(Float(view.drawableSize.width), Float(view.drawableSize.height)),
            time: Float(CACurrentMediaTime() - startTime),
            iters: Int32(load)
        )
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) {
            enc.setRenderPipelineState(pipeline)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.size, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }
        commandBuffer.present(drawable)
    }

    private struct Uniforms {
        var res: simd_float2
        var time: Float
        var iters: Int32
    }
}
