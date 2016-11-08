//MIT License
//
//Copyright (c) 2016
//
//Permission is hereby granted, free of charge, to any person obtaining a copy
//of this software and associated documentation files (the "Software"), to deal
//in the Software without restriction, including without limitation the rights
//to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//copies of the Software, and to permit persons to whom the Software is
//furnished to do so, subject to the following conditions:
//
//The above copyright notice and this permission notice shall be included in all
//copies or substantial portions of the Software.
//
//THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//SOFTWARE.


import UIKit
import MetalKit

struct BezierParameters
{
    var a : vector_float2 = vector_float2()
    var b : vector_float2 = vector_float2()
    var p1 : vector_float2 = vector_float2()
    var p2 : vector_float2 = vector_float2()
    
    var thickness : Float = 0.01
    
    var color : vector_float4 = vector_float4()
    
    private var aMotionVec : vector_float2 = vector_float2()
    private var bMotionVec : vector_float2 = vector_float2()
    private var p1MotionVec : vector_float2 = vector_float2()
    private var p2MotionVec : vector_float2 = vector_float2()
    
    func makeRand() -> Float {
        return Float(arc4random_uniform(1000000)) / 500000.0 - 1.0
    }
    
    init() {
        // This will define line width for all curves:
        thickness = 0.004
        
        // Set a random color for this curve:
        color = vector_float4(x: Float(arc4random_uniform(1000)) / 1000.0,
                              y: Float(arc4random_uniform(1000)) / 1000.0,
                              z: Float(arc4random_uniform(1000)) / 1000.0,
                              w: 1.0)
        
        // Start this curve out at a random position and shape:
        a.x = makeRand()
        a.y = makeRand()
        
        b.x = makeRand()
        b.y = makeRand()
        
        p1.x = makeRand()
        p1.y = makeRand()
        
        p2.x = makeRand()
        p2.y = makeRand()
        
        // Initialize random motion vectors:
        aMotionVec.x = Float(arc4random_uniform(100)) / 10000.0 - 0.005
        aMotionVec.y = Float(arc4random_uniform(100)) / 10000.0 - 0.005
        
        bMotionVec.x = Float(arc4random_uniform(100)) / 10000.0 - 0.005
        bMotionVec.y = Float(arc4random_uniform(100)) / 10000.0 - 0.005
        
        p1MotionVec.x = Float(arc4random_uniform(100)) / 10000.0 - 0.005
        p1MotionVec.y = Float(arc4random_uniform(100)) / 10000.0 - 0.005
        
        p2MotionVec.x = Float(arc4random_uniform(100)) / 10000.0 - 0.005
        p2MotionVec.y = Float(arc4random_uniform(100)) / 10000.0 - 0.005
    }
    
    private func animateVector(vector : vector_float2, motionVec : inout vector_float2) -> vector_float2 {
        if vector.x >= 1.0 || vector.x <= -1.0 {
            motionVec.x = -motionVec.x
        }
        if vector.y >= 1.0 || vector.y <= -1.0 {
            motionVec.y = -motionVec.y
        }
        
        return vector_float2(x: vector.x + motionVec.x, y: vector.y + motionVec.y)
    }
    
    mutating func animate() {
        a = animateVector(vector: a, motionVec: &aMotionVec)
        b = animateVector(vector: b, motionVec: &bMotionVec)
        p1 = animateVector(vector: p1, motionVec: &p1MotionVec)
        p2 = animateVector(vector: p2, motionVec: &p2MotionVec)
    }
    
    init(a : vector_float2, b: vector_float2, p1 : vector_float2, p2 : vector_float2) {
        self.a = a
        self.b = b
        self.p1 = p1
        self.p2 = p2
    }
}

struct GlobalParameters {
    var elementsPerInstance : UInt
}

class MetalBezierView: MTKView {
    private var commandQueue: MTLCommandQueue! = nil
    private var library: MTLLibrary! = nil
    private var pipelineDescriptor = MTLRenderPipelineDescriptor()
    private var pipelineState : MTLRenderPipelineState! = nil
    private var vertexBuffer : MTLBuffer! = nil
    
    var indices : [UInt16] = [UInt16]()
    var indicesBuffer : MTLBuffer?
    
    var globalParamBuffer : MTLBuffer?
    
