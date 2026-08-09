//
//  MetalDotRenderer.swift
//
//  Draws the particle field with one instanced draw call.
//
//  The earlier version used one CALayer per dot, which was the right answer
//  for sixteen dots and the wrong one for a full-screen field: the count is
//  now in the hundreds, each particle needs a stretched trail rather than a
//  circle, and both a dark and a light copy are drawn. That is thousands of
//  layer property writes per frame. Metal does the whole field in a single
//  draw and leaves the CPU almost idle.
//
//  Everything is in points; the drawable is sized in pixels and the vertex
//  shader divides by the viewport, so Retina scaling needs no special case.
//

import AppKit
import Metal
import QuartzCore
import simd

protocol DotRendering: AnyObject {
    func configure(settings: RenderSettings, size: CGSize, scale: CGFloat, isDark: Bool)
    func render(motion: VehicleMotion, dt: Double)
}

/// Must match the layout in Shaders.metal.
private struct Uniforms {
    var viewport: SIMD2<Float>
    var globalAlpha: Float
    var softness: Float
}

private struct InstanceData {
    var head: SIMD2<Float>
    var tail: SIMD2<Float>
    var radius: Float
    var alpha: Float
    var colour: SIMD4<Float>
}

final class MetalDotRenderer: DotRendering {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    let layer: CAMetalLayer

    private var settings = RenderSettings()
    private var field = ParticleField()
    private var viewport = CGSize.zero
    private var isDark = true

    /// Reused every frame; grown, never shrunk.
    private var instances: [InstanceData] = []
    private var instanceBuffer: MTLBuffer?

    /// Hard ceiling. The field is periodic, so beyond this the extra
    /// particles are invisible clutter anyway, and a runaway viewport must
    /// never be able to allocate without bound.
    private static let maxInstances = 8192

    init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device,
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue

