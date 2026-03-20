import Foundation
import CoreGraphics
import AVFoundation
import Speech
#if canImport(UIKit)
import UIKit
#endif

enum VoiceInputState: Equatable {
    case idle
    case recording
    case transcribing
}

protocol SpeechRecognitionServicing {
    func startRecognition(
        onLevelUpdate: @escaping (CGFloat) -> Void,
        onTranscriptUpdate: @escaping (String) -> Void
    ) async throws
    func stopRecognition() async throws -> String
}

enum SpeechRecognitionError: LocalizedError {
    case recognizerUnavailable
    case speechAuthorizationDenied
    case microphonePermissionDenied
    case transcriptionUnavailable

    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable:
            return String(localized: "error.speech.unavailable")
        case .speechAuthorizationDenied:
            return String(localized: "error.speech.authorization_denied")
        case .microphonePermissionDenied:
            return String(localized: "error.speech.microphone_denied")
        case .transcriptionUnavailable:
            return String(localized: "error.speech.transcription_unavailable")
        }
    }
}

@MainActor
final class SpeechRecognitionService: SpeechRecognitionServicing {
    private let audioEngine = AVAudioEngine()
#if canImport(UIKit)
    private let audioSession = AVAudioSession.sharedInstance()
#endif

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    private var latestTranscript = ""
    private var stopRequested = false
    private var stopContinuation: CheckedContinuation<String, Error>?
    private var onTranscriptUpdate: ((String) -> Void)?

    func startRecognition(
        onLevelUpdate: @escaping (CGFloat) -> Void,
        onTranscriptUpdate: @escaping (String) -> Void
    ) async throws {
        try await requestSpeechAuthorization()
        try await requestMicrophonePermission()

        let locale = Self.preferredLocale()
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw SpeechRecognitionError.recognizerUnavailable
        }

        resetState()
        self.onTranscriptUpdate = onTranscriptUpdate

        speechRecognizer = recognizer

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = false
        recognitionRequest = request

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                await self.handleRecognitionEvent(result: result, error: error)
            }
        }

        try configureAudioSessionForRecording()

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.recognitionRequest?.append(buffer)
            let level = Self.normalizedLevel(from: buffer)
            Task { @MainActor in
                onLevelUpdate(level)
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
    }

    func stopRecognition() async throws -> String {
        guard recognitionRequest != nil else {
            throw SpeechRecognitionError.transcriptionUnavailable
        }

        stopRequested = true
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        recognitionRequest?.endAudio()

        return try await withCheckedThrowingContinuation { continuation in
            stopContinuation = continuation

            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 750_000_000)
                self?.finishIfPossible()
            }
        }
    }

    private func handleRecognitionEvent(result: SFSpeechRecognitionResult?, error: Error?) async {
        if let transcript = result?.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines),
           !transcript.isEmpty {
            latestTranscript = transcript
            onTranscriptUpdate?(transcript)
        }

        if let error {
            resumeStopContinuation(with: .failure(error))
            cleanup()
            return
        }

        if stopRequested, result?.isFinal == true {
            finishIfPossible()
        }
    }

    private func finishIfPossible() {
        if !latestTranscript.isEmpty {
            resumeStopContinuation(with: .success(latestTranscript))
            cleanup()
            return
        }

        if stopRequested {
            resumeStopContinuation(with: .failure(SpeechRecognitionError.transcriptionUnavailable))
            cleanup()
        }
    }

    private func resumeStopContinuation(with result: Result<String, Error>) {
        guard let continuation = stopContinuation else { return }
        stopContinuation = nil

        switch result {
        case .success(let text):
            continuation.resume(returning: text)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    private func cleanup() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        speechRecognizer = nil
        onTranscriptUpdate = nil
        deactivateAudioSession()
        resetState()
    }

    private func resetState() {
        latestTranscript = ""
        stopRequested = false
        stopContinuation = nil
    }

    private func requestSpeechAuthorization() async throws {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { authorizationStatus in
                continuation.resume(returning: authorizationStatus)
            }
        }

        guard status == .authorized else {
            throw SpeechRecognitionError.speechAuthorizationDenied
        }
    }

    private func requestMicrophonePermission() async throws {
#if canImport(UIKit)
        let granted = await withCheckedContinuation { continuation in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            } else {
                audioSession.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }

        guard granted else {
            throw SpeechRecognitionError.microphonePermissionDenied
        }
#endif
    }

    private func configureAudioSessionForRecording() throws {
#if canImport(UIKit)
        try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
#endif
    }

    private func deactivateAudioSession() {
#if canImport(UIKit)
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
#endif
    }

    private static func preferredLocale() -> Locale {
        Locale(identifier: AppLanguage.current().speechLocaleIdentifier)
    }

    private static func normalizedLevel(from buffer: AVAudioPCMBuffer) -> CGFloat {
        guard let channelData = buffer.floatChannelData?[0] else {
            return 0.08
        }

        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else {
            return 0.08
        }

        var sum: Float = 0
        for index in 0..<frameLength {
            let sample = channelData[index]
            sum += sample * sample
        }

        let rms = sqrt(sum / Float(frameLength))
        let clamped = max(0.08, min(CGFloat(rms) * 3.2, 1))
        return clamped
    }
}
