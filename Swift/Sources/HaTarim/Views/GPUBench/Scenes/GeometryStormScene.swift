import Foundation
import Metal
import MetalKit
import simd

/// Vertex-bound: N instâncias de cubo 3D com rotação per-instance + depth test.
/// Cada instância tem 36 índices, então load=200k = 7.2M triângulos/frame.
final class GeometryStormScene: GPUBenchScene {
    let name = "Geometry Storm"
    let loadRange: ClosedRange<Int> = 100...500_000
    let loadDefault: Int = 30_000
    let loadLabel = "instances"
    var load: Int

    private let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let vertexBuffer: MTLBuffer
    private let indexBuffer: MTLBuffer
    private let indexCount: Int
    private var startTime = CACurrentMediaTime()

    init?(device: MTLDevice) {
        self.device = device
        self.load = 30_000

        let s: Float = 0.04
        let verts: [Float] = [
            -s,-s,-s,  s,-s,-s,  s, s,-s, -s, s,-s,
            -s,-s, s,  s,-s, s,  s, s, s, -s, s, s
        ]
        let idx: [UInt16] = [
            0,1,2, 0,2,3,   4,6,5, 4,7,6,
            0,4,5, 0,5,1,   3,2,6, 3,6,7,
            0,3,7, 0,7,4,   1,5,6, 1,6,2
        ]

        guard let vb = device.makeBuffer(bytes: verts,
                                         length: MemoryLayout<Float>.size * verts.count,
                                         options: []),
              let ib = device.makeBuffer(bytes: idx,
                                         length: MemoryLayout<UInt16>.size * idx.count,
                                         options: []) else { return nil }
        self.vertexBuffer = vb
        self.indexBuffer = ib
        self.indexCount = idx.count

        let src = """
        #include <metal_stdlib>
        using namespace metal;

        struct Uniforms {
            float4x4 viewMtx;
            float4x4 proj;
            float    time;
        };

        struct VOut {
            float4 pos [[position]];
            float3 color;
        };

        float h11(uint i) { return fract(sin(float(i) * 12.9898) * 43758.5453); }

        float3x3 rotMat(float3 ax, float a) {
            float c = cos(a); float s = sin(a); float omc = 1.0 - c;
            float x = ax.x, y = ax.y, z = ax.z;
            return float3x3(
                float3(c + x*x*omc,    y*x*omc + z*s, z*x*omc - y*s),
                float3(x*y*omc - z*s,  c + y*y*omc,   z*y*omc + x*s),
                float3(x*z*omc + y*s,  y*z*omc - x*s, c + z*z*omc)
            );
        }

        vertex VOut gs_vert(uint vid                          [[vertex_id]],
                            uint iid                          [[instance_id]],
                            const device float* verts         [[buffer(0)]],
                            constant Uniforms& u              [[buffer(1)]]) {
            float3 v = float3(verts[vid*3+0], verts[vid*3+1], verts[vid*3+2]);

            float3 base = float3(
                h11(iid * 3u + 1u) * 5.0 - 2.5,
                h11(iid * 3u + 2u) * 5.0 - 2.5,
                h11(iid * 3u + 3u) * 5.0 - 2.5
            );
            float3 axis = normalize(float3(
                h11(iid * 7u + 1u) - 0.5,
                h11(iid * 7u + 2u) - 0.5,
                h11(iid * 7u + 3u) - 0.5
            ));
            float speed = 0.5 + h11(iid * 5u + 11u) * 1.8;
            float3 rotated = rotMat(axis, u.time * speed) * v;

            float3 wpos = base + rotated;
            float4 vp = u.viewMtx * float4(wpos, 1.0);
            VOut o;
            o.pos = u.proj * vp;
            o.color = float3(
                0.4 + 0.6 * h11(iid * 9u + 1u),
                0.4 + 0.6 * h11(iid * 9u + 2u),
                0.4 + 0.6 * h11(iid * 9u + 3u)
            );
            return o;
        }

        fragment float4 gs_frag(VOut in [[stage_in]]) {
            return float4(in.color, 1.0);
        }
        """

        guard let lib = try? device.makeLibrary(source: src, options: nil),
              let vfn = lib.makeFunction(name: "gs_vert"),
              let ffn = lib.makeFunction(name: "gs_frag") else { return nil }

        let rpd = MTLRenderPipelineDescriptor()
        rpd.vertexFunction = vfn
        rpd.fragmentFunction = ffn
        rpd.colorAttachments[0].pixelFormat = .bgra8Unorm
        rpd.depthAttachmentPixelFormat = .depth32Float
        guard let ps = try? device.makeRenderPipelineState(descriptor: rpd) else { return nil }
        self.pipeline = ps

        let dsd = MTLDepthStencilDescriptor()
        dsd.depthCompareFunction = .less
        dsd.isDepthWriteEnabled = true
        guard let ds = device.makeDepthStencilState(descriptor: dsd) else { return nil }
        self.depthState = ds
    }

    func resize(to size: CGSize) {}

    func encode(view: MTKView, commandBuffer: MTLCommandBuffer) {
        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor else { return }

        let aspect = Float(view.drawableSize.width / max(view.drawableSize.height, 1))
        let proj = Self.perspective(fovY: .pi / 3, aspect: aspect, near: 0.1, far: 30)
        let t = Float(CACurrentMediaTime() - startTime)
        let camMtx = Self.lookAt(eye: .init(6 * cos(t * 0.15), 1.5, 6 * sin(t * 0.15)),
                                 center: .init(0, 0, 0),
                                 up: .init(0, 1, 0))
        var u = Uniforms(viewMtx: camMtx, proj: proj, time: t)

        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0.02, green: 0.02, blue: 0.05, alpha: 1)
        rpd.colorAttachments[0].storeAction = .store
        rpd.depthAttachment.loadAction = .clear
        rpd.depthAttachment.clearDepth = 1.0
        rpd.depthAttachment.storeAction = .dontCare

        if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) {
            enc.setRenderPipelineState(pipeline)
            enc.setDepthStencilState(depthState)
            enc.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.size, index: 1)
            enc.drawIndexedPrimitives(type: .triangle,
                                      indexCount: indexCount,
                                      indexType: .uint16,
                                      indexBuffer: indexBuffer,
                                      indexBufferOffset: 0,
                                      instanceCount: load)
            enc.endEncoding()
        }
        commandBuffer.present(drawable)
    }

    private struct Uniforms {
        var viewMtx: simd_float4x4
        var proj: simd_float4x4
        var time: Float
    }

    private static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let yScale = 1 / tan(fovY * 0.5)
        let xScale = yScale / aspect
        let zRange = far - near
        let zScale = -(far + near) / zRange
        let wzScale = -2 * far * near / zRange
        return simd_float4x4(columns: (
            .init(xScale, 0, 0, 0),
            .init(0, yScale, 0, 0),
            .init(0, 0, zScale, -1),
            .init(0, 0, wzScale, 0)
        ))
    }

    private static func lookAt(eye: simd_float3, center: simd_float3, up: simd_float3) -> simd_float4x4 {
        let f = simd_normalize(center - eye)
        let s = simd_normalize(simd_cross(f, up))
        let uVec = simd_cross(s, f)
        return simd_float4x4(columns: (
            .init(s.x, uVec.x, -f.x, 0),
            .init(s.y, uVec.y, -f.y, 0),
            .init(s.z, uVec.z, -f.z, 0),
            .init(-simd_dot(s, eye), -simd_dot(uVec, eye), simd_dot(f, eye), 1)
        ))
    }
}
