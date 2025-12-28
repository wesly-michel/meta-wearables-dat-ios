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
class TTSService: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var isSpeaking = false
    
    override init() {
        super.init()
        synthesizer.delegate = self
        configureAudioSession()
    }
    
    /// Configure audio session to route to Bluetooth (Ray-Ban glasses)
    private func configureAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .spokenAudio, options: [.allowBluetoothHFP])
            try audioSession.setActive(true)
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
        
        // Create utterance
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: language)
        utterance.rate = rate
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        
        // Speak
        await MainActor.run {
            isSpeaking = true
            synthesizer.speak(utterance)
        }
        
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
    
    // MARK: - AVSpeechSynthesizerDelegate
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        isSpeaking = false
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        isSpeaking = false
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
