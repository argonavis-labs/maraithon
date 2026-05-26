import XCTest
@testable import Maraithon

/// Stub recognizer the transcriber tests inject through
/// `VoiceMemosTranscriber.init(recognizerFactory:)`. Every behavior the
/// transcriber cares about is exposed as a knob so each test can target
/// one failure mode in isolation.
private struct StubRecognizer: SpeechRecognizing {
    let isAvailable: Bool
    let supportsOnDeviceRecognition: Bool
    let result: Result<String, Error>

    func recognize(url: URL) async throws -> String {
        try result.get()
    }
}

private struct StubError: Error, Equatable {
    let label: String
}

final class VoiceMemosTranscriberTests: XCTestCase {

    func testReturnsSuccessForHappyPath() async {
        let transcriber = VoiceMemosTranscriber(
            recognizerFactory: { _ in
                StubRecognizer(
                    isAvailable: true,
                    supportsOnDeviceRecognition: true,
                    result: .success("  hello world  ")
                )
            },
            authorizationProbe: { .authorized }
        )

        let url = URL(fileURLWithPath: "/tmp/fake.m4a")
        let outcome = await transcriber.transcribe(url: url)

        XCTAssertEqual(
            outcome,
            .success(text: "hello world", locale: "en-US", engine: "sf_speech")
        )
    }

    func testTreatsEmptyTranscriptionAsEmptyOutcome() async {
        let transcriber = VoiceMemosTranscriber(
            recognizerFactory: { _ in
                StubRecognizer(
                    isAvailable: true,
                    supportsOnDeviceRecognition: true,
                    result: .success("   \n   ")
                )
            },
            authorizationProbe: { .authorized }
        )

        let outcome = await transcriber.transcribe(
            url: URL(fileURLWithPath: "/tmp/fake.m4a")
        )

        XCTAssertEqual(outcome, .empty(locale: "en-US", engine: "sf_speech"))
    }

    func testReturnsUnavailableWhenAuthorizationDenied() async {
        let transcriber = VoiceMemosTranscriber(
            recognizerFactory: { _ in
                XCTFail("Should not build a recognizer when auth is denied")
                return nil
            },
            authorizationProbe: { .denied }
        )

        let outcome = await transcriber.transcribe(
            url: URL(fileURLWithPath: "/tmp/fake.m4a")
        )

        XCTAssertEqual(outcome, .unavailable(reason: "speech_recognition_denied"))
    }

    func testReturnsUnavailableWhenRecognizerIsNil() async {
        let transcriber = VoiceMemosTranscriber(
            recognizerFactory: { _ in nil },
            authorizationProbe: { .authorized }
        )

        let outcome = await transcriber.transcribe(
            url: URL(fileURLWithPath: "/tmp/fake.m4a")
        )

        XCTAssertEqual(
            outcome,
            .unavailable(reason: "recognizer_unavailable_for_locale")
        )
    }

    func testRefusesWhenOnDeviceUnsupported() async {
        // The whole point of the v1.5 design is that audio never leaves
        // the device for transcription, so a recognizer that can only do
        // cloud requests should be skipped entirely.
        let transcriber = VoiceMemosTranscriber(
            recognizerFactory: { _ in
                StubRecognizer(
                    isAvailable: true,
                    supportsOnDeviceRecognition: false,
                    result: .success("would be sent to apple servers")
                )
            },
            authorizationProbe: { .authorized }
        )

        let outcome = await transcriber.transcribe(
            url: URL(fileURLWithPath: "/tmp/fake.m4a")
        )

        XCTAssertEqual(
            outcome,
            .unavailable(reason: "on_device_recognition_unsupported")
        )
    }

    func testWrapsRecognizerErrorAsFailed() async {
        let transcriber = VoiceMemosTranscriber(
            recognizerFactory: { _ in
                StubRecognizer(
                    isAvailable: true,
                    supportsOnDeviceRecognition: true,
                    result: .failure(StubError(label: "boom"))
                )
            },
            authorizationProbe: { .authorized }
        )

        let outcome = await transcriber.transcribe(
            url: URL(fileURLWithPath: "/tmp/fake.m4a")
        )

        if case .failed(let reason) = outcome {
            XCTAssertTrue(reason.contains("boom"), "Got: \(reason)")
        } else {
            XCTFail("Expected .failed, got \(outcome)")
        }
    }
}
