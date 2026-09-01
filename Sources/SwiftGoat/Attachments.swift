import Foundation
import UniformTypeIdentifiers
import FountainKit

/// A local file staged onto the composer (dropped from Finder or picked
/// with the paperclip). The API's only file lane is base64 image
/// attachments, so images ride that; text files are inlined into the
/// prompt as fenced blocks; anything else is refused with a reason.
struct Attachment: Identifiable {
    enum Payload {
        case image(ImageInput)
        case text(String)
    }

    let id = UUID()
    let filename: String
    let payload: Payload

    var isImage: Bool {
        if case .image = payload { return true }
        return false
    }

    /// Caps keep a drag-anything surface from wedging a JSON body: images
    /// travel base64 in the prompt request, text lands verbatim in context.
    static let imageByteLimit = 8 * 1024 * 1024
    static let textByteLimit = 256 * 1024

    enum LoadError: LocalizedError {
        case unreadable(String)
        case tooLarge(String, limit: Int)
        case unsupported(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name):
                "Couldn't read \(name)."
            case .tooLarge(let name, let limit):
                "\(name) is too large (limit \(limit / 1024 / 1024 > 0 ? "\(limit / 1024 / 1024) MB" : "\(limit / 1024) KB"))."
            case .unsupported(let name):
                "\(name) isn't an image or text file — the API can't carry it."
            }
        }
    }

    static func load(from url: URL) throws -> Attachment {
        let name = url.lastPathComponent
        guard let data = try? Data(contentsOf: url) else {
            throw LoadError.unreadable(name)
        }

        let type = UTType(filenameExtension: url.pathExtension)
        if let type, type.conforms(to: .image), let mime = type.preferredMIMEType {
            guard data.count <= imageByteLimit else {
                throw LoadError.tooLarge(name, limit: imageByteLimit)
            }
            return Attachment(
                filename: name,
                payload: .image(ImageInput(data: data.base64EncodedString(), mediaType: mime))
            )
        }

        if let contents = String(data: data, encoding: .utf8) {
            guard data.count <= textByteLimit else {
                throw LoadError.tooLarge(name, limit: textByteLimit)
            }
            return Attachment(filename: name, payload: .text(contents))
        }

        throw LoadError.unsupported(name)
    }
}

extension [Attachment] {
    var images: [ImageInput] {
        compactMap {
            if case .image(let input) = $0.payload { return input }
            return nil
        }
    }

    /// The prompt with every text attachment appended as a named fence, so
    /// the sandboxed agent sees the local file it was handed.
    func assemblePrompt(draft: String) -> String {
        var parts = [draft]
        for attachment in self {
            if case .text(let contents) = attachment.payload {
                parts.append("```\(attachment.filename)\n\(contents)\n```")
            }
        }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}
