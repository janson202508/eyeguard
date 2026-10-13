import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// 把用户自己的图片导入素材库。
///
/// 三件事值得说明：
///
/// 1. **按内容哈希去重**。同一张图不管从哪条路径、改没改文件名，重复导入都会被
///    认出来。用文件名去重会在「照片 2.jpg」这种默认名上直接失效。
///
/// 2. **超 2560px 的图会被降采样重编码**。一张 6000×4000 的原图十几 MB，
///    当全屏背景用是纯浪费；20 张就是几百 MB。已经是不超 2560px 的 JPEG
///    则原样复制，避免无谓的二次压缩。
///
/// 3. **depthScore 与 tone 取保守默认值**（4.0 / 中性）。这两项在引导式定位下
///    是核心指标（规格书附录 A），但程序没法可靠地判断「这张图够不够远」。
///    取 4.0 让用户图片默认进入「优先纵深」那一档，取中性让它们夜间不会被
///    误排除。想精细调整可以直接改 manifest.json。
enum SceneImporter {

    /// 导入失败的原因。
    ///
    /// 存**枚举而不是字符串**：`Outcome` 是纯数据，渲染要等到真正显示的那一刻，
    /// 那时才知道界面用的是哪国语言。在导入那一刻就把中文句子写进 `failed`，
    /// 等于把「导入时的语言」永久烙进了这条结果 —— 用户中途切语言，
    /// 已经失败的那些行还是旧语言。
    enum ImportReason: Hashable {
        case unreadable
        case notAnImage
        case undecodable
        case writeFailed
        /// 系统错误（`NSError`），文案由系统提供，不归文案表管。
        case system(String)

        func text(_ s: Strings) -> String {
            switch self {
            case .unreadable:    return s.importReasonUnreadable
            case .notAnImage:    return s.importReasonNotImage
            case .undecodable:   return s.importReasonUndecodable
            case .writeFailed:   return s.importReasonWriteFailed
            case .system(let m): return m
            }
        }
    }

    /// 一次导入的结果。逐类列出，而不是只报一个数字 ——
    /// 「导入了 8 张」在另外 2 张被跳过时是误导。
    struct Outcome {
        var added: [SceneAsset] = []
        var duplicates: [String] = []
        var unsupported: [String] = []
        var failed: [(name: String, reason: ImportReason)] = []

        var isEmpty: Bool {
            added.isEmpty && duplicates.isEmpty && unsupported.isEmpty && failed.isEmpty
        }

        /// 一行摘要。
        ///
        /// 连接符走 `listSeparator`（英文 ", " / 中文 "、"）—— 这里正是
        /// 「在调用点拼字符串」最典型的翻车点：中文用顿号、英文用逗号加空格，
        /// 写死哪一个另一边就是错的。
        func summary(_ s: Strings) -> String {
            var parts: [String] = []
            if !added.isEmpty        { parts.append(s.importAdded(added.count)) }
            if !duplicates.isEmpty   { parts.append(s.importSkippedDuplicates(duplicates.count)) }
            if !unsupported.isEmpty  { parts.append(s.importUnsupported(unsupported.count)) }
            if !failed.isEmpty       { parts.append(s.importFailed(failed.count)) }
            return parts.isEmpty ? s.importNothing : parts.joined(separator: s.listSeparator)
        }

        func failureDetail(_ s: Strings) -> String? {
            guard !failed.isEmpty else { return nil }
            return failed.prefix(3)
                .map { s.importFailureLine($0.name, $0.reason.text(s)) }
                .joined(separator: "\n")
        }

        /// 摘要的展开版：把被跳过的文件名也列出来。
        ///
        /// 「导入 8 张，跳过重复 2 张」在用户眼里是个谜 —— 他不知道跳的是哪两张，
        /// 也就无从判断该不该处理。列出名字（超过 3 个就省略）才能让他自己决定。
        func summaryDetail(_ s: Strings) -> String {
            var parts: [String] = []

            func nameList(_ names: [String]) -> String {
                let shown = names.prefix(3).joined(separator: s.listSeparator)
                return names.count > 3 ? s.importAndMore(shown, names.count) : shown
            }

            if !duplicates.isEmpty {
                parts.append(s.importDuplicatesList(nameList(duplicates)))
            }
            if !unsupported.isEmpty {
                parts.append(s.importUnsupportedList(nameList(unsupported)))
            }
            if let detail = failureDetail(s) {
                parts.append(s.importFailedList(
                    detail.replacingOccurrences(of: "\n", with: s.detailSeparator)
                ))
            }
            return parts.joined(separator: s.detailSeparator)
        }

        /// 直接给用户看的一整行：摘要，必要时接上明细。
        ///
        /// 把「怎么接」收在这里，是为了让调用点不再出现 `summary + " —— " + detail`
        /// 这种拼接 —— 破折号在中英文里长度不同，且英文还需要两侧空格。
        func message(_ s: Strings) -> String {
            let head = summary(s)
            let detail = summaryDetail(s)
            return detail.isEmpty ? head : s.importSummaryWithDetail(head, detail)
        }
    }

