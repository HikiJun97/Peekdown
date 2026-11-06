import Foundation

// MARK: - TextBundle Converter CLI
// Usage: peekdown-convert input.md [-o output.textpack | output.textbundle]
//
// 마크다운과 그 문서가 참조하는 로컬 이미지를 TextBundle 하나로 묶는다. http://textbundle.org/spec/
//   이름.textbundle/
//     text.md      이미지 경로를 assets/… 로 바꾼 본문
//     info.json    {"version": 2, "type": "net.daringfireball.markdown", …}
//     assets/      이미지 파일
// .textpack은 이 폴더를 통째로 ZIP으로 묶은 것이다(Obsidian Importer 등은 ZIP 안의 .textbundle 폴더를 찾는다).
//
// 문서는 신뢰할 수 없는 입력이다. 내보낸 파일은 남에게 공유되므로 다음을 지킨다.
// - 원격 이미지(http, https)는 내려받지 않고 링크로 남긴다
// - 로컬 이미지는 심볼릭 링크를 따라간 실제 대상이 일반 파일이고, 이미지 확장자이고, 내용도 이미지일 때만 담는다
// - 담는 파일 이름은 경로 문자를 걸러 assets/ 밖으로 나가지 못하게 한다

struct TextBundleConverter {
    struct ImageRef {
        let range: NSRange      // ![alt](path) 전체
        let alt: String
        let originalPath: String
    }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "svg", "webp", "tiff", "tif"]

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
        print("Packs a Markdown file and its local images into a TextBundle (http://textbundle.org).")
        print("Writes a .textpack (zipped bundle) unless the output ends in .textbundle.")
        print("If -o is not specified, writes <input name>.textpack next to the input.")
        print("Remote images (http, https) are kept as links.")
    }

    static func convert(inputPath: String, outputPath: String?) throws {
        let inputURL = URL(fileURLWithPath: inputPath)
        let baseDir = inputURL.deletingLastPathComponent()

        guard FileManager.default.fileExists(atPath: inputPath) else {
            throw ConvertError.fileNotFound(inputPath)
        }

        let markdownData = try Data(contentsOf: inputURL)
        let markdown = String(data: markdownData, encoding: .utf8)
            ?? String(data: markdownData, encoding: .isoLatin1) ?? ""

        // Determine output path. zip은 임시 폴더에서 실행하므로 상대 경로는 지금 작업 폴더 기준 절대 경로로 바꿔 둔다
        let outputURL = outputPath.map { URL(fileURLWithPath: $0).absoluteURL }
            ?? baseDir.appendingPathComponent(inputURL.deletingPathExtension().lastPathComponent + ".textpack")
        let outputExt = outputURL.pathExtension.lowercased()
        guard outputExt == "textpack" || outputExt == "textbundle" else {
            throw ConvertError.badOutput("output must end in .textpack or .textbundle: \(outputURL.path)")
        }
        let asFolder = outputExt == "textbundle"
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: outputURL.path, isDirectory: &isDirectory), isDirectory.boolValue != asFolder {
            throw ConvertError.badOutput("output exists and is a \(isDirectory.boolValue ? "folder" : "file"): \(outputURL.path)")
        }
        let bundleName = outputURL.deletingPathExtension().lastPathComponent + ".textbundle"

        // Build the bundle in a temp directory
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let bundleDir = tempDir.appendingPathComponent(bundleName)
        let assetsDir = bundleDir.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: assetsDir, withIntermediateDirectories: true)

        // 같은 원본은 한 번만 담는다. 이름은 앞에서부터 정하고, 치환은 일치한 위치에만 뒤에서부터 한다
        var usedFilenames: Set<String> = []
        var assigned: [String: String] = [:]   // 원본 경로 → assets 안 파일 이름
        var replacements: [(NSRange, String)] = []
        for ref in parseImageReferences(markdown) {
            if isRemote(ref.originalPath) { continue }  // 원격 이미지는 링크로 남긴다
            let filename: String
            if let existing = assigned[ref.originalPath] {
                filename = existing
            } else {
                guard let (data, ext) = loadImage(ref.originalPath, baseDir: baseDir) else {
                    fputs("Warning: Skipped image (not a readable local image file): \(ref.originalPath)\n", stderr)
                    continue
                }
                let name = uniqueFilename(baseName: safeBaseName(ref.originalPath), ext: ext, used: &usedFilenames)
                let dest = assetsDir.appendingPathComponent(name).standardizedFileURL
                // 걸러낸 이름이라도 마지막으로 assets/ 안인지 확인한다
                guard dest.deletingLastPathComponent().path == assetsDir.standardizedFileURL.path else { continue }
                try data.write(to: dest)
                assigned[ref.originalPath] = name
                filename = name
            }
            // TextBundle 명세: 본문은 이미지를 assets/ 로 시작하는 상대 경로로 가리켜야 한다
            replacements.append((ref.range, "![\(ref.alt)](assets/\(encodeDestination(filename)))"))
        }
        var output = markdown as NSString
        for (range, text) in replacements.reversed() {
            output = output.replacingCharacters(in: range, with: text) as NSString
        }

        try (output as String).write(to: bundleDir.appendingPathComponent("text.md"), atomically: true, encoding: .utf8)
        try infoJSON().write(to: bundleDir.appendingPathComponent("info.json"))

        // 임시 위치에 다 만든 다음 한 번에 교체한다(실패해도 기존 파일이 남는다)
        let finished: URL
        if asFolder {
            finished = bundleDir
        } else {
            finished = tempDir.appendingPathComponent("out.textpack")
            try createZip(of: bundleName, in: tempDir, outputPath: finished.path)
        }
        if FileManager.default.fileExists(atPath: outputURL.path) {
            _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: finished)
        } else {
            try FileManager.default.moveItem(at: finished, to: outputURL)
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

        let ns = markdown as NSString
        return regex.matches(in: markdown, options: [], range: NSRange(location: 0, length: ns.length)).map { match in
            ImageRef(range: match.range,
                     alt: ns.substring(with: match.range(at: 1)),
                     originalPath: localPath(ns.substring(with: match.range(at: 2))))
        }
    }

    static func isRemote(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("//")
    }

    /// 마크다운 주소를 실제 경로로 바꾼다: <a b.png> 꺾쇠를 벗기고, a%20b.png 같은 퍼센트 인코딩을 푼다.
    static func localPath(_ destination: String) -> String {
        var path = destination.trimmingCharacters(in: .whitespaces)
        if path.hasPrefix("<") && path.hasSuffix(">") { path = String(path.dropFirst().dropLast()) }
        if path.hasPrefix("data:") || isRemote(path) { return path }
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

    /// 이미지 데이터와 확장자를 읽는다. data URI이거나, 실제 대상이 이미지 내용을 가진 일반 파일일 때만.
    static func loadImage(_ path: String, baseDir: URL) -> (Data, String)? {
        if path.hasPrefix("data:") {
            guard let comma = path.firstIndex(of: ","), path[..<comma].hasSuffix(";base64"),
                  let data = Data(base64Encoded: String(path[path.index(after: comma)...])) else { return nil }
            let header = path[..<comma].lowercased()
            let ext = header.contains("image/png") ? "png" : header.contains("image/jpeg") ? "jpg"
                : header.contains("image/gif") ? "gif" : header.contains("image/svg") ? "svg"
                : header.contains("image/webp") ? "webp" : "png"
            return isImageData(data, ext: ext) ? (data, ext) : nil
        }
        let url = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : baseDir.appendingPathComponent(path))
            .resolvingSymlinksInPath()
        let ext = url.pathExtension.lowercased()
        guard imageExtensions.contains(ext),
              (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
              let data = try? Data(contentsOf: url), isImageData(data, ext: ext) else { return nil }
        return (data, ext)
    }

    /// 파일 앞부분이 확장자에 맞는 실제 이미지 형식인지 본다. MdairRender.swift의 같은 검사와 맞춘다.
    static func isImageData(_ data: Data, ext: String) -> Bool {
        let b = [UInt8](data.prefix(12))
        func starts(_ sig: [UInt8]) -> Bool { b.count >= sig.count && Array(b.prefix(sig.count)) == sig }
        switch ext {
        case "png": return starts([0x89, 0x50, 0x4E, 0x47])
        case "jpg", "jpeg": return starts([0xFF, 0xD8, 0xFF])
        case "gif": return starts(Array("GIF8".utf8))
        case "webp": return starts(Array("RIFF".utf8)) && b.count >= 12 && Array(b[8..<12]) == Array("WEBP".utf8)
        case "tif", "tiff": return starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A])
        case "svg": return String(decoding: data.prefix(4096), as: UTF8.self).lowercased().contains("<svg")
        default: return false
        }
    }

    /// assets 안 파일 이름의 기본 부분. 경로 구분자·제어 문자를 걸러 폴더 밖을 가리키지 못하게 한다.
    static func safeBaseName(_ path: String) -> String {
        if path.hasPrefix("data:") { return "inline" }
        let last = (path as NSString).lastPathComponent
        let base = (last as NSString).deletingPathExtension
        var cleaned = String(base.unicodeScalars.map { scalar -> Character in
            "/\\:".unicodeScalars.contains(scalar) || scalar.properties.generalCategory == .control ? "_" : Character(scalar)
        })
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        return cleaned.isEmpty ? "image" : String(cleaned.prefix(100))
    }

    /// 이미 쓴 이름(새로 만든 a_1 같은 이름 포함)과 겹치지 않는 이름을 고른다
    static func uniqueFilename(baseName: String, ext: String, used: inout Set<String>) -> String {
        var candidate = "\(baseName).\(ext)"
        var n = 0
        while used.contains(candidate.lowercased()) {
            n += 1
            candidate = "\(baseName)_\(n).\(ext)"
        }
        used.insert(candidate.lowercased())
        return candidate
    }

    /// 번들 폴더를 통째로 ZIP으로 묶어 .textpack을 만든다
    static func createZip(of bundleName: String, in dir: URL, outputPath: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        // -y: 심볼릭 링크를 따라가지 않고 링크 자체로 담는다(번들 안에는 링크가 없어야 정상이다)
        process.arguments = ["-r", "-q", "-y", outputPath, bundleName]
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
        case badOutput(String)
        case zipFailed

        var errorDescription: String? {
            switch self {
            case .fileNotFound(let path): return "File not found: \(path)"
            case .badOutput(let message): return message
            case .zipFailed: return "Failed to create ZIP archive"
            }
        }
    }
}

// Entry point
TextBundleConverter.main()
