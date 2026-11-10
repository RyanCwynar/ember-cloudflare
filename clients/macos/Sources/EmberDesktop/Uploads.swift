import AppKit
import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Ember's file uploads (apps/web/src/lib/uploads.ts):
///
/// 1. `POST /api/rooms/:id/uploads` with the file's name, type, size and client message id (and thread)
///    answers `{ id, partSize, parts }`.
/// 2. Each part but the last is `PUT …/uploads/:id/parts/:n` (204).
/// 3. A thumbnail, for pictures and videos, is `PUT …/uploads/:id/preview`: a JPEG within 1200×800.
/// 4. The last part answers the file's message (201), which the room also broadcasts.
enum Uploads {
    static let maxFileSize = 250_000_000
    static let previewBox = CGSize(width: 1200, height: 800)

    struct Started: Decodable {
        let id: String
        let partSize: Int
        let parts: Int
    }

    private struct Start: Encodable {
        let name: String
        let type: String
        let size: Int
        let clientMessageId: String
        let parentId: String?
        let alsoSend: Bool?
    }

    static func contentType(of url: URL) -> String {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    /// Uploads the file at `url` to the room, calling `progress` with 0...1 as parts go, and answers its message.
    static func upload(_ url: URL, to roomId: String, api: APIClient, clientMessageId: String,
                       parentId: String?, alsoSend: Bool, progress: @escaping @MainActor (Double) -> Void) async throws -> Message {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxFileSize else { throw APIError.server(status: 413, message: "Files must be 250 MB or smaller.") }
        let type = contentType(of: url)
        let start = Start(name: url.lastPathComponent, type: type, size: size, clientMessageId: clientMessageId,
                          parentId: parentId, alsoSend: parentId == nil ? nil : alsoSend)
        let started = try await api.send(Started.self, "/api/rooms/\(roomId)/uploads", method: "POST", body: start)

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let base = "/api/rooms/\(roomId)/uploads/\(started.id)"
        for n in 1...max(1, started.parts) {
            if n == started.parts, let preview = await preview(of: url, type: type) {
                // Best effort, as the web app's: a file without a preview still shows by its name.
                _ = try? await put(preview, to: "\(base)/preview", api: api)
            }
            try handle.seek(toOffset: UInt64((n - 1) * started.partSize))
            let chunk = n == started.parts ? (try handle.readToEnd() ?? Data()) : (try handle.read(upToCount: started.partSize) ?? Data())
            let (status, data) = try await put(chunk, to: "\(base)/parts/\(n)", api: api)
            if n < started.parts {
                guard status == 204 else { throw refusal(status, data) }
            } else {
                guard status == 200 || status == 201 else { throw refusal(status, data) }
                await progress(1)
                return try JSONDecoder().decode(Message.self, from: data)
            }
            await progress(Double(n * started.partSize) / Double(max(size, 1)))
        }
        throw APIError.server(status: 0, message: "Upload failed. Please attach the file and try again.")
    }

    private static func put(_ body: Data, to path: String, api: APIClient) async throws -> (Int, Data) {
        var request = try api.request(path, method: "PUT")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await api.session.upload(for: request, from: body)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    private static func refusal(_ status: Int, _ data: Data) -> APIError {
        if status == 413 { return .server(status: 413, message: "Files must be 250 MB or smaller.") }
        let reason = (try? JSONDecoder().decode(ProblemAnswer.self, from: data))?.error
        return .server(status: status, message: reason ?? "Upload failed. Please attach the file and try again.")
    }

    /// A JPEG thumbnail within 1200×800: a picture scaled down, or a video's frame a tenth of a second in.
    static func preview(of url: URL, type: String) async -> Data? {
        if type.hasPrefix("image/"), type != "image/gif", type != "image/svg+xml" {
            return NSImage(contentsOf: url)?.jpegFitting(previewBox)
        }
        if type.hasPrefix("video/") {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = previewBox
            guard let (frame, _) = try? await generator.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)) else { return nil }
            return NSImage(cgImage: frame, size: .zero).jpegFitting(previewBox)
        }
        return nil
    }

    /// Writes pasted image data to a temporary file so it uploads like any other.
    static func temporaryFile(for image: NSImage) -> URL? {
        guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Pasted image \(formatter.string(from: Date())).png")
        do { try png.write(to: url); return url } catch { return nil }
    }
}

extension NSImage {
    /// The picture scaled down to fit within `box`, as a JPEG.
    func jpegFitting(_ box: CGSize) -> Data? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = min(1, box.width / CGFloat(cg.width), box.height / CGFloat(cg.height))
        let width = max(1, Int(CGFloat(cg.width) * scale)), height = max(1, Int(CGFloat(cg.height) * scale))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    /// The picture scaled down to fit within `box`×`box`, as a JPEG.
    func jpegFitting(_ box: CGFloat) -> Data? { jpegFitting(CGSize(width: box, height: box)) }
}
