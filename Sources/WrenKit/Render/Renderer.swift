import CWrenCore
import Metal

/// 端末の 1 フレームを Metal で描く。セルのデータは Zig が Metal のバッファに直接書く。
final class Renderer {
    enum SetupError: Error {
        case font
        case metal(String)
    }

    static let pixelFormat = MTLPixelFormat.bgra8Unorm

    let device: MTLDevice
    /// 1 セルの大きさ（ピクセル）。
    let cellSize: (width: Int, height: Int)
    /// グリッドの周りの余白（ピクセル）。x は左右、y は上下。
    let padding: (top: Int, bottom: Int, horizontal: Int)

    /// グリッドの周りの余白（ポイント）。左右と下はウィンドウの角丸で文字が欠けないための量。
    /// 上はタイトルバーがあって角丸にかからないので、小さくしている。
    private static let paddingPoints = (top: 2.0, bottom: 16.0, horizontal: 8.0)

    private let handle: OpaquePointer
    private let backgroundPipeline: MTLRenderPipelineState
    private let glyphPipeline: MTLRenderPipelineState
    private let atlasTexture: MTLTexture
    private var atlasGeneration: UInt64 = 0
    private var cellBuffer: MTLBuffer?

    /// fontSize はポイント、scale は画面の拡大率（Retina なら 2）。
    init(device: MTLDevice, fontName: String, fontSize: Double, scale: Double) throws {
        guard let handle = wren_renderer_new(fontName, fontSize * scale) else { throw SetupError.font }
        self.handle = handle
        self.device = device
        let metrics = wren_renderer_metrics(handle)
        cellSize = (Int(metrics.cell_width), Int(metrics.cell_height))
        let points = Renderer.paddingPoints
        padding = (
            Int((points.top * scale).rounded()), Int((points.bottom * scale).rounded()),
            Int((points.horizontal * scale).rounded()))

        let library: MTLLibrary
        do {
            library = try device.makeDefaultLibrary(bundle: .main)
        } catch {
            wren_renderer_free(handle)
            throw SetupError.metal("default.metallib を読めない: \(error)")
        }

        func pipeline(_ name: String, blending: Bool) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "\(name)_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: "\(name)_fragment")
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = Renderer.pixelFormat
            if blending {
                attachment.isBlendingEnabled = true
                attachment.sourceRGBBlendFactor = .sourceAlpha
                attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }

        let atlasSize = Int(wren_renderer_atlas_size())
        let atlasDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: atlasSize, height: atlasSize, mipmapped: false)
        do {
            backgroundPipeline = try pipeline("background", blending: false)
            glyphPipeline = try pipeline("glyph", blending: true)
            guard let texture = device.makeTexture(descriptor: atlasDescriptor) else {
                throw SetupError.metal("アトラスのテクスチャを作れない")
            }
            atlasTexture = texture
        } catch {
            wren_renderer_free(handle)
            throw error
        }
    }

    deinit {
        wren_renderer_free(handle)
    }

    /// 大きさ size（ピクセル）の描画先に入る桁数と行数。
    func gridSize(for size: (width: Int, height: Int)) -> (cols: Int, rows: Int) {
        (
            max(1, (size.width - 2 * padding.horizontal) / cellSize.width),
            max(1, (size.height - padding.top - padding.bottom) / cellSize.height)
        )
    }

    /// cols x rows のグリッドがちょうど入る描画先の大きさ（ピクセル）。
    func pixelSize(cols: Int, rows: Int) -> (width: Int, height: Int) {
        (cols * cellSize.width + 2 * padding.horizontal, rows * cellSize.height + padding.top + padding.bottom)
    }

    /// session の今の画面を pass の描画先に描く。viewport は描画先の大きさ（ピクセル）。
    func draw(
        session: TerminalSession,
        commandBuffer: MTLCommandBuffer,
        pass: MTLRenderPassDescriptor,
        viewport: (width: Int, height: Int)
    ) {
        // 端からはみ出す分も含めて、描画先に入りうるセルの数だけ場所を用意する。
        let capacity = (viewport.width / cellSize.width + 1) * (viewport.height / cellSize.height + 1)
        let stride = MemoryLayout<WrenCell>.stride
        if cellBuffer == nil || cellBuffer!.length < capacity * stride {
            cellBuffer = device.makeBuffer(length: capacity * stride, options: .storageModeShared)
        }
        guard let cellBuffer else { return }

        let cells = cellBuffer.contents().bindMemory(to: WrenCell.self, capacity: capacity)
        let frame = wren_renderer_frame(handle, session.handle, cells, capacity)
        uploadAtlasIfNeeded(generation: frame.atlas_generation)

        let bg = frame.background
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(bg.0) / 255, green: Double(bg.1) / 255, blue: Double(bg.2) / 255, alpha: 1)
        pass.colorAttachments[0].loadAction = .clear
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        defer { encoder.endEncoding() }
        guard frame.cell_count > 0 else { return }

        var uniforms = Uniforms(
            viewport: SIMD2(Float(viewport.width), Float(viewport.height)),
            cell: SIMD2(Float(cellSize.width), Float(cellSize.height)),
            atlas: SIMD2(repeating: Float(atlasTexture.width)),
            origin: SIMD2(Float(padding.horizontal), Float(padding.top)))
        encoder.setVertexBuffer(cellBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.setFragmentTexture(atlasTexture, index: 0)

        let count = Int(frame.cell_count)
        encoder.setRenderPipelineState(backgroundPipeline)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)
        encoder.setRenderPipelineState(glyphPipeline)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)
    }

    private func uploadAtlasIfNeeded(generation: UInt64) {
        guard generation != atlasGeneration else { return }
        atlasGeneration = generation
        let size = atlasTexture.width
        atlasTexture.replace(
            region: MTLRegionMake2D(0, 0, size, size),
            mipmapLevel: 0,
            withBytes: wren_renderer_atlas_pixels(handle),
            bytesPerRow: size)
    }

    /// Shaders/terminal.metal の Uniforms と同じ並び。
    private struct Uniforms {
        var viewport: SIMD2<Float>
        var cell: SIMD2<Float>
        var atlas: SIMD2<Float>
        var origin: SIMD2<Float>
    }
}
