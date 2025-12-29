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

    // Actor for thread-safe state management (Swift 6 compatible)
    private actor UpdateState {
        var lastUpdateTime: Date?
        var isUpdating = false
        var isPaused = false  // Pause updates during query processing

        func shouldUpdate(interval: TimeInterval) -> Bool {
            if isPaused { return false }  // Don't update when paused
            if isUpdating { return false }
            if let lastUpdate = lastUpdateTime {
                if Date().timeIntervalSince(lastUpdate) < interval {
                    return false
                }
            }
            isUpdating = true
            lastUpdateTime = Date()
            return true
        }

        func finishUpdate() {
            isUpdating = false
        }

        func reset() {
            lastUpdateTime = nil
            isUpdating = false
        }

        func pause() {
            isPaused = true
            print("⏸️ SceneContextManager: Paused")
        }

        func resume() {
            isPaused = false
            print("▶️ SceneContextManager: Resumed")
        }
    }

    private let updateState = UpdateState()

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

    /// Update scene context from current video frame
    /// - Parameter frame: Current camera frame from Ray-Ban glasses
    func updateSceneContext(from frame: UIImage) async {
        // Thread-safe check using actor
        guard await updateState.shouldUpdate(interval: updateInterval) else {
            return  // Silently skip if too soon or already updating
        }

        defer {
            Task { await updateState.finishUpdate() }
        }

        do {
            // Get lightweight scene description
            let description = try await getSceneDescription(from: frame)
            
            // Don't store frame data to save memory - we'll capture fresh frame if needed
            // let frameData = frame.jpegData(compressionQuality: 0.7)
            
            // Update scene context
            currentScene = SceneContext(
                description: description,
                lastUpdated: Date(),
                confidence: determineConfidence(from: description),
                currentFrameData: nil  // Don't cache frames - saves memory
            )
            
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
        // Resize image to VERY small size for scene tracking (faster upload, less memory)
        let resizedImage = resizeImage(image, targetWidth: 320)  // Reduced from 640px
        
        guard let imageData = resizedImage.jpegData(compressionQuality: 0.3) else {  // More compression
            throw SceneError.imageConversionFailed
        }
        
        let base64Image = imageData.base64EncodedString()
        
        let sizeKB = imageData.count / 1024
        print("📦 SceneContextManager: Image size = \(sizeKB)KB (target: <50KB)")
        
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
                "maxOutputTokens": 50,  // Very brief - just the essentials
                "topP": 0.9,
                "topK": 20
            ]
        ]
        
        // Make API request - Use stable Gemini 2.0 Flash model (more reliable)
        let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=\(geminiAPIKey)"
        
        guard let url = URL(string: endpoint) else {
            throw SceneError.invalidEndpoint
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30.0  // 30 seconds for reliability on slower networks

        let jsonData = try JSONSerialization.data(withJSONObject: payload)
        request.httpBody = jsonData

        let payloadSizeKB = jsonData.count / 1024
        print("🌐 SceneContextManager: Sending request to Gemini (payload: \(payloadSizeKB)KB, base64 image: \(base64Image.count / 1024)KB)...")
        let startTime = Date()

        let (data, response) = try await URLSession.shared.data(for: request)
        
        let duration = Date().timeIntervalSince(startTime)
        print("✅ SceneContextManager: Response received in \(String(format: "%.2f", duration))s")
        
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
    
    /// Build lightweight scene description prompt - optimized for Thai content
    private func buildScenePrompt() -> String {
        """
        Briefly describe what you see in 1 sentence, focusing on Thai text/language content.
        
        What to identify:
        - Type: menu, sign, product, document
        - Language: Thai text, mixed Thai/English
        - Context: restaurant, store, street
        
        Example: "Thai restaurant menu with 8 dishes and prices in Thai"
        
        Keep it under 15 words.
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
        Task { await updateState.reset() }
    }

    func resetUpdateTimer() {
        Task { await updateState.reset() }
    }

    /// Pause scene updates (during query processing to avoid redundant API calls)
    func pauseUpdates() {
        Task { await updateState.pause() }
    }

    /// Resume scene updates
    func resumeUpdates() {
        Task { await updateState.resume() }
    }
    
    // MARK: - Image Processing
    
    /// Resize image to reduce payload size and speed up API calls
    private func resizeImage(_ image: UIImage, targetWidth: CGFloat) -> UIImage {
        let scale = targetWidth / image.size.width
        let newHeight = image.size.height * scale
        let newSize = CGSize(width: targetWidth, height: newHeight)
        
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
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
