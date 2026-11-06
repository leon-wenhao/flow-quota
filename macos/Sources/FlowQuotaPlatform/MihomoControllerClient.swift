import Darwin
import Foundation

/// Minimal read-only client for Mihomo's documented HTTP controller over a Unix socket.
/// The socket is local and user-owned; no controller secret or config mutation is used.
public struct MihomoControllerClient: Sendable {
    public typealias Request = @Sendable (String) throws -> Data
    private let request: Request

    public init(socketPath: String? = nil) {
        let path = socketPath ?? Self.defaultSocketPath
        request = MihomoUnixSocketTransport(path: path).get
    }

    init(request: @escaping Request) { self.request = request }

    public func readConnections() throws -> MihomoAPIResponse {
        let data = try request("/connections")
        return try MihomoAPIResponse.decode(data)
    }

    public static var defaultSocketPath: String {
        "/var/run/clash-verge-service/users/\(getuid())/verge-mihomo.sock"
    }
}

struct MihomoUnixSocketTransport: Sendable {
    let path: String
    static let maximumResponseBytes = 2 * 1_048_576
    static let timeoutSeconds: Int = 3

    func get(_ endpoint: String) throws -> Data {
        guard path.utf8.count < MemoryLayout<sockaddr_un>.size - 2,
              endpoint.hasPrefix("/"), !endpoint.contains("\0") else {
            throw PlatformError.unavailable("Mihomo API 地址无效。")
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw PlatformError.unavailable("无法创建 Mihomo 本地连接。") }
        defer { close(fd) }
        var timeout = timeval(tv_sec: Self.timeoutSeconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            buffer.copyBytes(from: path.utf8)
        }
        let addressLength = socklen_t(MemoryLayout<UInt8>.size + MemoryLayout<sa_family_t>.size + path.utf8.count + 1)
        address.sun_len = UInt8(addressLength)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, addressLength)
            }
        }
        guard connected == 0 else { throw PlatformError.unavailable("无法连接 Mihomo API：\(String(cString: strerror(errno)) )") }
        let request = Data("GET \(endpoint) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n".utf8)
        try sendAll(request, fd: fd)
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                recv(fd, bytes.baseAddress, bytes.count, 0)
            }
            if count == 0 { break }
            guard count > 0 else { throw PlatformError.unavailable("读取 Mihomo API 失败：\(String(cString: strerror(errno)) )") }
            response.append(buffer, count: count)
            guard response.count <= Self.maximumResponseBytes else {
                throw PlatformError.unavailable("Mihomo API 响应超过安全上限。")
            }
        }
        return try Self.body(from: response)
    }

    private func sendAll(_ data: Data, fd: Int32) throws {
        var sent = 0
        while sent < data.count {
            let count = data.withUnsafeBytes { bytes in
                send(fd, bytes.baseAddress!.advanced(by: sent), data.count - sent, 0)
            }
            guard count > 0 else { throw PlatformError.unavailable("发送 Mihomo API 请求失败。") }
            sent += count
        }
    }

    static func body(from response: Data) throws -> Data {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = response.range(of: separator) else {
            throw PlatformError.unavailable("Mihomo API 响应格式无效。")
        }
        let header = String(decoding: response[..<range.lowerBound], as: UTF8.self)
        guard header.hasPrefix("HTTP/1.1 200 ") || header.hasPrefix("HTTP/1.0 200 ") else {
            throw PlatformError.unavailable("Mihomo API 返回非成功状态。")
        }
        let body = Data(response[range.upperBound...])
        if header.localizedCaseInsensitiveContains("transfer-encoding: chunked") {
            return try decodeChunked(body)
        }
        return body
    }

    private static func decodeChunked(_ body: Data) throws -> Data {
        var cursor = body.startIndex
        var decoded = Data()
        while true {
            guard let lineEnd = body[cursor...].range(of: Data("\r\n".utf8)) else {
                throw PlatformError.unavailable("Mihomo API 分块长度无效。")
            }
            let line = String(decoding: body[cursor..<lineEnd.lowerBound], as: UTF8.self)
            let sizeText = line.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)[0]
            guard !sizeText.isEmpty, let size = Int(sizeText, radix: 16), size >= 0 else {
                throw PlatformError.unavailable("Mihomo API 分块长度无效。")
            }
            cursor = lineEnd.upperBound
            if size == 0 { return decoded }
            guard body.distance(from: cursor, to: body.endIndex) >= size + 2 else {
                throw PlatformError.unavailable("Mihomo API 分块内容不完整。")
            }
            decoded.append(body[cursor..<body.index(cursor, offsetBy: size)])
            cursor = body.index(cursor, offsetBy: size)
            guard body[cursor..<body.index(cursor, offsetBy: 2)] == Data("\r\n".utf8) else {
                throw PlatformError.unavailable("Mihomo API 分块结尾无效。")
            }
            cursor = body.index(cursor, offsetBy: 2)
            guard decoded.count <= Self.maximumResponseBytes else {
                throw PlatformError.unavailable("Mihomo API 响应超过安全上限。")
            }
        }
    }
}

public struct MihomoAPIResponse: Decodable, Sendable {
    public let uploadTotal: Int64
    public let downloadTotal: Int64
    public let connections: [MihomoAPIConnection]

    public static func decode(_ data: Data) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.uploadTotal >= 0, value.downloadTotal >= 0,
              value.connections.count <= 512 else {
            throw PlatformError.unavailable("Mihomo API 返回的连接数据无效。")
        }
        var ids = Set<String>()
        for connection in value.connections {
            guard !connection.id.isEmpty, ids.insert(connection.id).inserted,
                  connection.upload >= 0, connection.download >= 0 else {
                throw PlatformError.unavailable("Mihomo API 返回了重复或无效连接。")
            }
        }
        return value
    }
}

public struct MihomoAPIConnection: Decodable, Sendable {
    public let id: String
    public let upload: Int64
    public let download: Int64
    public let metadata: MihomoConnectionMetadata
    public let chains: [String]
    public let rule: String?
}

public struct MihomoConnectionMetadata: Decodable, Sendable {
    public let host: String?
    public let sniffHost: String?
    public let process: String?
    public let processPath: String?
    public let uid: Int64?
}
