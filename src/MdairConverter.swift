import Foundation
import CommonCrypto

// MARK: - MdairConverter CLI
// Usage: peekdown-convert input.md [-o output.mdair]

struct MdairConverter {
    struct ImageRef {
        let fullMatch: String
        let alt: String
        let originalPath: String
        var assetFilename: String
    }

    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            printUsage()
            exit(1)
        }

        let inputPath = args[1]
        var outputPath: String?

        if args.count >= 4 && args[2] == "-o" {
            outputPath = args[3]
        }

        do {
            try convert(inputPath: inputPath, outputPath: outputPath)
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    static func printUsage() {
        print("Usage: peekdown-convert <input.md> [-o output.mdair]")
        print("")
        print("Converts a Markdown file with images into a .mdair bundle.")
        print("If -o is not specified, output filename is derived from input.")
    }

    static func convert(inputPath: String, outputPath: String?) throws {
        let inputURL = URL(fileURLWithPath: inputPath)
        let baseDir = inputURL.deletingLastPathComponent()

        guard FileManager.default.fileExists(atPath: inputPath) else {
            throw ConvertError.fileNotFound(inputPath)
        }

        let markdownData = try Data(contentsOf: inputURL)
        var markdown = String(data: markdownData, encoding: .utf8)
            ?? String(data: markdownData, encoding: .isoLatin1) ?? ""

        // Parse image references
        let imageRefs = parseImageReferences(markdown)

        // Create temp directory for building the archive
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let assetsDir = tempDir.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)

        // Track used filenames for collision resolution
        var usedFilenames: [String: Int] = [:]

        // Process each image
        var processedRefs: [ImageRef] = []
        for var ref in imageRefs {
            let resolvedFilename = resolveFilename(ref.originalPath, usedFilenames: &usedFilenames)
            ref.assetFilename = resolvedFilename

            let copied = copyAsset(
                originalPath: ref.originalPath,
                baseDir: baseDir,
                destURL: assetsDir.appendingPathComponent(resolvedFilename)
            )

            if copied {
                processedRefs.append(ref)
                // Rewrite path in markdown
                let newRef = "![\(ref.alt)](assets/\(encodeDestination(resolvedFilename)))"
                markdown = markdown.replacingOccurrences(of: ref.fullMatch, with: newRef)
            } else {
                fputs("Warning: Could not resolve image: \(ref.originalPath)\n", stderr)
            }
        }

        // Write content.md
        let contentURL = tempDir.appendingPathComponent("content.md")
        try markdown.write(to: contentURL, atomically: true, encoding: .utf8)

        // Generate manifest.json
        let manifest = generateManifest(
            markdown: markdown,
            assets: processedRefs,
            assetsDir: assetsDir
        )
        let manifestURL = tempDir.appendingPathComponent("manifest.json")
        try manifest.write(to: manifestURL, atomically: true, encoding: .utf8)

        // Determine output path
        let finalOutput: String
        if let out = outputPath {
            // zip은 임시 폴더에서 실행하므로, 상대 경로는 지금 작업 폴더 기준 절대 경로로 바꿔 둔다
            finalOutput = URL(fileURLWithPath: out).absoluteURL.path
        } else {
            let name = inputURL.deletingPathExtension().lastPathComponent
            finalOutput = baseDir.appendingPathComponent("\(name).mdair").path
        }

        // Create ZIP using /usr/bin/zip
        try createZip(sourceDir: tempDir, outputPath: finalOutput)

        // Clean up
        try? FileManager.default.removeItem(at: tempDir)

        print("Created: \(finalOutput)")
    }

    static func parseImageReferences(_ markdown: String) -> [ImageRef] {
        guard let regex = try? NSRegularExpression(
            pattern: #"!\[([^\]]*)\]\(([^)]+)\)"#, options: []
        ) else { return [] }

        let range = NSRange(markdown.startIndex..., in: markdown)
        let matches = regex.matches(in: markdown, options: [], range: range)

        return matches.compactMap { match in
            guard let fullRange = Range(match.range(at: 0), in: markdown),
                  let altRange = Range(match.range(at: 1), in: markdown),
                  let pathRange = Range(match.range(at: 2), in: markdown) else { return nil }

            let fullMatch = String(markdown[fullRange])
            let alt = String(markdown[altRange])
            let path = localPath(String(markdown[pathRange]))

            return ImageRef(fullMatch: fullMatch, alt: alt, originalPath: path, assetFilename: "")
        }
    }

    /// 마크다운 주소를 실제 경로로 바꾼다: <a b.png> 꺾쇠를 벗기고, a%20b.png 같은 퍼센트 인코딩을 푼다.
    static func localPath(_ destination: String) -> String {
        var path = destination.trimmingCharacters(in: .whitespaces)
        if path.hasPrefix("<") && path.hasSuffix(">") { path = String(path.dropFirst().dropLast()) }
        if path.hasPrefix("data:") || path.hasPrefix("http://") || path.hasPrefix("https://") { return path }
        return path.removingPercentEncoding ?? path
    }

    /// 파일 이름을 마크다운 주소로 쓸 수 있게 공백·괄호·꺾쇠·%·\ 를 퍼센트 인코딩한다.
    /// CommonMark는 공백이 든 주소를 이미지로 보지 않는다.
    static func encodeDestination(_ filename: String) -> String {
        let unsafe = Set(" \t()<>%\\".unicodeScalars)
        var out = ""
        for scalar in filename.unicodeScalars {
            if unsafe.contains(scalar) || scalar.properties.generalCategory == .control {
                out += String(scalar).utf8.map { String(format: "%%%02X", $0) }.joined()
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    static func resolveFilename(_ originalPath: String, usedFilenames: inout [String: Int]) -> String {
        let url: URL
        if originalPath.hasPrefix("data:") {
            // data URI — generate a filename
            let ext = originalPath.contains("image/png") ? "png"
                : originalPath.contains("image/jpeg") ? "jpg"
                : originalPath.contains("image/gif") ? "gif"
                : originalPath.contains("image/svg") ? "svg"
                : "png"
            let baseName = "inline"
            return uniqueFilename(baseName: baseName, ext: ext, usedFilenames: &usedFilenames)
        }

        if originalPath.hasPrefix("http://") || originalPath.hasPrefix("https://") {
            url = URL(string: originalPath) ?? URL(fileURLWithPath: originalPath)
        } else {
            url = URL(fileURLWithPath: originalPath)
        }

        let baseName = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension
        return uniqueFilename(baseName: baseName, ext: ext, usedFilenames: &usedFilenames)
    }

    static func uniqueFilename(baseName: String, ext: String, usedFilenames: inout [String: Int]) -> String {
        let candidate = "\(baseName).\(ext)"
        if usedFilenames[candidate] == nil {
            usedFilenames[candidate] = 0
            return candidate
        }
        let count = (usedFilenames[candidate] ?? 0) + 1
        usedFilenames[candidate] = count
        return "\(baseName)_\(count).\(ext)"
    }

    static func copyAsset(originalPath: String, baseDir: URL, destURL: URL) -> Bool {
        let fm = FileManager.default

        // Handle data URIs
        if originalPath.hasPrefix("data:") {
            guard let commaIndex = originalPath.firstIndex(of: ",") else { return false }
            let b64String = String(originalPath[originalPath.index(after: commaIndex)...])
            guard let data = Data(base64Encoded: b64String) else { return false }
            return fm.createFile(atPath: destURL.path, contents: data)
        }

        // Handle URLs
        if originalPath.hasPrefix("http://") || originalPath.hasPrefix("https://") {
            guard let url = URL(string: originalPath) else { return false }
            // Synchronous download
            let semaphore = DispatchSemaphore(value: 0)
            var downloadedData: Data?
            let task = URLSession.shared.dataTask(with: url) { data, _, _ in
                downloadedData = data
                semaphore.signal()
            }
            task.resume()
            _ = semaphore.wait(timeout: .now() + 30)
            guard let data = downloadedData else { return false }
            return fm.createFile(atPath: destURL.path, contents: data)
        }

        // Handle local paths
        let sourceURL: URL
        if originalPath.hasPrefix("/") {
            sourceURL = URL(fileURLWithPath: originalPath)
        } else {
            sourceURL = baseDir.appendingPathComponent(originalPath)
        }

        guard fm.fileExists(atPath: sourceURL.path) else { return false }
        do {
            try fm.copyItem(at: sourceURL, to: destURL)
            return true
        } catch {
            return false
        }
    }

    static func generateManifest(markdown: String, assets: [ImageRef], assetsDir: URL) -> String {
        // Extract title from first h1 heading
        var title: String?
        let lines = markdown.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") {
                title = String(trimmed.dropFirst(2))
                break
            }
        }

        // Build asset entries
        var assetEntries: [[String: Any]] = []
        let fm = FileManager.default
        for ref in assets {
            let filePath = assetsDir.appendingPathComponent(ref.assetFilename).path
            var entry: [String: Any] = [
                "name": ref.assetFilename,
                "mime": mimeType(for: ref.assetFilename)
            ]

            if let attrs = try? fm.attributesOfItem(atPath: filePath),
               let size = attrs[.size] as? Int {
                entry["size"] = size
            }

            if let data = fm.contents(atPath: filePath) {
                entry["hash"] = "sha256:\(sha256Hex(data))"
            }

            assetEntries.append(entry)
        }

        // Build manifest
        let iso8601 = ISO8601DateFormatter()
        iso8601.formatOptions = [.withInternetDateTime]

        var manifest: [String: Any] = [
            "mdair_version": 1,
            "created": iso8601.string(from: Date()),
            "assets": assetEntries
        ]
        if let t = title {
            manifest["title"] = t
        }

        guard let jsonData = try? JSONSerialization.data(
            withJSONObject: manifest,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return "{}" }

        return String(data: jsonData, encoding: .utf8) ?? "{}"
    }

    static func mimeType(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "webp": return "image/webp"
        case "tiff", "tif": return "image/tiff"
        default: return "image/png"
        }
    }

    static func sha256Hex(_ data: Data) -> String {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { ptr in
            _ = CC_SHA256(ptr.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    static func createZip(sourceDir: URL, outputPath: String) throws {
        // Remove existing output file
        try? FileManager.default.removeItem(atPath: outputPath)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-r", "-q", outputPath, "content.md", "manifest.json", "assets"]
        process.currentDirectoryURL = sourceDir
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ConvertError.zipFailed
        }
    }

    enum ConvertError: LocalizedError {
        case fileNotFound(String)
        case zipFailed

        var errorDescription: String? {
            switch self {
            case .fileNotFound(let path): return "File not found: \(path)"
            case .zipFailed: return "Failed to create ZIP archive"
            }
        }
    }
}

// Entry point
MdairConverter.main()
