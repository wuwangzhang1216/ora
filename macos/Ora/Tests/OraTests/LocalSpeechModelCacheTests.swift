import Foundation
import XCTest
@testable import Ora

final class LocalSpeechModelCacheTests: XCTestCase {
    private func withCache(_ test: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try test(directory)
    }

    private func write(_ name: String, in directory: URL, data: Data = Data([1])) throws {
        let file = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
    }

    func testCompleteRecognitionCacheAvoidsNetworkDiscovery() throws {
        try withCache { directory in
            try write("model.safetensors", in: directory)
            for file in LocalSpeechModelCache.recognitionFiles { try write(file, in: directory) }
            XCTAssertTrue(LocalSpeechModelCache.canLoadOffline(
                from: directory, requiredFiles: LocalSpeechModelCache.recognitionFiles))
        }
    }

    func testMissingOrEmptyTokenizerStillNeedsDownload() throws {
        try withCache { directory in
            try write("model.safetensors", in: directory)
            for file in LocalSpeechModelCache.recognitionFiles where file != "merges.txt" {
                try write(file, in: directory)
            }
            XCTAssertFalse(LocalSpeechModelCache.canLoadOffline(
                from: directory, requiredFiles: LocalSpeechModelCache.recognitionFiles))
            try write("merges.txt", in: directory, data: Data())
            XCTAssertFalse(LocalSpeechModelCache.canLoadOffline(
                from: directory, requiredFiles: LocalSpeechModelCache.recognitionFiles))
        }
    }

    func testEveryIndexedWeightShardMustExist() throws {
        try withCache { directory in
            for file in LocalSpeechModelCache.recognitionFiles { try write(file, in: directory) }
            let index = Data(#"{"weight_map":{"a":"first.safetensors","b":"second.safetensors"}}"#.utf8)
            try write("model.safetensors.index.json", in: directory, data: index)
            try write("first.safetensors", in: directory)
            XCTAssertFalse(LocalSpeechModelCache.canLoadOffline(
                from: directory, requiredFiles: LocalSpeechModelCache.recognitionFiles))
            try write("second.safetensors", in: directory)
            XCTAssertTrue(LocalSpeechModelCache.canLoadOffline(
                from: directory, requiredFiles: LocalSpeechModelCache.recognitionFiles))
        }
    }

    func testCoreMLDirectoryAloneIsNotACompleteVADCache() throws {
        try withCache { directory in
            for file in LocalSpeechModelCache.vadFiles where !file.hasSuffix("weight.bin") {
                try write(file, in: directory)
            }
            XCTAssertFalse(LocalSpeechModelCache.canLoadOffline(
                from: directory, requiredFiles: LocalSpeechModelCache.vadFiles))
            try write("silero_vad.mlmodelc/weights/weight.bin", in: directory)
            XCTAssertTrue(LocalSpeechModelCache.canLoadOffline(
                from: directory, requiredFiles: LocalSpeechModelCache.vadFiles))
        }
    }
}
