import AppKit
import MetalKit

/// 端末 1 つを表示するビュー。画面が変わったときだけ描き直す。
final class TerminalView: MTKView, MTKViewDelegate {
    private let session: TerminalSession
    private let renderer: Renderer
    private let commandQueue: MTLCommandQueue

    init(session: TerminalSession, renderer: Renderer) {
        self.session = session
        self.renderer = renderer
        commandQueue = renderer.device.makeCommandQueue()!
        super.init(frame: .zero, device: renderer.device)
        colorPixelFormat = Renderer.pixelFormat
        // 毎フレームではなく、needsDisplay を立てたときだけ描く。
        isPaused = true
        enableSetNeedsDisplay = true
        delegate = self
        session.onWakeup = { [weak self] in self?.needsDisplay = true }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) は使わない")
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        // 次の変化の通知を受け取れるようにしてから描く。
        _ = session.takeDirty()
        guard let pass = currentRenderPassDescriptor,
              let drawable = currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer()
        else { return }
        renderer.draw(
            session: session, commandBuffer: commandBuffer, pass: pass,
            viewport: (Int(drawableSize.width), Int(drawableSize.height)))
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