    // This is where we store all curve parameters (including their current positions during
    // animation). We use the PageAlignedContiguousArray to directly store and manipulate
    // them in shared memory.
    var params : PageAlignedContiguousArray<BezierParameters> = PageAlignedContiguousArray<BezierParameters>(repeating: BezierParameters(), count: 5000)
    var paramBuffer : MTLBuffer?
    
    override init(frame frameRect: CGRect, device: MTLDevice?)
    {
        super.init(frame: frameRect, device: device)
        configureWithDevice(device!)
    }
    
    required init(coder: NSCoder)
    {
        super.init(coder: coder)
        configureWithDevice(MTLCreateSystemDefaultDevice()!)
    }
    
    private func configureWithDevice(_ device : MTLDevice) {
        self.clearColor = MTLClearColor.init(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)
        self.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.framebufferOnly = true
        self.colorPixelFormat = .bgra8Unorm
        
        // Run with 4x MSAA:
        self.sampleCount = 4
        
        self.preferredFramesPerSecond = 60
        
        self.device = device
    }
    
    override var device: MTLDevice! {
        didSet {
            super.device = device
            commandQueue = (self.device?.makeCommandQueue())!
            
            library = device?.newDefaultLibrary()
            pipelineDescriptor.vertexFunction = library?.makeFunction(name: "bezier_vertex")
            pipelineDescriptor.fragmentFunction = library?.makeFunction(name: "simple_fragment")
            pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            
            pipelineDescriptor.vertexDescriptor?.attributes[0].bufferIndex = 0
            pipelineDescriptor.vertexDescriptor?.attributes[0].format = .half2
            
            pipelineDescriptor.vertexDescriptor?.layouts[0].stepFunction = .perInstance
            pipelineDescriptor.vertexDescriptor?.layouts[0].stepRate = 10
            pipelineDescriptor.vertexDescriptor?.layouts[0].stride = MemoryLayout<BezierParameters>.size

            
            // Run with 4x MSAA:
            pipelineDescriptor.sampleCount = 4
            
            do {
                try pipelineState = device?.makeRenderPipelineState(descriptor: pipelineDescriptor)
            }
            catch {
                
            }
            for (index, _) in params.enumerated() {
                params[index] = BezierParameters()
            }
            
            paramBuffer = device.makeBufferWithPageAlignedArray(params)
            
            var currentIndex : UInt16 = 0
            
            // Set how many "elements" are to be used for each curve. Normally we would
            // calculate this per curve, but since we're using the indexed primitives
            // approach, we need a fixed number of vertices per curve. Note that this is
            // the number of triangles, not vertexes:
            var globalParams = GlobalParameters(elementsPerInstance: 200)
            globalParamBuffer = (self.device?.makeBuffer(bytes: &globalParams,
                                                     length: MemoryLayout<GlobalParameters>.size,
                                                     options: .storageModeShared))
            
            repeat {
                indices.append(currentIndex)
                indices.append(currentIndex + 1)
                indices.append(currentIndex + 2)
                currentIndex += 1
            } while indices.count < Int(globalParams.elementsPerInstance * 3)
            
            let indicesDataSize = MemoryLayout<UInt>.size * indices.count
            indicesBuffer = (self.device?.makeBuffer(bytes: indices,
                                                         length: indicesDataSize,
                                                         options: .storageModeShared))
        }
    }
    
    override func draw(_ rect: CGRect) {
        
        // Animate all of our curves. No need to reload this into the GPU as we have loaded
        // the params into shared memory so our modifications will be automatically visible
        // to the vertex shader.
        for (index, _) in params.enumerated() {
            params[index].animate()
        }
        
        let commandBuffer = commandQueue!.makeCommandBuffer()
        
        let renderPassDescriptor = self.currentRenderPassDescriptor
        
        if renderPassDescriptor == nil {
            return
        }
        
        let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor!)
        
        renderEncoder.setRenderPipelineState(pipelineState)
        
        renderEncoder.setVertexBuffer(paramBuffer, offset: 0, at: 0)
        renderEncoder.setVertexBuffer(globalParamBuffer, offset: 0, at: 1)

        renderEncoder.drawIndexedPrimitives(type: .triangle, indexCount: indices.count, indexType: .uint16, indexBuffer: indicesBuffer!, indexBufferOffset: 0, instanceCount: params.count)

        renderEncoder.endEncoding()
        
        commandBuffer.present(self.currentDrawable!)
        commandBuffer.commit()
        
    }
}