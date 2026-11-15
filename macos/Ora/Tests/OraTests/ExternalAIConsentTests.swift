import XCTest
@testable import Ora

final class ExternalAIConsentTests: XCTestCase {
    func testLocalProcessingDoesNotRequestSharing() {
        for recognition in [RecognitionBackendKind.local, .nemotron, .appleSpeech] {
            XCTAssertTrue(ExternalAIUsage.services(recognition: recognition, translation: .mlxSwift,
                realRouterURL: "https://example.com", rapidMLXURL: "http://localhost:8000").isEmpty)
        }
    }

    func testAudioAndTranslationRecipientsAreDisclosedSeparately() {
        let services = ExternalAIUsage.services(recognition: .realRouter, translation: .rapidMLX,
            realRouterURL: "https://speech.example", rapidMLXURL: "http://127.0.0.1:8000/v1")
        XCTAssertEqual(services, [
            .init(server: "https://speech.example", sendsAudio: true, sendsText: false),
            .init(server: "http://127.0.0.1:8000/v1", sendsAudio: false, sendsText: true)])
    }

    func testOneProviderDisclosesBothDataTypesAndSnapshotRetainsRecipient() {
        var configuredURL = "https://first.example"
        let services = ExternalAIUsage.services(recognition: .realRouter, translation: .realRouter,
            realRouterURL: configuredURL, rapidMLXURL: "unused")
        configuredURL = "https://second.example"
        XCTAssertEqual(services.count, 1)
        XCTAssertTrue(services[0].sendsAudio)
        XCTAssertTrue(services[0].sendsText)
        XCTAssertTrue(services[0].disclosure.contains("https://first.example"))
        XCTAssertFalse(services[0].disclosure.contains(configuredURL))
    }
}
