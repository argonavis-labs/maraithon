/// Short on-device voice capture. Audio is never uploaded and transcription remains editable.
import AVFoundation
import Observation
import Speech

@MainActor @Observable
final class ContextDictation {
    private(set) var recording = false
    private(set) var starting = false
    private(set) var transcript = ""
    private(set) var error: String?
    private var engine: AVAudioEngine?
    private var recognition: SFSpeechRecognitionTask?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var deadline: Task<Void, Never>?
    private var generation = UUID()

    func start() async {
        guard !recording, !starting else { return }
        starting = true; error = nil; transcript = ""
        let captureID = UUID()
        generation = captureID
        defer { starting = false }
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        let microphone = await AVCaptureDevice.requestAccess(for: .audio)
        guard generation == captureID, !Task.isCancelled else { return }
        guard speech, microphone else {
            error = "Enable Microphone and Speech Recognition in Settings, or type your note."
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: .current), recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else {
            error = "On-device dictation isn't available for this language. You can type your note."
            return
        }
        do {
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true)
            #endif
            let engine = AVAudioEngine()
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = true
            request.addsPunctuation = true
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw URLError(.cannotLoadFromNetwork) }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
            self.engine = engine; self.request = request
            recognition = recognizer.recognitionTask(with: request) { [weak self] result, failure in
                let text = result?.bestTranscription.formattedString
                let finished = result?.isFinal == true
                let failed = failure != nil
                Task { @MainActor [weak self] in
                    guard let self, self.generation == captureID else { return }
                    if let text { self.transcript = text }
                    if finished || failed {
                        if failed, self.recording, self.transcript.isEmpty {
                            self.error = "Dictation couldn't finish. Try again or type your note."
                        }
                        self.stop()
                    }
                }
            }
            engine.prepare()
            try engine.start()
            recording = true
            deadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(55)) } catch { return }
                self?.stop()
            }
        } catch {
            stop()
            self.error = "The microphone couldn't start. Try again or type your note."
        }
    }

    func stop() {
        generation = UUID()
        deadline?.cancel(); deadline = nil
        engine?.stop()
        if let engine { engine.inputNode.removeTap(onBus: 0) }
        request?.endAudio()
        recognition?.cancel()
        engine = nil; request = nil; recognition = nil; recording = false
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}
