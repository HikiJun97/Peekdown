import Foundation

// MARK: - TextBundle Converter CLI
// Usage: peekdown-convert input.md [-o output.textpack | output.textbundle]
//
// 마크다운과 그 문서가 참조하는 이미지를 TextBundle 하나로 묶는다. http://textbundle.org/spec/
//   이름.textbundle/
//     text.md      이미지 경로를 assets/… 로 바꾼 본문
//     info.json    {"version": 2, "type": "net.daringfireball.markdown", …}
//     assets/      이미지 파일
// .textpack은 이 폴더를 통째로 ZIP으로 묶은 것이다(Obsidian Importer 등은 ZIP 안의 .textbundle 폴더를 찾는다).

struct TextBundleConverter {
    struct ImageRef {
        let fullMatch: String
        let alt: String
        let originalPath: String
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
        print("Usage: peekdown-convert <input.md> [-o output.textpack | output.textbundle]")
        print("")
        print("Packs a Markdown file and its images into a TextBundle (http://textbundle.org).")
        print("Writes a .textpack (zipped bundle) unless the output ends in .textbundle.")
        print("If -o is not specified, writes <input name>.textpack next to the input.")
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

        // Determine output path. zip은 임시 폴더에서 실행하므로 상대 경로는 지금 작업 폴더 기준 절대 경로로 바꿔 둔다
        let outputURL = outputPath.map { URL(fileURLWithPath: $0).absoluteURL }
            ?? baseDir.appendingPathComponent(inputURL.deletingPathExtension().lastPathComponent + ".textpack")
        let asFolder = outputURL.pathExtension.lowercased() == "textbundle"
        let bundleName = outputURL.deletingPathExtension().lastPathComponent + ".textbundle"

        // Build the bundle in a temp directory
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let bundleDir = tempDir.appendingPathComponent(bundleName)
        let assetsDir = bundleDir.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)

        // Track used filenames for collision resolution
        var usedFilenames: [String: Int] = [:]

        // Process each image
        for ref in parseImageReferences(markdown) {
            let resolvedFilename = resolveFilename(ref.originalPath, usedFilenames: &usedFilenames)
            let copied = copyAsset(
                originalPath: ref.originalPath,
                baseDir: baseDir,
                destURL: assetsDir.appendingPathComponent(resolvedFilename)
            )

            if copied {
                // TextBundle 명세: 본문은 이미지를 assets/ 로 시작하는 상대 경로로 가리켜야 한다
                let newRef = "![\(ref.alt)](assets/\(encodeDestination(resolvedFilename)))"
                markdown = markdown.replacingOccurrences(of: ref.fullMatch, with: newRef)
            } else {
                fputs("Warning: Could not resolve image: \(ref.originalPath)\n", stderr)
            }
        }

        try markdown.write(to: bundleDir.appendingPathComponent("text.md"), atomically: true, encoding: .utf8)
        try infoJSON().write(to: bundleDir.appendingPathComponent("info.json"))

        try? FileManager.default.removeItem(at: outputURL)
        if asFolder {
            try FileManager.default.moveItem(at: bundleDir, to: outputURL)
        } else {
            try createZip(of: bundleName, in: tempDir, outputPath: outputURL.path)
        }

        print("Created: \(outputURL.path)")
    }

    /// TextBundle 명세 버전 2의 info.json
    static func infoJSON() throws -> Data {
        let info: [String: Any] = [
            "version": 2,
            "type": "net.daringfireball.markdown",
            "transient": false,
            "creatorIdentifier": "io.github.hikijun97.peekdown",
        ]
        return try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
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

            return ImageRef(fullMatch: fullMatch, alt: alt, originalPath: path)
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

    /// 번들 폴더를 통째로 ZIP으로 묶어 .textpack을 만든다
    static func createZip(of bundleName: String, in dir: URL, outputPath: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-r", "-q", outputPath, bundleName]
        process.currentDirectoryURL = dir
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
TextBundleConverter.main()
