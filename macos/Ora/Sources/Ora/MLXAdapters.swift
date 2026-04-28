// Vendored from DePasqualeOrg/swift-hf-api-mlx and swift-tokenizers-mlx (MIT),
// rewritten to target HuggingFace's swift-transformers instead of
// DePasqualeOrg/swift-tokenizers. We vendor because the upstream -mlx adapters
// pin mlx-swift-lm to conflicting SHAs (documented upstream TODOs).
//
// Bridges HFAPI.HubClient + Tokenizers.Tokenizer (swift-transformers) to
// MLXLMCommon.Downloader / MLXLMCommon.Tokenizer protocols.

import Foundation
import HFAPI
import MLXLMCommon
import Tokenizers

// MARK: - HubClient as Downloader

public enum HuggingFaceDownloaderError: LocalizedError {
    case invalidRepositoryID(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRepositoryID(let id):
            return "Invalid Hugging Face repository ID: '\(id)'. Expected format 'namespace/name'."
        }
    }
}

extension HubClient: @retroactive Downloader {
    public func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        guard let repoID = Repo.ID(rawValue: id) else {
            throw HuggingFaceDownloaderError.invalidRepositoryID(id)
        }
        let revision = revision ?? "main"

        if !useLatest {
            if let cached = resolveCachedSnapshot(
                repo: repoID,
                revision: revision,
                matching: patterns
            ) {
                return cached
            }
        }

        return try await downloadSnapshot(
            of: repoID,
            revision: revision,
            matching: patterns,
            progressHandler: progressHandler
        )
    }
}

// MARK: - Tokenizer bridge (swift-transformers → MLXLMCommon)

struct TokenizerBridge: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        // swift-transformers uses the label `tokens:` instead of `tokenIds:`
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages,
                tools: tools,
                additionalContext: additionalContext
            )
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

public struct TokenizersLoader: TokenizerLoader {
    public init() {}

    public func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        // swift-transformers uses `modelFolder:` rather than `directory:`
        let upstream = try await AutoTokenizer.from(modelFolder: directory)
        return TokenizerBridge(upstream)
    }
}
