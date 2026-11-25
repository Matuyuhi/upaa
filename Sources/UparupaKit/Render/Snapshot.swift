import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

/// ウィンドウを出さずに端末の 1 フレームを PNG に書き出す。描画の確認用。
enum Snapshot {
    enum Failure: Error {
        case message(String)
    }

    /// シェルを起動し、input を送って出力が落ち着くのを待ってから、画面を url に書く。
    static func write(to url: URL, cols: Int, rows: Int, input: String?) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw Failure.message("Metal のデバイスが無い") }
        let renderer = try Renderer(device: device, fontName: Defaults.fontName, fontSize: Defaults.fontSize, scale: 2)
        guard let session = TerminalSession(cols: UInt16(cols), rows: UInt16(rows)) else {
            throw Failure.message("端末セッションを起動できない")
        }

        waitUntilQuiet(session)
        if let input {
            session.write(input)
            waitUntilQuiet(session)
        }

        let (width, height) = renderer.pixelSize(cols: cols, rows: rows)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Renderer.pixelFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: descriptor),
              let queue = device.makeCommandQueue(),
              let commandBuffer = queue.makeCommandBuffer()
        else { throw Failure.message("描画先を作れない") }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].storeAction = .store
        renderer.draw(session: session, commandBuffer: commandBuffer, pass: pass, viewport: (width, height))
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        // テクスチャは BGRA の順。
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                  width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw Failure.message("画像を作れない") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.message("PNG を書けない: \(url.path)") }
    }

    /// 出力が 300 ミリ秒止まるまで待つ（最長 10 秒）。
    private static func waitUntilQuiet(_ session: TerminalSession) {
        let deadline = Date().addingTimeInterval(10)
        var quietSince = Date()
        while Date() < deadline {
            if session.takeDirty() { quietSince = Date() }
            if Date().timeIntervalSince(quietSince) > 0.3 { return }
            usleep(20_000)
        }
    }
}
