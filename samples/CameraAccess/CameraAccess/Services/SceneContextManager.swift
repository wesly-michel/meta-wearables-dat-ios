/*
 * SceneContextManager.swift
 * Ray-Ban Meta Translation App
 *
 * Manages lightweight scene tracking for Continuous Vision Mode.
 * Updates scene context every 2-3 seconds with minimal API calls.
 */

import Foundation
import UIKit

class SceneContextManager {
    
    // MARK: - Properties
    
    private let geminiAPIKey: String
    private let updateInterval: TimeInterval
    private var lastUpdateTime: Date?
    private var isUpdating = false
    
    // Current scene state
    private(set) var currentScene: SceneContext
    
    // Callbacks
    var onSceneUpdate: ((SceneContext) -> Void)?
    
    // MARK: - Initialization
    
    init(apiKey: String, updateInterval: TimeInterval = 2.5) {
        self.geminiAPIKey = apiKey
        self.updateInterval = updateInterval
        self.currentScene = SceneContext()
    }
    
    // MARK: - Scene Tracking
    
    /// Check if scene should be updated based on interval
    func shouldUpdateScene() -> Bool {
        guard let lastUpdate = lastUpdateTime else {
            return true  // First update
        }
        
        let elapsed = Date().timeIntervalSince(lastUpdate)
        return elapsed >= updateInterval && !isUpdating
    }
    
    /// Update scene context from current video frame
    /// - Parameter frame: Current camera frame from Ray-Ban glasses
    func updateSceneContext(from frame: UIImage) async {
        guard shouldUpdateScene() else { return }
        
        isUpdating = true
        defer { isUpdating = false }
        
        do {
            // Get lightweight scene description
            let description = try await getSceneDescription(from: frame)
            
            // Store frame data for later detailed analysis
            let frameData = frame.jpegData(compressionQuality: 0.7)
            
            // Update scene context
            currentScene = SceneContext(
                description: description,
                lastUpdated: Date(),
                confidence: determineConfidence(from: description),
                currentFrameData: frameData
            )
            
            lastUpdateTime = Date()
            
            // Notify observers
            onSceneUpdate?(currentScene)
            
        } catch {
            print("⚠️ SceneContextManager: Failed to update scene - \(error.localizedDescription)")
            
            // Update with error state
            currentScene = SceneContext(
                description: "Unable to detect scene",
                lastUpdated: Date(),
                confidence: .low,
                currentFrameData: nil
            )
        }
    }
    
    // MARK: - Scene Description
    
    /// Get lightweight scene description using Gemini
    private func getSceneDescription(from image: UIImage) async throws -> String {
        guard let imageData = image.jpegData(compressionQuality: 0.6) else {
            throw SceneError.imageConversionFailed
        }
        
        let base64Image = imageData.base64EncodedString()
        
        // Lightweight prompt for quick scene understanding
        let payload: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        [
                            "inline_data": [
                                "mime_type": "image/jpeg",
                                "data": base64Image
                            ]
                        ],
                        [
                            "text": buildScenePrompt()
                        ]
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": 0.1,
                "maxOutputTokens": 150,  // Keep response brief
                "topP": 0.9,
                "topK": 20
            ]
        ]
        
        // Make API request
        let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash-exp:generateContent?key=\(geminiAPIKey)"
        
        guard let url = URL(string: endpoint) else {
            throw SceneError.invalidEndpoint
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        // Check response
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw SceneError.apiError(httpResponse.statusCode)
        }
        
        // Parse response
        let geminiResponse = try JSONDecoder().decode(GeminiSceneResponse.self, from: data)
        
        guard let text = geminiResponse.candidates.first?.content.parts.first?.text else {
            throw SceneError.noContent
        }
        
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Build lightweight scene description prompt
    private func buildScenePrompt() -> String {
        """
        Describe what you see in this image in 1-2 brief sentences.
        
        Focus on:
        - Main subject (menu, sign, product, person, etc.)
        - Key text visible (language, general content)
        - Context (restaurant, store, street, etc.)
        
        Keep it concise - just the essential information.
        
        Examples:
        - "Thai restaurant menu with 8 items, prices 80-200 baht"
        - "Product package: spicy chips, red packaging with Thai text"
        - "Street sign in Thai pointing to temple, 500m"
        
        Describe this image now:
        """
    }
    
    // MARK: - Confidence Determination
    
    private func determineConfidence(from description: String) -> SceneConfidence {
        let lowConfidenceKeywords = ["unclear", "blurry", "unable", "can't see", "no visible"]
        let highConfidenceKeywords = ["menu", "sign", "product", "package", "text"]
        
        let lowerDescription = description.lowercased()
        
        // Check for low confidence indicators
        for keyword in lowConfidenceKeywords {
            if lowerDescription.contains(keyword) {
                return .low
            }
        }
        
        // Check for high confidence indicators
        var matchCount = 0
        for keyword in highConfidenceKeywords {
            if lowerDescription.contains(keyword) {
                matchCount += 1
            }
        }
        
        return matchCount >= 2 ? .high : .medium
    }
    
    // MARK: - Getters
    
    func getCurrentSceneDescription() -> String {
        return currentScene.description
    }
    
    func getCurrentFrame() -> UIImage? {
        guard let data = currentScene.currentFrameData else { return nil }
        return UIImage(data: data)
    }
    
    func getSceneAge() -> TimeInterval {
        return currentScene.age
    }
    
    // MARK: - Reset
    
    func clearContext() {
        currentScene = SceneContext()
        lastUpdateTime = nil
        isUpdating = false
    }
    
    func resetUpdateTimer() {
        lastUpdateTime = nil
    }
}

// MARK: - Response Models

private struct GeminiSceneResponse: Codable {
    let candidates: [Candidate]
    
    struct Candidate: Codable {
        let content: Content
    }
    
    struct Content: Codable {
        let parts: [Part]
    }
    
    struct Part: Codable {
        let text: String?
    }
}

// MARK: - Errors

enum SceneError: Error {
    case imageConversionFailed
    case invalidEndpoint
    case apiError(Int)
    case noContent
    
    var localizedDescription: String {
        switch self {
        case .imageConversionFailed:
            return "Failed to convert image"
        case .invalidEndpoint:
            return "Invalid API endpoint"
        case .apiError(let code):
            return "API error: \(code)"
        case .noContent:
            return "No content in response"
        }
    }
}
