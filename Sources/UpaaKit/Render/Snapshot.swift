import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

/// Draws the terminal screen without showing a window. Used for render checks, comparison against baseline images, and measurement.
enum Snapshot {
    enum Failure: Error {
        case message(String)
    }

    /// Starts the shell (or command if given), sends input, waits for the output to settle, then writes the screen to url.
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
        // Texture is in BGRA order.
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                  width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw Failure.message("failed to create image") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.message("failed to write PNG: \(url.path)") }
    }

    /// Proportion (0 to 1) of pixels whose colors differ clearly between two PNGs. 1 if the sizes differ.
    /// Font edges render slightly differently across OS versions, so small differences are not counted.
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

    /// Measures the time until the file has finished being cat'ed (no rendering), and the time to build one frame when that screen is drawn repeatedly.
    static func bench(file: String, cols: Int, rows: Int) throws -> (megabytesPerSecond: Double, frameMilliseconds: Double) {
        let offscreen = try Offscreen(cols: cols, rows: rows, command: nil)
        waitUntilQuiet(offscreen.session)

        // So the end marker can be told apart from echoed input, have the shell compute it.
        let start = Date()
        offscreen.session.write("cat '\(file)'; echo upaa-done-$((40+2))\n")
        while !offscreen.session.plainText().contains("upaa-done-42") {
            if Date().timeIntervalSince(start) > 120 { throw Failure.message("cat did not finish within 120 seconds") }
            usleep(2_000)
        }
        let elapsed = Date().timeIntervalSince(start)
        let bytes = (try FileManager.default.attributesOfItem(atPath: file)[.size] as? Int) ?? 0

        let frames = 200
        var seconds = 0.0
        for _ in 0..<frames { seconds += try offscreen.draw() }
        return (Double(bytes) / 1e6 / elapsed, seconds / Double(frames) * 1000)
    }

    /// Waits until output has been quiet for 300 ms (up to 10 seconds at most).
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
        else { throw Failure.message("failed to read image: \(url.path)") }
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let context = CGContext(
            data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw Failure.message("failed to decode image: \(url.path)") }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (image.width, image.height, pixels)
    }

    /// Terminal session and the texture its screen is drawn to. The scale is fixed at 2 (Retina).
    private final class Offscreen {
        let session: TerminalSession
        let target: MTLTexture
        private let renderer: Renderer
        private let queue: MTLCommandQueue

        init(cols: Int, rows: Int, command: String?) throws {
            guard let device = MTLCreateSystemDefaultDevice() else { throw Failure.message("no Metal device") }
            let defaults = Config()
            renderer = try Renderer(device: device, fontName: defaults.fontFamily, fontSize: defaults.fontSize, scale: 2)
            guard let session = TerminalSession(cols: UInt16(cols), rows: UInt16(rows), command: command) else {
                throw Failure.message("failed to start terminal session")
            }
            self.session = session

            let (width, height) = renderer.pixelSize(cols: cols, rows: rows)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: Renderer.pixelFormat, width: width, height: height, mipmapped: false)
            descriptor.usage = [.renderTarget]
            descriptor.storageMode = .shared
            guard let target = device.makeTexture(descriptor: descriptor), let queue = device.makeCommandQueue() else {
                throw Failure.message("failed to create drawing target")
            }
            self.target = target
            self.queue = queue
        }

        /// Draws the current screen into target. Returns the seconds spent building one frame on the CPU.
        func draw() throws -> Double {
            guard let commandBuffer = queue.makeCommandBuffer() else { throw Failure.message("failed to create draw command") }
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