    static let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "webp", "tiff", "tif", "bmp", "gif"
    ]

    /// 单边超过这个像素就降采样
    static let maxEdge = 2560

    /// - Parameters:
    ///   - urls: 用户选中的文件（可以是文件，也可以是文件夹）
    ///   - category: 这批图片归属的类别
    ///   - existingIDs: 素材库里已有的 id，用于去重
    static func importItems(_ urls: [URL],
                            category: SceneCategory,
                            existingIDs: Set<String>) -> Outcome {
        AppPaths.ensureDirectories()

        var outcome = Outcome()
        var known = existingIDs

        for url in expand(urls) {
            let name = url.lastPathComponent

            guard supportedExtensions.contains(url.pathExtension.lowercased()) else {
                outcome.unsupported.append(name)
                continue
            }

            guard let data = try? Data(contentsOf: url) else {
                outcome.failed.append((name, .unreadable))
                continue
            }

            let id = "user-" + sha256Hex(data).prefix(16)
            if known.contains(id) {
                outcome.duplicates.append(name)
                continue
            }

            do {
                let asset = try write(data: data, from: url, id: id, category: category)
                outcome.added.append(asset)
                known.insert(id)
            } catch let error as ImportError {
                outcome.failed.append((name, error.reason))
            } catch {
                // 系统错误（`NSError`）的文案由系统给出，不经过文案表。
                outcome.failed.append((name, .system(error.localizedDescription)))
            }
        }

        return outcome
    }

    // MARK: - 私有

    /// 把选中的 URL 展开成文件列表。选到文件夹时取它下面一层里的图片。
    private static func expand(_ urls: [URL]) -> [URL] {
        var files: [URL] = []
        let fm = FileManager.default

        for url in urls {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }

            if isDirectory.boolValue {
                let contents = (try? fm.contentsOfDirectory(at: url,
                                                            includingPropertiesForKeys: nil,
                                                            options: [.skipsHiddenFiles])) ?? []
                files.append(contentsOf: contents.filter {
                    supportedExtensions.contains($0.pathExtension.lowercased())
                }.sorted { $0.lastPathComponent < $1.lastPathComponent })
            } else {
                files.append(url)
            }
        }
        return files
    }

    private static func write(data: Data,
                              from source: URL,
                              id: String,
                              category: SceneCategory) throws -> SceneAsset {
        guard let size = imageSize(of: source) else {
            throw ImportError.notAnImage
        }

        let longest = max(size.width, size.height)
        let isJPEG = ["jpg", "jpeg"].contains(source.pathExtension.lowercased())
        let directory = AppPaths.sceneDirectory

        let fileName: String
        if isJPEG && longest <= maxEdge {
            // 已经是合适尺寸的 JPEG —— 原样复制，不做二次压缩
            fileName = "\(id).jpg"
            try data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
        } else {
            fileName = "\(id).jpg"
            try writeDownscaled(source, to: directory.appendingPathComponent(fileName))
        }

        let written = (try? Data(contentsOf: directory.appendingPathComponent(fileName)))?.count ?? 0
        let finalSize = imageSize(of: directory.appendingPathComponent(fileName)) ?? size

        return SceneAsset(
            id: id,
            fileName: fileName,
            category: category,
            source: .imported,
            license: "用户导入",
            width: finalSize.width,
            height: finalSize.height,
            byteSize: written,
            depthScore: 4.0,
            tone: .neutral,
            originalName: source.lastPathComponent
        )
    }

    private static func imageSize(of url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        return (width, height)
    }

    private static func writeDownscaled(_ source: URL, to destination: URL) throws {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil) else {
            throw ImportError.notAnImage
        }

        // kCGImageSourceCreateThumbnailWithTransform 让 EXIF 方向生效，
        // 否则竖拍的照片导入后会躺着。
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxEdge,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            imageSource, 0, options as CFDictionary
        ) else {
            throw ImportError.decodeFailed
        }

        guard let destinationRef = CGImageDestinationCreateWithURL(
            destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            throw ImportError.writeFailed
        }

        CGImageDestinationAddImage(destinationRef, thumbnail, [
            kCGImageDestinationLossyCompressionQuality: 0.85
        ] as CFDictionary)

        guard CGImageDestinationFinalize(destinationRef) else {
            throw ImportError.writeFailed
        }
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 导入过程中的可预期错误。
    ///
    /// 只带「是哪种错」，不带文案 —— 文案在渲染时从文案表取（见 `ImportReason`）。
    /// 原来这里靠 `LocalizedError.errorDescription` 返回中文句子，
    /// 结果是**错误一产生就被定型成中文**，与界面语言无关。
    enum ImportError: Error {
        case notAnImage
        case decodeFailed
        case writeFailed

        var reason: ImportReason {
            switch self {
            case .notAnImage:   return .notAnImage
            case .decodeFailed: return .undecodable
            case .writeFailed:  return .writeFailed
            }
        }
    }
}

/// 缩略图缓存。
///
/// 用 ImageIO 生成缩略图而不是 `NSImage(contentsOf:)` —— 后者会把整张
/// 2560px 的图解码进内存，设置页里几十张一起渲染时会明显吃内存。
/// 缩略图直接从 JPEG 的 DCT 层抽样解码，代价低一个数量级。
@MainActor
enum ThumbnailCache {
    private static var cache: [String: NSImage] = [:]

    static func thumbnail(for asset: SceneAsset, maxPixel: Int = 320) -> NSImage? {
        guard let url = AppPaths.imageURL(for: asset) else { return nil }

        // 缓存键用**解析后的绝对路径**，不是 fileName。
        // 用户导入的图与预置素材可能重名（都叫 "01.jpg"），只用 fileName
        // 做键会让两张不同的图互相顶掉缩略图。
        let key = "\(url.path)@\(maxPixel)"
        if let cached = cache[key] { return cached }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }

        let image = NSImage(cgImage: cgImage, size: .zero)
        cache[key] = image
        return image
    }

    static func invalidate() {
        cache.removeAll()
    }
}
