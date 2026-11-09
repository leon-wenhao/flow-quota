import Foundation

/// Public metadata only. Releases stay invisible to this resolver until the
/// publisher has verified every anonymous asset and added the activation marker.
struct GiteeUpdateFeed {
    static let api = "https://gitee.com/api/v5/repos/Leon-wh/flow-quota"
    static let limit = 1_048_576
    typealias Loader = @Sendable (URL) async throws -> Data
    struct Release: Decodable {
        let id: Int
        let tag_name: String
        let prerelease: Bool
        let body: String
    }
    struct Asset: Decodable {
        let name: String
        let browser_download_url: URL
    }

    static func resolve(architecture: String = architecture, load: Loader = fetch) async throws -> URL {
        guard ["arm64", "x86_64"].contains(architecture) else { throw invalid("不支持的更新架构。") }
        // Gitee's /latest means most recently modified, not highest version.
        // Bound pagination and fail visibly instead of silently using old data.
        var releases: [Release] = []
        for page in 1...10 {
            let data = try await load(URL(string: api + "/releases?per_page=100&page=\(page)")!)
            guard data.count <= limit else { throw invalid("Gitee 版本信息超过大小限制。") }
            let batch = try JSONDecoder().decode([Release].self, from: data)
            releases += batch
            if batch.count < 100 { break }
            if page == 10 { throw invalid("Gitee 版本数量超过查询上限。") }
        }
        let candidates = releases.compactMap { release -> (Release, Int)? in
            guard !release.prerelease,
                  release.tag_name.range(of: #"^v[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil,
                  let marker = release.body.range(of: #"<!-- flow-quota-ready:[1-9][0-9]* -->"#, options: .regularExpression),
                  let build = Int(release.body[marker].dropFirst("<!-- flow-quota-ready:".count).dropLast(4)) else { return nil }
            return (release, build)
        }.sorted { $0.1 > $1.1 }
        guard let release = candidates.first?.0 else { throw invalid("Gitee 暂无已核验的正式更新。") }
        let data = try await load(URL(string: api + "/releases/\(release.id)/attach_files?per_page=100")!)
        guard data.count <= limit else { throw invalid("Gitee 附件信息超过大小限制。") }
        let assets = try JSONDecoder().decode([Asset].self, from: data)
        let feeds = assets.filter { $0.name == "appcast-\(architecture).xml" }
        guard feeds.count == 1, let url = feeds.first?.browser_download_url,
              url.scheme == "https", url.host == "gitee.com", url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else {
            throw invalid("Gitee 更新清单缺失或地址不受支持。")
        }
        return url
    }

    static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    static func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Ephemeral session: fallback must work without browser login/cookies.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 15
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url?.scheme == "https", response.url?.host == "gitee.com" else {
            throw invalid("Gitee 版本接口不可用。")
        }
        var result = Data()
        for try await byte in bytes {
            guard result.count < limit else { throw invalid("Gitee 版本信息超过大小限制。") }
            result.append(byte)
        }
        return result
    }

    private static func invalid(_ message: String) -> NSError {
        NSError(domain: "FlowQuota.UpdateSource", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
