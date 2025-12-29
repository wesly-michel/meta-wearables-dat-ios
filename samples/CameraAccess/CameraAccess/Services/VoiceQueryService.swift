/*
 * VoiceQueryService.swift
 * Ray-Ban Meta Translation App
 *
 * Handles speech-to-text conversion for voice queries.
 * Uses iOS Speech Recognition framework for real-time transcription.
 */

import Foundation
import Speech
import AVFoundation

@MainActor
class VoiceQueryService: NSObject {
    
    // MARK: - Properties
    
    private let speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    private var isListening = false
    private var currentTranscription = ""

    // Silence detection - finalize if no new transcription for this duration
    private let silenceTimeout: TimeInterval = 2.0  // 2 seconds of no new words = done speaking
    private var lastTranscriptionTime: Date?
    private var silenceTimer: Task<Void, Never>?
    
    // Callbacks
    var onPartialTranscription: ((String) -> Void)?
    var onFinalTranscription: ((String) -> Void)?
    var onError: ((Error) -> Void)?
    
    // MARK: - Initialization
    
    override init() {
        // Initialize with user's preferred language, fallback to English
        self.speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        super.init()
        
        // Check if speech recognition is available
        guard speechRecognizer != nil else {
            print("⚠️ Speech recognition not available for this locale")
            return
        }
    }
    
    // MARK: - Permission Handling
    
    /// Request speech recognition permission
    func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                switch status {
                case .authorized:
                    print("✅ Speech recognition authorized")
                    continuation.resume(returning: true)
                case .denied:
                    print("❌ Speech recognition denied")
                    continuation.resume(returning: false)
                case .restricted:
                    print("❌ Speech recognition restricted")
                    continuation.resume(returning: false)
                case .notDetermined:
                    print("⚠️ Speech recognition not determined")
                    continuation.resume(returning: false)
                @unknown default:
                    continuation.resume(returning: false)
                }
            }
        }
    }
    
    func checkAuthorizationStatus() -> SFSpeechRecognizerAuthorizationStatus {
        return SFSpeechRecognizer.authorizationStatus()
    }
    
    // MARK: - Listening Control
    
    /// Start listening for voice input
    func startListening() async throws {
        // Stop any ongoing recognition
        if isListening {
            await stopListening()
        }

        // Check authorization
        guard checkAuthorizationStatus() == .authorized else {
            throw VoiceQueryError.notAuthorized
        }

        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            throw VoiceQueryError.recognizerNotAvailable
        }

        // Audio session should already be configured by VAD with HFP
        // Just ensure it's active and log the current route
        let audioSession = AVAudioSession.sharedInstance()

        // Only configure if not already active (fallback)
        if !audioSession.isOtherAudioPlaying {
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.allowBluetooth, .defaultToSpeaker])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        }

        // Log current audio route for debugging
        let currentRoute = audioSession.currentRoute
        print("🔈 Audio input: \(currentRoute.inputs.map { "\($0.portName) (\($0.portType.rawValue))" }.joined(separator: ", "))")
        print("🔈 Audio output: \(currentRoute.outputs.map { "\($0.portName) (\($0.portType.rawValue))" }.joined(separator: ", "))")

        // Create recognition request with on-device recognition if available for better latency
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            throw VoiceQueryError.requestCreationFailed
        }

        recognitionRequest.shouldReportPartialResults = true

        // Use on-device recognition if available (better for real-time, no network latency)
        if #available(iOS 13, *) {
            recognitionRequest.requiresOnDeviceRecognition = speechRecognizer.supportsOnDeviceRecognition
            print("🎙️ On-device recognition: \(speechRecognizer.supportsOnDeviceRecognition ? "enabled" : "disabled (using server)")")
        }

        // Get audio input node
        let inputNode = audioEngine.inputNode

        // Start silence timer - will finalize if no speech detected
        startSilenceTimer()

        // Start recognition task
        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self = self else { return }

                if let result = result {
                    let transcription = result.bestTranscription.formattedString

                    // Track if we got new content
                    let hasNewContent = transcription.count > self.currentTranscription.count
                    self.currentTranscription = transcription

                    // Send partial results
                    self.onPartialTranscription?(transcription)

                    // Log partial results for debugging
                    if !transcription.isEmpty {
                        print("🎙️ Partial: '\(transcription)'")
                    }

                    // Reset silence timer when we get new content
                    if hasNewContent && !transcription.isEmpty {
                        self.lastTranscriptionTime = Date()
                        self.restartSilenceTimer()
                    }

                    // Check if final (iOS decided speech ended)
                    if result.isFinal {
                        self.silenceTimer?.cancel()
                        print("✅ Final transcription (iOS): \(transcription)")
                        self.onFinalTranscription?(transcription)
                        Task {
                            await self.stopListening()
                        }
                    }
                }

                if let error = error {
                    self.silenceTimer?.cancel()
                    let nsError = error as NSError
                    // Ignore "No speech detected" errors - just return empty and let VAD restart
                    if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1110 {
                        print("ℹ️ No speech detected - returning to listening mode")
                        // Call final transcription with empty string to signal completion
                        self.onFinalTranscription?("")
                    } else {
                        print("⚠️ Recognition error: \(error.localizedDescription)")
                        self.onError?(error)
                    }
                    Task {
                        await self.stopListening()
                    }
                }
            }
        }

        // Configure audio tap - use smaller buffer for lower latency
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        print("🎙️ Audio format: \(recordingFormat.sampleRate)Hz, \(recordingFormat.channelCount) channels")

        var bufferCount = 0
        var hasLoggedAudioLevel = false
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            bufferCount += 1

            // Log first buffer and every 50th
            if bufferCount == 1 || bufferCount % 50 == 0 {
                print("🎙️ Receiving audio buffer #\(bufferCount)")
            }

            // Log audio level once to verify we're getting real audio
            if !hasLoggedAudioLevel, let channelData = buffer.floatChannelData {
                let data = channelData.pointee
                var sum: Float = 0
                for i in 0..<Int(buffer.frameLength) {
                    sum += abs(data[i])
                }
                let avgLevel = sum / Float(buffer.frameLength)
                let dbLevel = 20 * log10(max(avgLevel, 0.0001))
                print("🎙️ Audio level: \(String(format: "%.1f", dbLevel)) dB (avg amplitude: \(String(format: "%.6f", avgLevel)))")
                hasLoggedAudioLevel = true
            }

            recognitionRequest.append(buffer)
        }

        // Start audio engine
        audioEngine.prepare()
        try audioEngine.start()

        isListening = true
        currentTranscription = ""

        print("🎤 Started listening for voice query")
    }
    
    /// Stop listening for voice input
    func stopListening() async {
        guard isListening else { return }

        // Cancel silence timer
        silenceTimer?.cancel()
        silenceTimer = nil

        // Stop audio engine
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)

        // End recognition
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()

        recognitionRequest = nil
        recognitionTask = nil

        isListening = false

        print("🛑 Stopped listening for voice query")
    }

    // MARK: - Silence Timer

    /// Start a timer that will finalize transcription after silence
    private func startSilenceTimer() {
        lastTranscriptionTime = Date()
        silenceTimer?.cancel()

        silenceTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000) // Check every 0.5 seconds

                guard let self = self, self.isListening else { break }

                if let lastTime = self.lastTranscriptionTime {
                    let elapsed = Date().timeIntervalSince(lastTime)
                    if elapsed >= self.silenceTimeout {
                        // Silence timeout - finalize what we have
                        if !self.currentTranscription.isEmpty {
                            print("⏱️ Silence timeout - finalizing: '\(self.currentTranscription)'")
                            self.onFinalTranscription?(self.currentTranscription)
                        } else {
                            print("⏱️ Silence timeout - no speech captured")
                            self.onFinalTranscription?("")
                        }
                        await self.stopListening()
                        break
                    }
                }
            }
        }
    }

    /// Restart the silence timer (called when new speech is detected)
    private func restartSilenceTimer() {
        lastTranscriptionTime = Date()
        print("⏱️ Silence timer reset")
    }
    
    /// Force finalize current transcription
    func finalizeTranscription() async {
        guard isListening else { return }
        
        recognitionRequest?.endAudio()
        
        // Give it a moment to process
        try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5 seconds
        
        if !currentTranscription.isEmpty {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.onFinalTranscription?(self.currentTranscription)
            }
        }
        
        await stopListening()
    }
    
    // MARK: - State Queries
    
    func isCurrentlyListening() -> Bool {
        return isListening
    }
    
    func getCurrentTranscription() -> String {
        return currentTranscription
    }
    
    // MARK: - Language Support
    
    /// Change recognition language
    func setLanguage(_ locale: Locale) {
        // Note: This requires reinitializing the speech recognizer
        // For now, language is set at initialization
    }
    
    static func supportedLocales() -> [Locale] {
        return SFSpeechRecognizer.supportedLocales().sorted { $0.identifier < $1.identifier }
    }
}

