import Foundation

struct AppVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    let major: Int64
    let minor: Int64
    let patch: Int64
    let build: Int64

    init(version: String, build: Int64 = 0) throws {
        let normalized = version.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        let parts = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count), parts.allSatisfy({ Int64($0) != nil }) else {
            throw UpdateCheckError.invalidVersion(version)
        }
        guard build >= 0 else { throw UpdateCheckError.invalidBuild }
        major = Int64(parts[0])!
        minor = parts.count > 1 ? Int64(parts[1])! : 0
        patch = parts.count > 2 ? Int64(parts[2])! : 0
        self.build = build
    }

    var description: String { "\(major).\(minor).\(patch) (build \(build))" }
    var marketingString: String { "\(major).\(minor).\(patch)" }

    static var current: AppVersion {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let buildString = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return (try? AppVersion(version: version, build: Int64(buildString) ?? 0))
            ?? (try! AppVersion(version: "0.1.0", build: 0))
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch, lhs.build) < (rhs.major, rhs.minor, rhs.patch, rhs.build)
    }
}

struct UpdateRelease: Equatable, Sendable {
    let version: AppVersion
    let minimumSystemVersion: String?
    let releaseNotesURL: URL?
    let downloadURL: URL
    let publishedAt: String?
}

enum UpdateCheckState: Equatable, Sendable {
    case idle
    case checking
    case upToDate
    case available(UpdateRelease)
    case failed(String)

    var message: String {
        switch self {
        case .idle: return "尚未检查更新"
        case .checking: return "正在检查更新…"
        case .upToDate: return "当前已是最新版本"
        case .available(let release): return "发现新版本：\(release.version.marketingString)"
        case .failed(let message): return message
        }
    }
}

enum UpdateCheckResult: Equatable, Sendable {
    case upToDate
    case available(UpdateRelease)
}

enum UpdateCheckError: Error, LocalizedError, Equatable, Sendable {
    case invalidVersion(String)
    case invalidBuild
    case invalidResponse
    case httpStatus(Int)
    case invalidManifest
    case incompatibleSystem(String)

    var errorDescription: String? {
        switch self {
        case .invalidVersion(let value): return "版本号无效：\(value)"
        case .invalidBuild: return "版本 build 无效。"
        case .invalidResponse: return "更新服务返回了无效响应。"
        case .httpStatus(let status): return "更新服务暂时不可用（HTTP \(status)）。"
        case .invalidManifest: return "更新清单不完整或下载地址不安全。"
        case .incompatibleSystem(let version): return "新版本需要 macOS \(version) 或更高版本。"
        }
    }
}

struct UpdateManifest: Decodable, Equatable, Sendable {
    let version: String
    let build: Int64
    let minimumSystemVersion: String?
    let releaseNotesURL: URL?
    let downloadURL: URL
    let publishedAt: String?

    func release() throws -> UpdateRelease {
        let appVersion = try AppVersion(version: version, build: build)
        guard downloadURL.scheme?.lowercased() == "https",
              downloadURL.host != nil,
              releaseNotesURL.map({ $0.scheme?.lowercased() == "https" && $0.host != nil }) ?? true else {
            throw UpdateCheckError.invalidManifest
        }
        return UpdateRelease(version: appVersion,
                             minimumSystemVersion: minimumSystemVersion,
                             releaseNotesURL: releaseNotesURL,
                             downloadURL: downloadURL,
                             publishedAt: publishedAt)
    }
}

protocol UpdateDataLoading: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: UpdateDataLoading {}

struct UpdateChecker: Sendable {
    static let defaultManifestURL = URL(string:
        "https://raw.githubusercontent.com/leon-wenhao/flow-quota/main/update-manifest.json")!

    let endpoint: URL
    private let loader: any UpdateDataLoading

    init(endpoint: URL = UpdateChecker.defaultManifestURL, loader: any UpdateDataLoading = URLSession.shared) {
        self.endpoint = endpoint
        self.loader = loader
    }

    func check(current: AppVersion, systemVersion: AppVersion? = nil) async throws -> UpdateCheckResult {
        var request = URLRequest(url: endpoint,
                                 cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("FlowQuota/\(current.marketingString)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await loader.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpdateCheckError.invalidResponse }
        guard (200...299).contains(http.statusCode) else { throw UpdateCheckError.httpStatus(http.statusCode) }

        let manifest: UpdateManifest
        do {
            manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)
        } catch {
            throw UpdateCheckError.invalidManifest
        }
        let release = try manifest.release()
        if let minimum = release.minimumSystemVersion,
           let systemVersion,
           (try AppVersion(version: minimum)) > systemVersion {
            throw UpdateCheckError.incompatibleSystem(minimum)
        }
        return release.version > current ? .available(release) : .upToDate
    }
}