        // Compiled from source at launch rather than at build time; see
        // ParticleShaders for why.
        guard let library = Self.makeLibrary(device: device),
              let vertexFunction = library.makeFunction(name: "particle_vertex"),
              let fragmentFunction = library.makeFunction(name: "particle_fragment") else { return nil }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = .bgra8Unorm
        // Premultiplied source-over: the overlay sits on live content.
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        self.pipeline = pipeline

        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.isOpaque = false
        layer.framebufferOnly = true
        // Draw only when we ask, in step with the display link.
        layer.presentsWithTransaction = false
        layer.allowsNextDrawableTimeout = true
        self.layer = layer
    }

    private static func makeLibrary(device: MTLDevice) -> MTLLibrary? {
        do {
            return try device.makeLibrary(source: ParticleShaders.source, options: nil)
        } catch {
            // Worth being loud about: without this there is no overlay at all.
            NSLog("MotionCues: shader compilation failed — %@", String(describing: error))
            return nil
        }
    }

    // MARK: - DotRendering

    /// The overlay is drawn below native resolution on purpose.
    ///
    /// It covers the whole screen and repaints every frame, so its cost is
    /// dominated by pixels, not by particle count: at 2× on a 1470×956 display
    /// that is 5.6 million pixels of clear-and-blend, 60 times a second, plus
    /// the WindowServer compositing the result over live content. Measured at
    /// 9–18 % of a core on an M4 — far too much for something meant to run for
    /// a whole journey on battery.
    ///
    /// Everything drawn is a soft-edged blob with no fine detail, so it
    /// survives being rendered at a lower resolution and scaled up by the
    /// compositor. 1.25× keeps the dots from looking chunky while cutting the
    /// pixel count by about 60 % against 2×.
    static let renderScale: CGFloat = 1.25

    func configure(settings: RenderSettings, size: CGSize, scale: CGFloat, isDark: Bool) {
        self.settings = settings
        self.isDark = isDark
        self.viewport = size
        let effective = min(scale, Self.renderScale)
        layer.contentsScale = effective
        layer.frame = CGRect(origin: .zero, size: size)
        layer.drawableSize = CGSize(width: (size.width * effective).rounded(),
                                    height: (size.height * effective).rounded())
        // Let the compositor smooth the upscale rather than showing us pixels.
        layer.magnificationFilter = .linear
    }

    func resetField() { field.reset() }

    func render(motion: VehicleMotion, dt: Double) {
        field.update(motion: motion, settings: settings, dt: dt)
        buildInstances()
        draw()
    }

    private func buildInstances() {
        instances.removeAll(keepingCapacity: true)
        guard viewport.width > 1, viewport.height > 1 else { return }

        // Paired dark and light copies, offset perpendicular to travel by a
        // little over a radius, so whichever contrasts with the background
        // reads and the other recedes.
        let darkFirst = !isDark
        field.forEachParticle(viewport: viewport, settings: settings) { p in
            guard instances.count + 2 <= Self.maxInstances else { return }
            let r = Float(p.radius)
            guard r > 0.35 else { return }

            let head = SIMD2<Float>(Float(p.position.x), Float(p.position.y))
            let tail = SIMD2<Float>(Float(p.previous.x), Float(p.previous.y))
            let shift = SIMD2<Float>(0, r * 1.15)

            let strong: SIMD4<Float> = darkFirst
                ? SIMD4<Float>(0, 0, 0, 1)
                : SIMD4<Float>(1, 1, 1, 1)
            let counter: SIMD4<Float> = darkFirst
                ? SIMD4<Float>(1, 1, 1, 0.85)
                : SIMD4<Float>(0, 0, 0, 0.85)

            instances.append(InstanceData(head: head + shift, tail: tail + shift,
                                          radius: r * 0.92, alpha: Float(p.alpha),
                                          colour: counter))
            instances.append(InstanceData(head: head, tail: tail,
                                          radius: r, alpha: Float(p.alpha),
                                          colour: strong))
        }
    }

    /// True when the field has come to a complete stop, so the display link
    /// can be parked.
    var isSettled: Bool { field.intensity < 0.004 }

    /// How fast the overlay currently needs to be redrawn.
    ///
    /// Dropping the pixel resolution turned out not to help — the cost is
    /// compositing a full-screen layer, which is nearly fixed per frame — so
    /// the lever that does work is drawing fewer frames. Gentle motion is
    /// perfectly legible at 24 fps; a hard brake is not, and gets the full
    /// refresh rate. Interpolating between the two keeps the change from being
    /// noticeable.
    var preferredFrameRate: CAFrameRateRange {
        let t = min(1, field.intensity * 1.6)
        let preferred = Float(24 + 36 * t)
        return CAFrameRateRange(minimum: 24, maximum: 120, preferred: preferred)
    }

    /// Renders one frame into an offscreen image instead of the layer.
    ///
    /// Used by `Tools/DemoRenderer` so the published demo is produced by this
    /// exact renderer rather than a lookalike.
    func renderToImage(motion: VehicleMotion, dt: Double, scale: CGFloat) -> CGImage? {
        field.update(motion: motion, settings: settings, dt: dt)
        buildInstances()

        let width = Int(viewport.width * scale), height = Int(viewport.height * scale)
        guard width > 0, height > 0 else { return nil }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

        guard let buffer = encode(into: texture) else { return nil }
        buffer.commit()
        buffer.waitUntilCompleted()

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!, bytesPerRow: width * 4,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        // Metal's origin is bottom-left and BGRA; CoreGraphics wants top-left.
        var flipped = [UInt8](repeating: 0, count: bytes.count)
        let rowBytes = width * 4
        for row in 0..<height {
            let src = row * rowBytes
            let dst = (height - 1 - row) * rowBytes
            flipped.replaceSubrange(dst..<(dst + rowBytes), with: bytes[src..<(src + rowBytes)])
        }
        guard let provider = CGDataProvider(data: Data(flipped) as CFData) else { return nil }
        return CGImage(width: width, height: height,
                       bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                                                | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    // MARK: - Drawing

    private func draw() {
        guard let drawable = layer.nextDrawable(),
              let buffer = encode(into: drawable.texture) else { return }
        buffer.present(drawable)
        buffer.commit()
    }

    private func encode(into texture: MTLTexture) -> MTLCommandBuffer? {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store

        guard let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }

        if !instances.isEmpty {
            ensureInstanceBuffer(count: instances.count)
            if let instanceBuffer {
                instances.withUnsafeBytes { src in
                    instanceBuffer.contents().copyMemory(from: src.baseAddress!, byteCount: src.count)
                }
                var uniforms = Uniforms(
                    viewport: SIMD2<Float>(Float(viewport.width), Float(viewport.height)),
                    globalAlpha: Float(settings.opacity),
                    softness: 0.9
                )
                encoder.setRenderPipelineState(pipeline)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
                encoder.setVertexBuffer(instanceBuffer, offset: 0, index: 1)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                       instanceCount: instances.count)
            }
        }

        encoder.endEncoding()
        return buffer
    }

    private func ensureInstanceBuffer(count: Int) {
        let needed = count * MemoryLayout<InstanceData>.stride
        if let existing = instanceBuffer, existing.length >= needed { return }
        // Round up so a slowly growing field does not reallocate every frame.
        let capacity = max(needed * 2, 64 * MemoryLayout<InstanceData>.stride)
        instanceBuffer = device.makeBuffer(length: capacity, options: .storageModeShared)
    }
}
