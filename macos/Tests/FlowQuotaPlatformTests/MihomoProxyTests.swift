import Foundation
import Testing
@testable import FlowQuotaPlatform
import FlowQuotaCore

private let mihomoJSON = """
{
  "uploadTotal": 1000,
  "downloadTotal": 2000,
  "connections": [
    {"id":"a","upload":100,"download":200,"metadata":{"process":"Chrome","processPath":"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome","uid":501},"chains":["Proxy A"],"rule":"MATCH"}
  ]
}
"""

@Test func mihomoPayloadParsesBoundedTrafficAndProcessMetadata() throws {
    let response = try MihomoAPIResponse.decode(Data(mihomoJSON.utf8))
    #expect(response.uploadTotal == 1000)
    #expect(response.downloadTotal == 2000)
    #expect(response.connections.first?.metadata.process == "Chrome")
    #expect(response.connections.first?.upload == 100)
}

@Test func mihomoAccumulatorBaselinesThenCountsContinuousDeltasBySource() throws {
    let response = try MihomoAPIResponse.decode(Data(mihomoJSON.utf8))
    var accumulator = MihomoProxyAccumulator()
    let first = try accumulator.consume(response, scope: "socket", capturedAt: Date(timeIntervalSince1970: 100))
    #expect(first.uploadedBytes == 0)
    #expect(first.downloadedBytes == 0)
    let nextJSON = mihomoJSON.replacingOccurrences(of: "1000", with: "1500")
        .replacingOccurrences(of: "2000", with: "2600")
        .replacingOccurrences(of: "\"upload\":100", with: "\"upload\":140")
        .replacingOccurrences(of: "\"download\":200", with: "\"download\":260")
    let next = try accumulator.consume(try MihomoAPIResponse.decode(Data(nextJSON.utf8)),
        scope: "socket", capturedAt: Date(timeIntervalSince1970: 102))
    #expect(next.uploadedBytes == 500)
    #expect(next.downloadedBytes == 600)
    #expect(next.sources.first?.displayName == "Google Chrome（Clash）")
    #expect(next.sources.first?.uploadedBytes == 40)
    #expect(next.sources.first?.downloadedBytes == 60)
}

@Test func mihomoAccumulatorRebaselinesOnRestartAndRejectsBadPayload() throws {
    let response = try MihomoAPIResponse.decode(Data(mihomoJSON.utf8))
    var accumulator = MihomoProxyAccumulator()
    _ = try accumulator.consume(response, scope: "socket", capturedAt: Date())
    let restart = try accumulator.consume(response, scope: "new-socket", capturedAt: Date())
    #expect(restart.uploadedBytes == 0)
    #expect(restart.downloadedBytes == 0)
    let bad = "{\"uploadTotal\":0,\"downloadTotal\":0,\"connections\":[{\"id\":\"a\",\"upload\":-1,\"download\":0,\"metadata\":{},\"chains\":[]}] }"
    #expect(throws: (any Error).self) { try MihomoAPIResponse.decode(Data(bad.utf8)) }
}

@Test func mihomoControllerUsesReadOnlyConnectionsEndpoint() throws {
    let client = MihomoControllerClient(request: { endpoint in
        #expect(endpoint == "/connections")
        return Data(mihomoJSON.utf8)
    })
    #expect(try client.readConnections().connections.count == 1)
}

@Test func mihomoTransportDecodesChunkedHTTPResponse() throws {
    let json = Data(mihomoJSON.utf8)
    let split = json.count / 2
    let first = json.prefix(split)
    let second = json.dropFirst(split)
    let response = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)
        + Data(String(split, radix: 16).utf8) + Data("\r\n".utf8) + first
        + Data("\r\n".utf8) + Data(String(second.count, radix: 16).utf8) + Data("\r\n".utf8) + second
        + Data("\r\n0\r\n\r\n".utf8)
    #expect(try MihomoUnixSocketTransport.body(from: response) == json)
}