// MARK: - Errors

enum VoiceQueryError: Error {
    case notAuthorized
    case recognizerNotAvailable
    case requestCreationFailed
    case audioEngineError
    
    var localizedDescription: String {
        switch self {
        case .notAuthorized:
            return "Speech recognition not authorized. Please enable in Settings."
        case .recognizerNotAvailable:
            return "Speech recognizer not available"
        case .requestCreationFailed:
            return "Failed to create recognition request"
        case .audioEngineError:
            return "Audio engine error"
        }
    }
}

// MARK: - Helper Extensions

extension VoiceQueryService {
    /// Convenience method: listen for a single question with timeout
    func listenForQuestion(timeout: TimeInterval = 10.0) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            var hasResumed = false
            
            // Set up timeout
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if !hasResumed {
                    hasResumed = true
                    Task {
                        await self.stopListening()
                    }
                    continuation.resume(throwing: VoiceQueryError.audioEngineError)
                }
            }
            
            // Set up completion handler
            onFinalTranscription = { [weak self] transcription in
                if !hasResumed {
                    hasResumed = true
                    timeoutTask.cancel()
                    continuation.resume(returning: transcription)
                    self?.onFinalTranscription = nil
                }
            }
            
            // Set up error handler
            onError = { [weak self] error in
                if !hasResumed {
                    hasResumed = true
                    timeoutTask.cancel()
                    continuation.resume(throwing: error)
                    self?.onError = nil
                }
            }
            
            // Start listening
            Task {
                try? await self.startListening()
            }
        }
    }
}
