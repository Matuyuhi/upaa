import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

/// ウィンドウを出さずに端末の画面を描く。描画の確認、基準の画像との比較、計測に使う。
enum Snapshot {
    enum Failure: Error {
        case message(String)
    }

    /// シェル（command があればそのコマンド）を起動し、input を送って出力が落ち着くのを待ってから、画面を url に書く。
    static func write(to url: URL, cols: Int, rows: Int, command: String?, input: String?) throws {
        let offscreen = try Offscreen(cols: cols, rows: rows, command: command)
        waitUntilQuiet(offscreen.session)
        if let input {
            offscreen.session.write(input)
            waitUntilQuiet(offscreen.session)
        }
        _ = try offscreen.draw()

        let (width, height) = (offscreen.target.width, offscreen.target.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        offscreen.target.getBytes(
            &pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
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

    /// 2 枚の PNG で、色がはっきり違うピクセルの割合（0〜1）。大きさが違えば 1。
    /// OS のバージョンでフォントの縁の描き方が少し変わるので、小さな差は数えない。
    static func difference(_ a: URL, _ b: URL) throws -> Double {
        let (first, second) = (try rgba(a), try rgba(b))
        guard first.width == second.width, first.height == second.height else { return 1 }
        var different = 0
        for i in stride(from: 0, to: first.pixels.count, by: 4) {
            let delta = (0..<3).map { abs(Int(first.pixels[i + $0]) - Int(second.pixels[i + $0])) }.max()!
            if delta > 64 { different += 1 }
        }
        return Double(different) / Double(first.width * first.height)
    }

    /// ファイルを cat し終えるまでの時間（描画なし）と、その画面を繰り返し描いたときの 1 フレームの組み立て時間を測る。
    static func bench(file: String, cols: Int, rows: Int) throws -> (megabytesPerSecond: Double, frameMilliseconds: Double) {
        let offscreen = try Offscreen(cols: cols, rows: rows, command: nil)
        waitUntilQuiet(offscreen.session)

        // 入力のエコーと区別できるよう、終わりの目印はシェルに計算させる。
        let start = Date()
        offscreen.session.write("cat '\(file)'; echo upaa-done-$((40+2))\n")
        while !offscreen.session.plainText().contains("upaa-done-42") {
            if Date().timeIntervalSince(start) > 120 { throw Failure.message("cat が 120 秒で終わらない") }
            usleep(2_000)
        }
        let elapsed = Date().timeIntervalSince(start)
        let bytes = (try FileManager.default.attributesOfItem(atPath: file)[.size] as? Int) ?? 0

        let frames = 200
        var seconds = 0.0
        for _ in 0..<frames { seconds += try offscreen.draw() }
        return (Double(bytes) / 1e6 / elapsed, seconds / Double(frames) * 1000)
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

    private static func rgba(_ url: URL) throws -> (width: Int, height: Int, pixels: [UInt8]) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw Failure.message("画像を読めない: \(url.path)") }
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let context = CGContext(
            data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw Failure.message("画像を展開できない: \(url.path)") }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (image.width, image.height, pixels)
    }

    /// 端末セッションと、その画面を描くテクスチャ。拡大率は 2（Retina）に固定している。
    private final class Offscreen {
        let session: TerminalSession
        let target: MTLTexture
        private let renderer: Renderer
        private let queue: MTLCommandQueue

        init(cols: Int, rows: Int, command: String?) throws {
            guard let device = MTLCreateSystemDefaultDevice() else { throw Failure.message("Metal のデバイスが無い") }
            renderer = try Renderer(device: device, fontName: Defaults.fontName, fontSize: Defaults.fontSize, scale: 2)
            guard let session = TerminalSession(cols: UInt16(cols), rows: UInt16(rows), command: command) else {
                throw Failure.message("端末セッションを起動できない")
            }
            self.session = session

            let (width, height) = renderer.pixelSize(cols: cols, rows: rows)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: Renderer.pixelFormat, width: width, height: height, mipmapped: false)
            descriptor.usage = [.renderTarget]
            descriptor.storageMode = .shared
            guard let target = device.makeTexture(descriptor: descriptor), let queue = device.makeCommandQueue() else {
                throw Failure.message("描画先を作れない")
            }
            self.target = target
            self.queue = queue
        }

        /// 今の画面を target に描く。戻り値は CPU 側で 1 フレームを組み立てるのにかかった秒数。
        func draw() throws -> Double {
            guard let commandBuffer = queue.makeCommandBuffer() else { throw Failure.message("描画命令を作れない") }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].storeAction = .store
            let start = Date()
            renderer.draw(
                session: session, commandBuffer: commandBuffer, pass: pass, viewport: (target.width, target.height))
            commandBuffer.commit()
            let seconds = Date().timeIntervalSince(start)
            commandBuffer.waitUntilCompleted()
            return seconds
        }
    }
}
