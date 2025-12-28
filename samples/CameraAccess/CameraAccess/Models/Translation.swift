/*
 * Translation.swift
 * Ray-Ban Meta Translation App
 *
 * Model for storing individual translation records with metadata.
 */

import Foundation

struct Translation: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let sourceText: String
    let translatedText: String
    let sourceLang: String
    let targetLang: String
    let mode: TranslationMode
    
    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        sourceText: String,
        translatedText: String,
        sourceLang: String,
        targetLang: String,
        mode: TranslationMode = .camera
    ) {
        self.id = id
        self.timestamp = timestamp
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.sourceLang = sourceLang
        self.targetLang = targetLang
        self.mode = mode
    }
    
    /// Formatted timestamp for display
    var formattedTime: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .short
        return formatter.string(from: timestamp)
    }
}

enum TranslationMode: String, Codable {
    case camera = "Camera"
    case audio = "Audio"
    case manual = "Manual"
}
