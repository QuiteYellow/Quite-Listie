//
//  DeeplinkCompression.swift
//  Listie-md
//
//  Compression utilities for deeplink URL encoding
//

import Foundation
import Compression

enum DeeplinkCompression {

    /// Compresses a string using zlib and returns a Base64URL-encoded string.
    /// Flow: UTF-8 data → zlib compress → Base64URL encode
    static func compress(_ string: String) -> String? {
        guard let inputData = string.data(using: .utf8) else { return nil }
        return compressData(inputData, algorithm: COMPRESSION_ZLIB)
    }

    /// Decompresses a Base64URL-encoded compressed string back to the original.
    /// Supports zlib (default) and LZMA for backward compatibility.
    /// Flow: Base64URL decode → decompress → UTF-8 string
    static func decompress(_ base64URLString: String, algorithm: compression_algorithm = COMPRESSION_ZLIB) -> String? {
        guard let compressedData = base64URLToData(base64URLString) else { return nil }
        return decompressData(compressedData, algorithm: algorithm)
    }

    // MARK: - Private

    private static func compressData(_ inputData: Data, algorithm: compression_algorithm) -> String? {
        let inputBytes = Array(inputData)
        // Compression can occasionally expand very small inputs, so add headroom
        let bufferSize = inputData.count + 512
        var outputBuffer = [UInt8](repeating: 0, count: bufferSize)

        let compressedSize = compression_encode_buffer(
            &outputBuffer,
            bufferSize,
            inputBytes,
            inputData.count,
            nil,
            algorithm
        )

        guard compressedSize > 0 else { return nil }

        let compressedData = Data(outputBuffer.prefix(compressedSize))

        // Base64URL encoding (RFC 4648 §5): + → -, / → _, strip padding =
        return compressedData
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decompressData(_ compressedData: Data, algorithm: compression_algorithm) -> String? {
        let inputBytes = Array(compressedData)

        // Progressive buffer growth: start at 10x compressed size, double up to 10 MB
        var bufferSize = max(compressedData.count * 10, 4096)
        let maxBufferSize = 10_000_000

        while bufferSize <= maxBufferSize {
            var outputBuffer = [UInt8](repeating: 0, count: bufferSize)

            let decompressedSize = compression_decode_buffer(
                &outputBuffer,
                bufferSize,
                inputBytes,
                compressedData.count,
                nil,
                algorithm
            )

            // If decompressed size fills the entire buffer, it may have been truncated
            if decompressedSize == bufferSize {
                bufferSize *= 2
                continue
            }

            guard decompressedSize > 0 else { return nil }

            let decompressedData = Data(outputBuffer.prefix(decompressedSize))
            return String(data: decompressedData, encoding: .utf8)
        }

        return nil // Exceeded maximum buffer size
    }

    private static func base64URLToData(_ base64URLString: String) -> Data? {
        // Convert Base64URL back to standard Base64
        var base64 = base64URLString
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        // Re-add padding if needed
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }

        return Data(base64Encoded: base64)
    }
}
