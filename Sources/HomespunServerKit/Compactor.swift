// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import HomespunCore
import HomespunMedia

/// Runs blocking file and encoder work off the cooperative thread pool.
func detached<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .utility).async { continuation.resume(with: Result { try body() }) }
    }
}

/// Makes compact copies from local originals. Photos use the platform backend (libvips or
/// ImageIO) and videos x265; Live Photo motion is left for the phone (AVFoundation keeps
/// the still/motion pairing, FFmpeg does not).
struct Compactor: Sendable {
    struct Outcome: Sendable {
        var files: [CompactRecord]
        var deviceCompresses: [Role]
        var state: ServerAPI.AssetState
        var message: String?
    }

    /// A media problem that retrying cannot fix (undecodable, truncated, unsupported).
    struct Unprocessable: Error, CustomStringConvertible { var description: String }

    let profile: CompressionProfile

    /// The resource to compress: the current version (an edit's full-size render) when there is one.
    static func source(for kind: ServerAPI.AssetKind, in roles: Set<Role>) -> Role? {
        let preference: [Role] = kind == .video ? [.fullSizeVideo, .video] : [.fullSizePhoto, .photo]
        return preference.first(where: roles.contains)
    }

    func compact(kind: ServerAPI.AssetKind, sources: [Role: URL], baseName: String, into directory: URL) async throws
        -> Outcome {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let role = Self.source(for: kind, in: Set(sources.keys)), let source = sources[role] else {
            throw Unprocessable(description: "no original to compress")
        }
        let stem = (Storage.sanitized(baseName) as NSString).deletingPathExtension
        switch kind {
        case .photo, .livePhoto:
            guard let compressor = PlatformMedia.photoCompressor(profile: profile) else {
                throw Unprocessable(description: "no photo backend on this platform")
            }
            let output = directory.appendingPathComponent("\(stem).jpg")
            let result: PhotoCompressionResult
            do { result = try await detached { try compressor.compress(input: source, output: output) } }
            catch let error as PhotoCompressionError { throw Unprocessable(description: "photo: \(error)") }
            let record = CompactRecord(role: .photo, filename: result.url.lastPathComponent, size: result.size,
                                       sha256: result.sha256, path: result.url.path)
            #if os(macOS)
            if kind == .livePhoto {
                // A Mac compresses the motion too (AVFoundation keeps the pairing), so the phone
                // only downloads and imports.
                guard let motionSource = sources[.fullSizePairedVideo] ?? sources[.pairedVideo] else {
                    throw Unprocessable(description: "the Live Photo has no motion")
                }
                let motionOutput = directory.appendingPathComponent("\(stem).mov")
                let motion: VideoCompressionResult
                do { motion = try await LivePhotoMotionCompressor(profile: profile).compress(input: motionSource, output: motionOutput) }
                catch let error as VideoCompressionError { throw Unprocessable(description: "motion: \(error)") }
                guard result.mode == .compressed || motion.mode == .transcoded else {
                    try? FileManager.default.removeItem(at: directory)
                    return Outcome(files: [], deviceCompresses: [], state: .held, message: "Already compact")
                }
                if case .invalid(let reason) = await LivePhotoValidator.validate(photo: result.url, video: motionOutput) {
                    throw Unprocessable(description: "the compact Live Photo did not validate (\(reason))")
                }
                return Outcome(files: [record, CompactRecord(role: .pairedVideo, filename: motionOutput.lastPathComponent,
                                                             size: motion.size, sha256: motion.sha256, path: motionOutput.path)],
                               deviceCompresses: [], state: .ready, message: nil)
            }
            #endif
            if kind == .livePhoto {
                // The still pairs with motion the phone compresses, even if the still itself
                // could not get smaller.
                return Outcome(files: [record], deviceCompresses: [.pairedVideo], state: .ready, message: nil)
            }
            guard result.mode == .compressed else {
                try? FileManager.default.removeItem(at: result.url)
                return Outcome(files: [], deviceCompresses: [], state: .held, message: "Already compact")
            }
            return Outcome(files: [record], deviceCompresses: [], state: .ready, message: nil)

        case .video:
            #if os(Linux) || os(macOS)
            let ext = source.pathExtension.lowercased() == "mov" ? "mov" : "mp4"
            let output = directory.appendingPathComponent("\(stem).\(ext)")
            let result: VideoCompressionResult
            do {
                if Tools.path("ffmpeg") != nil {
                    let compressor = FFmpegVideoCompressor(profile: profile)
                    result = try await detached { try compressor.compress(input: source, output: output) }
                } else {
                    #if os(macOS)
                    // Without ffmpeg a Mac uses its own encoder; files are larger than x265's.
                    result = try await AVFoundationVideoCompressor(profile: profile).compress(input: source, output: output)
                    #else
                    throw Unprocessable(description: "ffmpeg is not installed on the server")
                    #endif
                }
            } catch let error as VideoCompressionError { throw Unprocessable(description: "video: \(error)") }
            switch result.mode {
            case .transcoded:
                return Outcome(files: [CompactRecord(role: .video, filename: output.lastPathComponent, size: result.size,
                                                     sha256: result.sha256, path: output.path)],
                               deviceCompresses: [], state: .ready, message: nil)
            case .originalKeptNotSmaller:
                try? FileManager.default.removeItem(at: output)
                return Outcome(files: [], deviceCompresses: [], state: .held, message: "Already compact")
            case .originalKeptHeld:
                try? FileManager.default.removeItem(at: output)
                return Outcome(files: [], deviceCompresses: [], state: .held,
                               message: "Kept as is: " + result.heldReasons.joined(separator: ", "))
            }
            #else
            throw Unprocessable(description: "no video backend on this platform")
            #endif
        }
    }
}
