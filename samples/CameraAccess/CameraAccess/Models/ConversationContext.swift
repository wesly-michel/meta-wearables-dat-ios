/*
 * ConversationContext.swift
 * Ray-Ban Meta Translation App
 *
 * Data models for Continuous Vision Mode:
 * - Message: Individual conversation turns
 * - SceneContext: Current view understanding
 * - VisionMode: Translation vs Continuous Vision
 */

import Foundation
import UIKit

// MARK: - Message Model

struct Message: Identifiable, Codable {
    let id: UUID
    let role: MessageRole
    let text: String
    let timestamp: Date
    
    init(id: UUID = UUID(), role: MessageRole, text: String, timestamp: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
    }
    
    var formattedTime: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: timestamp)
    }
}

enum MessageRole: String, Codable {
    case user = "user"
    case assistant = "assistant"
    case system = "system"
}

// MARK: - Scene Context Model

struct SceneContext: Codable {
    let description: String
    let lastUpdated: Date
    let confidence: SceneConfidence
    
    // Not stored in Codable - transient visual data
    var currentFrameData: Data?
    
    init(description: String = "No scene detected", 
         lastUpdated: Date = Date(),
         confidence: SceneConfidence = .low,
         currentFrameData: Data? = nil) {
        self.description = description
        self.lastUpdated = lastUpdated
        self.confidence = confidence
        self.currentFrameData = currentFrameData
    }
    
    var isEmpty: Bool {
        description.isEmpty || description == "No scene detected"
    }
    
    var age: TimeInterval {
        Date().timeIntervalSince(lastUpdated)
    }
    
    var isStale: Bool {
        age > 10.0  // Consider scene stale after 10 seconds
    }
    
    // Custom Codable to exclude currentFrameData
    enum CodingKeys: String, CodingKey {
        case description, lastUpdated, confidence
    }
}

enum SceneConfidence: String, Codable {
    case high = "High"
    case medium = "Medium"
    case low = "Low"
    
    var color: String {
        switch self {
        case .high: return "green"
        case .medium: return "orange"
        case .low: return "red"
        }
    }
}

// MARK: - Vision Mode

enum VisionMode: String, Codable {
    case translation = "Translation"
    case continuousVision = "Continuous Vision"
    
    var systemImage: String {
        switch self {
        case .translation: return "camera.fill"
        case .continuousVision: return "eye.fill"
        }
    }
    
    var description: String {
        switch self {
        case .translation:
            return "Point and translate text"
        case .continuousVision:
            return "Ask questions about what you see"
        }
    }
}

// MARK: - Conversation Session

struct ConversationSession: Identifiable, Codable {
    let id: UUID
    let startTime: Date
    var messages: [Message]
    var sceneHistory: [SceneContext]
    
    init(id: UUID = UUID(), startTime: Date = Date()) {
        self.id = id
        self.startTime = startTime
        self.messages = []
        self.sceneHistory = []
    }
    
    mutating func addMessage(_ message: Message) {
        messages.append(message)
    }
    
    mutating func addSceneContext(_ context: SceneContext) {
        sceneHistory.append(context)
    }
    
    var duration: TimeInterval {
        Date().timeIntervalSince(startTime)
    }
    
    var formattedDuration: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// MARK: - Voice Query State

enum VoiceQueryState {
    case idle
    case listening
    case processing
    case speaking
    case error(String)
    
    var displayText: String {
        switch self {
        case .idle: return "Ready to listen"
        case .listening: return "Listening..."
        case .processing: return "Thinking..."
        case .speaking: return "Speaking..."
        case .error(let msg): return "Error: \(msg)"
        }
    }
    
    var systemImage: String {
        switch self {
        case .idle: return "mic.fill"
        case .listening: return "waveform"
        case .processing: return "brain"
        case .speaking: return "speaker.wave.2.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }
    
    var color: String {
        switch self {
        case .idle: return "gray"
        case .listening: return "blue"
        case .processing: return "orange"
        case .speaking: return "green"
        case .error: return "red"
        }
    }
}
