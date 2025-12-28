/*
 * VoiceActivationDetector.swift
 * Ray-Ban Meta Translation App
 *
 * Monitors audio input for voice activity detection (VAD).
 * Triggers when user starts speaking, no wake word required.
 */

import Foundation
import AVFoundation

class VoiceActivationDetector {
    
    // MARK: - Properties
    
    private let audioEngine = AVAudioEngine()
    private var isMonitoring = false
    
    // VAD parameters
    private let silenceThreshold: Float = -40.0  // dB threshold for silence
    private let speechDuration: TimeInterval = 0.3  // Minimum speech duration
    private let silenceDuration: TimeInterval = 1.5  // Silence before considering speech ended
    
    // State tracking
    private var speechStartTime: Date?
    private var lastSpeechTime: Date?
    private var isSpeaking = false
    
    // Callbacks
    var onSpeechStarted: (() -> Void)?
    var onSpeechEnded: (() -> Void)?
    var onAudioLevel: ((Float) -> Void)?  // For visual feedback
    
    // MARK: - Monitoring Control
    
    func startMonitoring() throws {
        guard !isMonitoring else { return }
        
        // Configure audio session for input
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record, mode: .measurement)
        try audioSession.setActive(true)
        
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        
        // Install tap to analyze audio levels
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, time in
            self?.processAudioBuffer(buffer)
        }
        
        audioEngine.prepare()
        try audioEngine.start()
        
        isMonitoring = true
        print("✅ VoiceActivationDetector: Started monitoring")
    }
    
    func stopMonitoring() {
        guard isMonitoring else { return }
        
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        
        do {
            try AVAudioSession.sharedInstance().setActive(false)
        } catch {
            print("⚠️ Failed to deactivate audio session: \(error)")
        }
        
        isMonitoring = false
        isSpeaking = false
        speechStartTime = nil
        lastSpeechTime = nil
        
        print("🛑 VoiceActivationDetector: Stopped monitoring")
    }
    
    // MARK: - Audio Processing
    
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        
        let channelDataValue = channelData.pointee
        let channelDataValueArray = stride(
            from: 0,
            to: Int(buffer.frameLength),
            by: buffer.stride
        ).map { channelDataValue[$0] }
        
        // Calculate RMS (Root Mean Square) for audio level
        let rms = sqrt(channelDataValueArray.map { $0 * $0 }.reduce(0, +) / Float(buffer.frameLength))
        
        // Convert to decibels
        let avgPower = 20 * log10(rms)
        
        // Notify UI of audio level (for visualization)
        DispatchQueue.main.async { [weak self] in
            self?.onAudioLevel?(avgPower)
        }
        
        // Voice activity detection
        let isSpeechDetected = avgPower > silenceThreshold
        
        DispatchQueue.main.async { [weak self] in
            self?.updateSpeechState(isSpeechDetected: isSpeechDetected)
        }
    }
    
    private func updateSpeechState(isSpeechDetected: Bool) {
        let now = Date()
        
        if isSpeechDetected {
            // Speech detected
            lastSpeechTime = now
            
            if !isSpeaking {
                // Start of new speech
                if speechStartTime == nil {
                    speechStartTime = now
                } else if let startTime = speechStartTime,
                          now.timeIntervalSince(startTime) >= speechDuration {
                    // Speech has been sustained long enough
                    isSpeaking = true
                    onSpeechStarted?()
                    print("🎤 Speech started")
                }
            }
        } else {
            // Silence detected
            if isSpeaking {
                // Check if silence has been long enough to end speech
                if let lastSpeech = lastSpeechTime,
                   now.timeIntervalSince(lastSpeech) >= silenceDuration {
                    isSpeaking = false
                    speechStartTime = nil
                    onSpeechEnded?()
                    print("🔇 Speech ended")
                }
            } else {
                // Reset if not enough speech to trigger
                speechStartTime = nil
            }
        }
    }
    
    // MARK: - State Queries
    
    func isUserSpeaking() -> Bool {
        return isSpeaking
    }
    
    func isCurrentlyMonitoring() -> Bool {
        return isMonitoring
    }
    
    // MARK: - Configuration
    
    func setSilenceThreshold(_ threshold: Float) {
        // Typically between -50 (very quiet) and -20 (loud)
        // Default -40 works well for most environments
    }
    
    func setSpeechDuration(_ duration: TimeInterval) {
        // How long user must speak before triggering (prevents false positives)
    }
    
    func setSilenceDuration(_ duration: TimeInterval) {
        // How long silence before ending speech detection
    }
}

// MARK: - Audio Level Helper

extension VoiceActivationDetector {
    /// Convert decibel level to normalized 0-1 range for UI visualization
    static func normalizeAudioLevel(_ decibels: Float) -> Float {
        // Map -60dB (silence) to 0.0, -20dB (loud) to 1.0
        let minDB: Float = -60.0
        let maxDB: Float = -20.0
        
        let clamped = max(minDB, min(maxDB, decibels))
        return (clamped - minDB) / (maxDB - minDB)
    }
}
