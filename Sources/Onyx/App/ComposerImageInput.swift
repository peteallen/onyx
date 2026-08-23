import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ComposerImageDraft: Identifiable, Sendable, Hashable {
    let id: UUID
    let input: RuntimeTurnInput
    let displayName: String
    let byteCount: Int

    init(
        id: UUID = UUID(),
        input: RuntimeTurnInput,
        displayName: String,
        byteCount: Int
    ) {
        self.id = id
        self.input = input
        self.displayName = displayName
        self.byteCount = byteCount
    }

    var timelineAttachment: TimelineAttachment {
        let source: TimelineAttachmentSource = switch input {
        case let .localImagePath(path): .localFilePath(path)
        case let .imageURL(raw) where raw.lowercased().hasPrefix("data:"): .dataURL(raw)
        case let .imageURL(raw): .remoteURL(URL(string: raw)!)
        case .text: preconditionFailure("Composer image drafts cannot contain text")
        }
        return TimelineAttachment(
            id: "composer-image:\(id.uuidString)",
            source: source,
            accessibilityLabel: displayName,
            cacheIdentity: id.uuidString
        )
    }
}

enum ComposerImageValidationError: LocalizedError, Equatable {
    case tooMany(maximum: Int)
    case unreadable(String)
    case unsupported(String)
    case tooLarge(String, maximumMegabytes: Int)
    case dimensionsTooLarge(String, maximumPixels: Int)

    var errorDescription: String? {
        switch self {
        case let .tooMany(maximum):
            "You can attach up to \(maximum) images to one message."
        case let .unreadable(name):
            "\(name) could not be read as an image."
        case let .unsupported(name):
            "\(name) uses an unsupported image format. Choose PNG, JPEG, GIF, WebP, or HEIC."
        case let .tooLarge(name, maximumMegabytes):
            "\(name) is too large. Images must be \(maximumMegabytes) MB or smaller."
        case let .dimensionsTooLarge(name, maximumPixels):
            "\(name) is too large to preview safely. Keep each side at or below \(maximumPixels) pixels."
        }
    }
}

enum ComposerImageValidator {
    static let maximumCount = 10
    static let maximumBytes = 20 * 1_024 * 1_024
    static let maximumDimension = 8_192

    private static let allowedExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif"]

    static func localFile(at url: URL) throws -> ComposerImageDraft {
        let name = url.lastPathComponent.isEmpty ? "Image" : url.lastPathComponent
        guard url.isFileURL else { throw ComposerImageValidationError.unreadable(name) }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular else {
            throw ComposerImageValidationError.unreadable(name)
        }
        guard allowedExtensions.contains(url.pathExtension.lowercased()) else {
            throw ComposerImageValidationError.unsupported(name)
        }
        let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
        try validateByteCount(byteCount, name: name)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ComposerImageValidationError.unreadable(name)
        }
        try validateImageSource(source, name: name)
        return ComposerImageDraft(
            input: .localImagePath(url.path),
            displayName: name,
            byteCount: byteCount
        )
    }

    static func pastedImage(_ image: NSImage, name: String = "Pasted image") throws -> ComposerImageDraft {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw ComposerImageValidationError.unreadable(name)
        }
        try validateByteCount(png.count, name: name)
        guard let source = CGImageSourceCreateWithData(png as CFData, nil) else {
            throw ComposerImageValidationError.unreadable(name)
        }
        try validateImageSource(source, name: name)
        return ComposerImageDraft(
            input: .imageURL("data:image/png;base64,\(png.base64EncodedString())"),
            displayName: name,
            byteCount: png.count
        )
    }

    /// Clipboard decoding and PNG/base64 encoding are CPU- and allocation-
    /// heavy for screenshots. Keep that work off the main actor so paste can
    /// acknowledge immediately and the native composer remains responsive.
    static func pastedImages(_ images: [NSImage]) async -> [Result<ComposerImageDraft, any Error>] {
        let representations = images.map(\.tiffRepresentation)
        return await Task.detached(priority: .userInitiated) {
            representations.enumerated().map { index, representation in
                let name = representations.count == 1 ? "Pasted image" : "Pasted image \(index + 1)"
                return Result {
                    guard let representation,
                          let image = NSImage(data: representation) else {
                        throw ComposerImageValidationError.unreadable(name)
                    }
                    return try pastedImage(image, name: name)
                }
            }
        }.value
    }

    private static func validateByteCount(_ count: Int, name: String) throws {
        guard count > 0 else { throw ComposerImageValidationError.unreadable(name) }
        guard count <= maximumBytes else {
            throw ComposerImageValidationError.tooLarge(name, maximumMegabytes: maximumBytes / 1_024 / 1_024)
        }
    }

    private static func validateImageSource(_ source: CGImageSource, name: String) throws {
        guard CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw ComposerImageValidationError.unreadable(name)
        }
        guard width.intValue <= maximumDimension, height.intValue <= maximumDimension else {
            throw ComposerImageValidationError.dimensionsTooLarge(name, maximumPixels: maximumDimension)
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 32,
            kCGImageSourceShouldCacheImmediately: false,
        ]
        guard CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) != nil else {
            throw ComposerImageValidationError.unreadable(name)
        }
    }
}
