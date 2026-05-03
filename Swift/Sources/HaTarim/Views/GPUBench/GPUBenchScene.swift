import Foundation
import Metal
import MetalKit

protocol GPUBenchScene: AnyObject {
    var name: String { get }
    var loadRange: ClosedRange<Int> { get }
    var loadDefault: Int { get }
    var loadLabel: String { get }
    var load: Int { get set }

    func resize(to size: CGSize)
    func encode(view: MTKView, commandBuffer: MTLCommandBuffer)
}
