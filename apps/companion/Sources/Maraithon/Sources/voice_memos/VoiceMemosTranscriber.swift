import Foundation
import Speech

/// On-device transcription of a single `.m4a` file via `SFSpeechRecognizer`.
///
/// Privacy is the whole point: `requiresOnDeviceRecognition = true` is
/// hard-set on every recognition request, so audio bytes never leave the
/// machine for transcription. If the user hasn't authorized speech
/// recognition or the on-device model for `en-US` isn't installed, the
/// transcriber returns a `.unavailable` result and the source carries on
/// without a transcript — the audio bytes still ship to the server, where
/// transcription can be re-attempted later if needed.
///
/// v1.5 scope: English (`en-US`) only. Locale negotiation, multi-language
/// recognizers, and progressive partial-result streaming are deliberately
/// out of scope; the simpler API surface keeps the source's transcription
/// step a single `await transcriber.transcribe(url:)` call.
struct VoiceMemosTranscriber: Sendable {
    /// Result of a single transcription attempt. `unavailable` covers
    /// every "we won't try" case (no authorization, no on-device model,
    /// recognizer not available for the locale) so the source can treat
    /// the missing-transcript path uniformly.
    enum Outcome: Sendable, Equatable {
        case success(text: String, locale: String, engine: String)
        case empty(locale: String, engine: String)
        case unavailable(reason: String)
        case failed(reason: String)
    }

    /// Locale we attempt recognition under. Exposed so tests can read
    /// what the source-level transcriber will emit on the wire.
    let locale: Locale
    /// Engine identifier sent to the server as `transcript_engine`. Kept
    /// here so callers don't hard-code the string in multiple places.
    let engine: String
    /// Hook for injecting a fake recognizer in tests. Production callers
    /// use `init()` which wires the real `SFSpeechRecognizer`.
    private let recognizerFactory: @Sendable (Locale) -> SpeechRecognizing?
    private let authorizationProbe: @Sendable () async -> SFSpeechRecognizerAuthorizationStatus

    init(
        locale: Locale = Locale(identifier: "en-US"),
        engine: String = "sf_speech",
        recognizerFactory: @escaping @Sendable (Locale) -> SpeechRecognizing? = {
            SFSpeechRecognizer(locale: $0).map(SystemSpeechRecognizer.init(wrapped:))
        },
        authorizationProbe: @escaping @Sendable () async -> SFSpeechRecognizerAuthorizationStatus = {
            await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
        }
    ) {
        self.locale = locale
        self.engine = engine
        self.recognizerFactory = recognizerFactory
        self.authorizationProbe = authorizationProbe
    }

    /// Transcribe a single audio file. Always falls back gracefully —
    /// the source never crashes on a recognizer that's missing or
    /// returning errors. Returns `Outcome.unavailable` when the OS
    /// hasn't authorized speech recognition or the on-device model
    /// isn't ready; the caller still uploads the audio bytes so the
    /// transcript can be filled in later.
    func transcribe(url: URL) async -> Outcome {
        let status = await authorizationProbe()
        switch status {
        case .authorized:
            break
        case .denied:
            return .unavailable(reason: "speech_recognition_denied")
        case .restricted:
            return .unavailable(reason: "speech_recognition_restricted")
        case .notDetermined:
            return .unavailable(reason: "speech_recognition_not_determined")
        @unknown default:
            return .unavailable(reason: "speech_recognition_unknown_status")
        }

        guard let recognizer = recognizerFactory(locale) else {
            return .unavailable(reason: "recognizer_unavailable_for_locale")
        }
        guard recognizer.isAvailable else {
            return .unavailable(reason: "recognizer_not_available")
        }
        guard recognizer.supportsOnDeviceRecognition else {
            // We refuse to send audio to Apple's servers even if the
            // OS would happily do it — the whole feature is "this
            // never leaves the machine for transcription".
            return .unavailable(reason: "on_device_recognition_unsupported")
        }

        let localeID = locale.identifier
        do {
            // Hard cap: SFSpeechRecognizer occasionally never delivers a
            // final result on macOS (model download mid-recognition,
            // sandbox quirks, etc). Without a timeout the entire voice
            // memos cycle stalls forever on one bad recording. 120s is
            // generous — well over real-time for any reasonable note —
            // and on timeout we just upload the audio bytes for later.
            let text = try await Self.withTimeout(seconds: 120) {
                try await recognizer.recognize(url: url)
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return .empty(locale: localeID, engine: engine)
            }
            return .success(text: trimmed, locale: localeID, engine: engine)
        } catch is TimeoutError {
            return .failed(reason: "timed_out")
        } catch {
            return .failed(reason: String(describing: error))
        }
    }

    private struct TimeoutError: Error {}

    private static func withTimeout<T: Sendable>(
        seconds: Double,
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimeoutError()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}

/// Protocol abstraction over `SFSpeechRecognizer` so tests can inject a
/// stub without instantiating the real recognizer (which needs a live
/// system and signed entitlements). Kept internal — production code goes
/// through `SystemSpeechRecognizer` below.
protocol SpeechRecognizing: Sendable {
    var isAvailable: Bool { get }
    var supportsOnDeviceRecognition: Bool { get }
    func recognize(url: URL) async throws -> String
}

/// Real `SFSpeechRecognizer`-backed implementation. Runs the request with
/// `requiresOnDeviceRecognition = true`, which is the only mode this
/// transcriber ever supports.
struct SystemSpeechRecognizer: SpeechRecognizing, @unchecked Sendable {
    let wrapped: SFSpeechRecognizer

    var isAvailable: Bool { wrapped.isAvailable }
    var supportsOnDeviceRecognition: Bool { wrapped.supportsOnDeviceRecognition }

    func recognize(url: URL) async throws -> String {
        let recognizer = wrapped
        return try await withCheckedThrowingContinuation { continuation in
            let request = SFSpeechURLRecognitionRequest(url: url)
            request.shouldReportPartialResults = false
            request.requiresOnDeviceRecognition = true
            // Hold the task so it can be retained for the duration of
            // the callback. The recognizer cancels in-flight requests
            // when the task reference drops, so we keep it alive in a
            // local until the continuation resumes.
            var hasResumed = false
            let lock = NSLock()
            let resumeOnce: (Result<String, Error>) -> Void = { result in
                lock.lock()
                defer { lock.unlock() }
                guard !hasResumed else { return }
                hasResumed = true
                continuation.resume(with: result)
            }

            let task = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    resumeOnce(.failure(error))
                    return
                }
                guard let result else { return }
                if result.isFinal {
                    resumeOnce(.success(result.bestTranscription.formattedString))
                }
            }
            // Retain the task until the callback fires; without this the
            // recognition task is deallocated immediately and the
            // recognizer never delivers a final result.
            _ = task
        }
    }
}
