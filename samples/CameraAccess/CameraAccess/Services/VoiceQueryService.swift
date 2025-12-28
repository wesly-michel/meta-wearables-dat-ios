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
        
        // Configure audio session
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        
        // Create recognition request
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            throw VoiceQueryError.requestCreationFailed
        }
        
        recognitionRequest.shouldReportPartialResults = true
        
        // Get audio input node
        let inputNode = audioEngine.inputNode
        
        // Start recognition task
        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self = self else { return }
            
            if let result = result {
                let transcription = result.bestTranscription.formattedString
                self.currentTranscription = transcription
                
                // Send partial results
                DispatchQueue.main.async {
                    self.onPartialTranscription?(transcription)
                }
                
                // Check if final
                if result.isFinal {
                    DispatchQueue.main.async {
                        self.onFinalTranscription?(transcription)
                    }
                    Task {
                        await self.stopListening()
                    }
                }
            }
            
            if let error = error {
                print("⚠️ Recognition error: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.onError?(error)
                }
                Task {
                    await self.stopListening()
                }
            }
        }
        
        // Configure audio tap
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
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
