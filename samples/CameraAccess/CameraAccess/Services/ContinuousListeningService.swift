/*
 * ContinuousListeningService.swift
 * Ray-Ban Meta Translation App
 *
 * Unified always-on listening service that combines VAD and Speech Recognition.
 * Runs speech recognition continuously to eliminate handoff delays.
 * Uses audio level analysis to detect when user finishes speaking.
 */

import Foundation
import Speech
import AVFoundation

@MainActor
class ContinuousListeningService: NSObject {

    // MARK: - Properties

    private let speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    private var isRunning = false
    private var isPaused = false  // Track if we're paused (during TTS)
    private var currentTranscription = ""
    private var isProcessingQuery = false  // Prevents overlapping query processing
    private var hasTapInstalled = false  // Track tap state to prevent double-install

    // VAD parameters (now built-in)
    private let silenceThresholdDB: Float = -40.0  // dB threshold for silence
    private let speechConfirmDuration: TimeInterval = 0.25  // How long speech must be detected before we consider it real
    private let silenceFinalizeDuration: TimeInterval = 1.8  // Silence duration to finalize transcription

    // State tracking
    private var isSpeechActive = false
    private var speechStartTime: Date?
    private var lastSpeechTime: Date?
    private var lastTranscriptionUpdateTime: Date?

    // Silence monitoring task
    private var silenceMonitorTask: Task<Void, Never>?

    // Callbacks
    var onListeningStarted: (() -> Void)?
    var onSpeechDetected: (() -> Void)?  // User started speaking
    var onPartialTranscription: ((String) -> Void)?
    var onFinalTranscription: ((String) -> Void)?  // Ready to process query
    var onAudioLevel: ((Float) -> Void)?  // For UI visualization
    var onError: ((Error) -> Void)?

    // MARK: - Initialization

    override init() {
        self.speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        super.init()

        guard speechRecognizer != nil else {
            print("⚠️ Speech recognition not available for this locale")
            return
        }
    }

    // MARK: - Permission Handling

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

    // MARK: - Continuous Listening Control

    /// Start continuous listening - runs until explicitly stopped
    func startListening() async throws {
        guard !isRunning else {
            print("⚠️ Already listening")
            return
        }

        // Check authorization
        guard checkAuthorizationStatus() == .authorized else {
            throw ContinuousListeningError.notAuthorized
        }

        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            throw ContinuousListeningError.recognizerNotAvailable
        }

