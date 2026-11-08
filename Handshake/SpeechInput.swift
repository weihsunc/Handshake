import Foundation
import Speech
import AVFoundation
import Observation

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - SpeechInput
//
// Dictation for the chat bar: tap the mic, talk, text appears in the field.
// Wraps SFSpeechRecognizer + AVAudioEngine. Partial results stream in as the
// user speaks (formattedString is cumulative, so the caller replaces, not
// appends). The mic button was a dead image before this.
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
@Observable
final class SpeechInput {

    private(set) var isRecording = false
    var errorText: String? = nil

    private let recognizer = SFSpeechRecognizer()
    private let engine     = AVAudioEngine()
    private var request:   SFSpeechAudioBufferRecognitionRequest?
    private var task:      SFSpeechRecognitionTask?

    /// Asks for speech + microphone permission (first time only), then records.
    func start(onText: @escaping @MainActor (String) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in
                guard status == .authorized else {
                    self.errorText = String(localized: "Speech recognition isn't allowed. You can enable it in Settings.")
                    return
                }
                AVAudioApplication.requestRecordPermission { granted in
                    Task { @MainActor in
                        guard granted else {
                            self.errorText = String(localized: "Microphone access isn't allowed. You can enable it in Settings.")
                            return
                        }
                        self.begin(onText: onText)
                    }
                }
            }
        }
    }

    private func begin(onText: @escaping @MainActor (String) -> Void) {
        guard let recognizer, recognizer.isAvailable else {
            errorText = String(localized: "Speech recognition isn't available right now.")
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            errorText = String(localized: "Couldn't start the microphone.")
            return
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        request = req

        let input  = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            req.append(buffer)
        }
        engine.prepare()
        do { try engine.start() } catch {
            errorText = String(localized: "Couldn't start the microphone.")
            return
        }
        isRecording = true

        task = recognizer.recognitionTask(with: req) { result, error in
            Task { @MainActor in
                if let result { onText(result.bestTranscription.formattedString) }
                if let error {
                    // A user-initiated stop() has already cleared isRecording
                    // before the cancel callback lands; anything else is a real
                    // failure the user needs to hear about — otherwise the mic
                    // just flips back and looks like nothing happened.
                    if self.isRecording {
                        self.errorText = Self.friendly(error)
                    }
                    self.stop()
                } else if result?.isFinal == true {
                    self.stop()
                }
            }
        }
    }

    private static func friendly(_ error: Error) -> String {
        let ns = error as NSError
        // kAFAssistantErrorDomain 1110 = no speech detected; 216/1101 = input
        // unavailable. All of them mean the same thing to the user.
        if ns.domain == "kAFAssistantErrorDomain" || ns.domain == "kLSRErrorDomain" {
            return String(localized: "Couldn't hear anything. Check the microphone and try again.")
        }
        return String(localized: "Dictation stopped: \(ns.localizedDescription)")
    }

    func stop() {
        guard isRecording || request != nil else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task    = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
