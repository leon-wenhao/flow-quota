import CryptoKit
import Foundation

struct Request: Decodable {
    let file: String
    let signature: String
    let length: Int?
}

do {
    guard CommandLine.arguments.count == 2,
          let keyData = Data(base64Encoded: CommandLine.arguments[1]) else {
        throw CocoaError(.fileReadCorruptFile)
    }
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
    let requests = try JSONDecoder().decode([Request].self, from: FileHandle.standardInput.readDataToEndOfFile())
    for request in requests {
        guard let signature = Data(base64Encoded: request.signature), signature.count == 64 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: request.file), options: .mappedIfSafe)
        let count = request.length ?? data.count
        guard count >= 0, count <= data.count,
              key.isValidSignature(signature, for: data.prefix(count)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }
} catch {
    FileHandle.standardError.write(Data("Ed25519 signature validation failed.\n".utf8))
    exit(1)
}