        // Configure audio session for HFP (Ray-Ban glasses)
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP, .defaultToSpeaker])
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        // Log audio route
        let currentRoute = audioSession.currentRoute
        print("🔈 Continuous Listening - Input: \(currentRoute.inputs.map { "\($0.portName) (\($0.portType.rawValue))" }.joined(separator: ", "))")
        print("🔈 Continuous Listening - Output: \(currentRoute.outputs.map { "\($0.portName) (\($0.portType.rawValue))" }.joined(separator: ", "))")

        // Start speech recognition
        try await startRecognitionSession()

        isRunning = true
        isProcessingQuery = false

        // Start silence monitoring
        startSilenceMonitor()

        print("🎤 Continuous Listening started - always on, no wake word needed")
        onListeningStarted?()
    }

    /// Stop continuous listening completely
    func stopListening() async {
        guard isRunning else { return }

        // Cancel silence monitor
        silenceMonitorTask?.cancel()
        silenceMonitorTask = nil

        // Stop audio engine and remove tap safely
        cleanupAudioEngine()

        // End recognition
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()

        recognitionRequest = nil
        recognitionTask = nil

        // Deactivate audio session
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("⚠️ Failed to deactivate audio session: \(error)")
        }

        isRunning = false
        isPaused = false
        isSpeechActive = false
        currentTranscription = ""
        speechStartTime = nil
        lastSpeechTime = nil

        print("🛑 Continuous Listening stopped")
    }

    /// Safely cleanup audio engine and remove tap
    private func cleanupAudioEngine() {
        if hasTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasTapInstalled = false
        }
        if audioEngine.isRunning {
            audioEngine.stop()
        }
    }

    /// Pause listening (during TTS playback) - keeps audio session alive
    func pauseListening() async {
        guard isRunning, !isPaused else { return }

        print("⏸️ Pausing continuous listening")
        isPaused = true

        // Cancel silence monitor first
        silenceMonitorTask?.cancel()
        silenceMonitorTask = nil

        // Stop audio engine and remove tap safely
        cleanupAudioEngine()

        // End recognition task
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil

        // Reset state but keep isRunning true
        isSpeechActive = false
        currentTranscription = ""
        speechStartTime = nil
        lastSpeechTime = nil
        lastTranscriptionUpdateTime = nil
    }

    /// Resume listening after pause (after TTS completes)
    func resumeListening() async throws {
        guard isRunning else {
            try await startListening()
            return
        }

        guard isPaused else {
            print("⚠️ Not paused, nothing to resume")
            return
        }

        print("▶️ Resuming continuous listening")

        // Ensure audio engine is fully stopped before resuming
        cleanupAudioEngine()

        isProcessingQuery = false
        isPaused = false

        // Longer delay to ensure everything is cleaned up
        try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5 seconds

        // Restart recognition session
        try await startRecognitionSession()

        // Restart silence monitor
        startSilenceMonitor()
    }

    // MARK: - Private Methods

    private func startRecognitionSession() async throws {
        guard let speechRecognizer = speechRecognizer else {
            throw ContinuousListeningError.recognizerNotAvailable
        }

        // Ensure we don't have a tap already installed
        if hasTapInstalled {
            print("⚠️ Tap already installed, cleaning up first")
            cleanupAudioEngine()
        }

        // Create recognition request
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            throw ContinuousListeningError.requestCreationFailed
        }

        recognitionRequest.shouldReportPartialResults = true

        // Use on-device recognition if available
        if #available(iOS 13, *) {
            recognitionRequest.requiresOnDeviceRecognition = speechRecognizer.supportsOnDeviceRecognition
            print("🎙️ On-device recognition: \(speechRecognizer.supportsOnDeviceRecognition ? "enabled" : "disabled")")
        }

        // Get audio input node
        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        print("🎙️ Audio format: \(recordingFormat.sampleRate)Hz, \(recordingFormat.channelCount) channels")

        // Start recognition task
        recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self = self else { return }

                // Ignore results if paused (TTS is playing, might pick up TTS audio)
                guard !self.isPaused else { return }

                if let result = result {
                    let transcription = result.bestTranscription.formattedString

                    // Check if we got new content
                    if transcription.count > self.currentTranscription.count {
                        self.lastTranscriptionUpdateTime = Date()

                        // If this is first real transcription, mark speech as truly active
                        if self.currentTranscription.isEmpty && !transcription.isEmpty {
                            print("🎙️ First words detected: '\(transcription)'")
                        }
                    }

                    self.currentTranscription = transcription

                    if !transcription.isEmpty {
                        self.onPartialTranscription?(transcription)
                    }

                    // iOS decided speech ended (final result)
                    if result.isFinal && !self.isProcessingQuery {
                        self.handleFinalTranscription(transcription, source: "iOS final")
                    }
                }

                if let error = error {
                    let nsError = error as NSError

                    // Ignore errors if paused
                    guard !self.isPaused else { return }

                    // Ignore "No speech detected" - just restart (but not if paused)
                    if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1110 {
                        print("ℹ️ No speech detected - restarting recognition")
                        Task {
                            try? await self.restartRecognitionSession()
                        }
                    } else {
                        print("⚠️ Recognition error: \(error.localizedDescription)")
                        self.onError?(error)
                    }
                }
            }
        }

        // Install audio tap - single tap handles both VAD and speech recognition
        var bufferCount = 0
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            bufferCount += 1

            // Send audio to speech recognizer
            recognitionRequest.append(buffer)

            // Process audio for VAD (level detection)
            self?.processAudioBuffer(buffer, bufferCount: bufferCount)
        }
        hasTapInstalled = true

        // Start audio engine
        audioEngine.prepare()
        try audioEngine.start()

        // Reset state
        currentTranscription = ""
        isSpeechActive = false
        speechStartTime = nil
        lastSpeechTime = nil
        lastTranscriptionUpdateTime = nil
    }

    private func restartRecognitionSession() async throws {
        // Don't restart if paused (TTS is playing)
        guard !isPaused else {
            print("⏸️ Skipping restart - paused for TTS")
            return
        }

        // Stop current session safely
        cleanupAudioEngine()

        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil

        // Small delay before restart
        try? await Task.sleep(nanoseconds: 300_000_000)  // 0.3 seconds

        // Double-check we're not paused before restarting
        guard !isPaused else {
            print("⏸️ Skipping restart - paused during delay")
            return
        }

        // Start new session
        try await startRecognitionSession()
    }

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer, bufferCount: Int) {
        guard let channelData = buffer.floatChannelData else { return }

        let channelDataValue = channelData.pointee
        let channelDataValueArray = stride(
            from: 0,
            to: Int(buffer.frameLength),
            by: buffer.stride
        ).map { channelDataValue[$0] }

        // Calculate RMS
        let rms = sqrt(channelDataValueArray.map { $0 * $0 }.reduce(0, +) / Float(buffer.frameLength))

        // Convert to decibels
        let avgPower = 20 * log10(max(rms, 0.0001))

        // Notify UI of audio level
        DispatchQueue.main.async { [weak self] in
            self?.onAudioLevel?(avgPower)
        }

        // Log occasionally
        if bufferCount == 1 || bufferCount % 100 == 0 {
            print("🎙️ Audio buffer #\(bufferCount), level: \(String(format: "%.1f", avgPower)) dB")
        }

        // VAD: Detect speech vs silence
        let isSpeechDetected = avgPower > silenceThresholdDB

        DispatchQueue.main.async { [weak self] in
            self?.updateSpeechState(isSpeechDetected: isSpeechDetected)
        }
    }

    private func updateSpeechState(isSpeechDetected: Bool) {
        let now = Date()

        if isSpeechDetected {
            lastSpeechTime = now

            if !isSpeechActive {
                // Potential start of speech
                if speechStartTime == nil {
                    speechStartTime = now
                } else if let startTime = speechStartTime,
                          now.timeIntervalSince(startTime) >= speechConfirmDuration {
                    // Speech confirmed
                    isSpeechActive = true
                    print("🎤 Speech activity detected")
                    onSpeechDetected?()
                }
            }
        } else {
            // Silence detected
            if !isSpeechActive {
                // Reset potential speech start if too short
                speechStartTime = nil
            }
            // If speech is active, silence monitor will handle finalization
        }
    }

    private func startSilenceMonitor() {
        silenceMonitorTask?.cancel()

        silenceMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)  // Check every 0.2 seconds

                guard let self = self, self.isRunning, !self.isProcessingQuery else { break }

                // Check for silence after speech
                if self.isSpeechActive, let lastSpeech = self.lastSpeechTime {
                    let silenceDuration = Date().timeIntervalSince(lastSpeech)

                    if silenceDuration >= self.silenceFinalizeDuration {
                        // User stopped speaking
                        if !self.currentTranscription.isEmpty {
                            self.handleFinalTranscription(self.currentTranscription, source: "silence timeout")
                        } else {
                            // Reset for next utterance
                            self.isSpeechActive = false
                            self.speechStartTime = nil
                        }
                    }
                }

                // Also check if we have transcription but no recent updates
                if let lastUpdate = self.lastTranscriptionUpdateTime,
                   !self.currentTranscription.isEmpty,
                   !self.isProcessingQuery {
                    let timeSinceUpdate = Date().timeIntervalSince(lastUpdate)
                    if timeSinceUpdate >= self.silenceFinalizeDuration {
                        self.handleFinalTranscription(self.currentTranscription, source: "transcription timeout")
                    }
                }
            }
        }
    }

    private func handleFinalTranscription(_ transcription: String, source: String) {
        guard !isProcessingQuery else {
            print("⚠️ Already processing a query, ignoring: '\(transcription)'")
            return
        }

        guard !transcription.isEmpty else {
            // Reset for next utterance
            isSpeechActive = false
            speechStartTime = nil
            currentTranscription = ""
            return
        }

        isProcessingQuery = true
        isSpeechActive = false
        speechStartTime = nil

        print("✅ Final transcription (\(source)): '\(transcription)'")
        onFinalTranscription?(transcription)
    }

    /// Call this after query processing is complete to resume listening
    func queryProcessingComplete() {
        isProcessingQuery = false
        currentTranscription = ""
        lastTranscriptionUpdateTime = nil
        print("🔄 Ready for next query")
    }

    // MARK: - State Queries

    func isCurrentlyListening() -> Bool {
        return isRunning
    }

    func isSpeechCurrentlyActive() -> Bool {
        return isSpeechActive
    }

    func getCurrentTranscription() -> String {
        return currentTranscription
    }
}

// MARK: - Errors

enum ContinuousListeningError: Error {
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

// MARK: - Audio Level Helper

extension ContinuousListeningService {
    /// Convert decibel level to normalized 0-1 range for UI visualization
    static func normalizeAudioLevel(_ decibels: Float) -> Float {
        let minDB: Float = -60.0
        let maxDB: Float = -20.0

        let clamped = max(minDB, min(maxDB, decibels))
        return (clamped - minDB) / (maxDB - minDB)
    }
}
