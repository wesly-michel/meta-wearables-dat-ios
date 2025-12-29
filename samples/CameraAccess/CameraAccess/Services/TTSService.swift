/*
 * TTSService.swift
 * Ray-Ban Meta Translation App
 *
 * Handles text-to-speech conversion and audio routing to Ray-Ban glasses.
 * Audio automatically routes to connected Bluetooth device (the glasses).
 */

import AVFoundation
import Foundation

@MainActor
class TTSService: NSObject {
    private let synthesizer = AVSpeechSynthesizer()
    private var isSpeaking = false

    override init() {
        super.init()
        synthesizer.delegate = self
        // Don't configure audio session on init - let VoiceActivationDetector manage it
    }

    /// Ensure audio session is ready for playback (called before speaking)
    private func ensureAudioSessionForPlayback() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            // Use HFP profile for Ray-Ban glasses (two-way voice) per Meta docs
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.allowBluetooth, .defaultToSpeaker])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("⚠️ TTSService: Failed to configure audio session: \(error)")
        }
    }

    /// Speak translated text through Ray-Ban glasses speakers
    /// - Parameters:
    ///   - text: The text to speak
    ///   - language: Language code (e.g., "en-US", "th-TH")
    ///   - rate: Speech rate (0.0 = slowest, 1.0 = fastest, default: 0.5)
    func speak(_ text: String, language: String = "en-US", rate: Float = 0.5) async {
        // Stop any ongoing speech
        if isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        // Ensure audio session is configured for playback
        ensureAudioSessionForPlayback()

        print("🔊 TTSService: Speaking: \(text.prefix(50))...")

        // Create utterance
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: language)
        utterance.rate = rate
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0

        // Speak
        isSpeaking = true
        synthesizer.speak(utterance)

        // Wait for speech to finish
        while isSpeaking {
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        }
    }

    /// Stop any ongoing speech
    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    // Called from delegate extension
    fileprivate func markSpeechFinished() {
        Task { @MainActor in
            self.isSpeaking = false
        }
    }
}

// MARK: - AVSpeechSynthesizerDelegate (nonisolated for Swift 6 compatibility)

extension TTSService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
        }
    }
}

// MARK: - Language Support

extension TTSService {
    /// Get iOS language code from human-readable language name
    static func languageCode(for language: String) -> String {
        let languageCodes: [String: String] = [
            "English": "en-US",
            "Thai": "th-TH",
            "Japanese": "ja-JP",
            "Chinese": "zh-CN",
            "Korean": "ko-KR",
            "Spanish": "es-ES",
            "French": "fr-FR",
            "German": "de-DE",
            "Italian": "it-IT",
            "Arabic": "ar-SA",
            "Vietnamese": "vi-VN",
            "Portuguese": "pt-BR",
            "Russian": "ru-RU",
            "Hindi": "hi-IN"
        ]
        
        return languageCodes[language] ?? "en-US"
    }
}
