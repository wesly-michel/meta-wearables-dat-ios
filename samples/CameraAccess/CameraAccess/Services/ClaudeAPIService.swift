/*
 * ClaudeAPIService.swift
 * Ray-Ban Meta Translation App
 *
 * Handles all interactions with the Claude API for image-based translation.
 * Supports real-time translation using Claude Sonnet 4.5's vision capabilities.
 */

import Foundation
import UIKit

enum TranslationError: Error {
    case imageConversionFailed
    case invalidAPIKey
    case networkError(Error)
    case apiError(String)
    case decodingError(Error)
    
    var localizedDescription: String {
        switch self {
        case .imageConversionFailed:
            return "Failed to convert image for API request"
        case .invalidAPIKey:
            return "Invalid or missing Claude API key"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .apiError(let message):
            return "API error: \(message)"
        case .decodingError(let error):
            return "Failed to decode response: \(error.localizedDescription)"
        }
    }
}

class ClaudeAPIService {
    private let apiKey: String
    private let endpoint = "https://api.anthropic.com/v1/messages"
    private let model = "claude-sonnet-4-20250514"
    private let apiVersion = "2023-06-01"
    
    // Image compression quality (0.0-1.0)
    // Lower quality = smaller payload = faster API calls
    private let imageCompressionQuality: CGFloat = 0.7
    
    init(apiKey: String) {
        self.apiKey = apiKey
    }
    
    /// Translate text found in an image from source language to target language
    /// - Parameters:
    ///   - image: The UIImage captured from Ray-Ban glasses
    ///   - sourceLang: Source language (e.g., "Thai", "Japanese")
    ///   - targetLang: Target language (e.g., "English")
    /// - Returns: Translated text
    func translateImage(
        _ image: UIImage,
        sourceLang: String,
        targetLang: String
    ) async throws -> String {
        guard !apiKey.isEmpty else {
            throw TranslationError.invalidAPIKey
        }
        
        // Convert UIImage to base64 JPEG
        guard let imageData = image.jpegData(compressionQuality: imageCompressionQuality) else {
            throw TranslationError.imageConversionFailed
        }
        let base64Image = imageData.base64EncodedString()
        
        // Construct Claude API request
        let payload: [String: Any] = [
            "model": model,
            "max_tokens": 1000,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": "image/jpeg",
                                "data": base64Image
                            ]
                        ],
                        [
                            "type": "text",
                            "text": buildTranslationPrompt(sourceLang: sourceLang, targetLang: targetLang)
                        ]
                    ]
                ]
            ]
        ]
        
        // Make HTTP request
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            // Check HTTP status
            if let httpResponse = response as? HTTPURLResponse,
               !(200...299).contains(httpResponse.statusCode) {
                let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
                throw TranslationError.apiError("HTTP \(httpResponse.statusCode): \(errorBody)")
            }
            
            // Parse response
            let claudeResponse = try JSONDecoder().decode(ClaudeResponse.self, from: data)
            
            // Extract translated text
            guard let translatedText = claudeResponse.content.first?.text else {
                throw TranslationError.apiError("No translation in response")
            }
            
            return translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
            
        } catch let error as TranslationError {
            throw error
        } catch let error as DecodingError {
            throw TranslationError.decodingError(error)
        } catch {
            throw TranslationError.networkError(error)
        }
    }
    
    /// Build optimized prompt for image translation
    /// Designed for speed and accuracy
    private func buildTranslationPrompt(sourceLang: String, targetLang: String) -> String {
        """
        You are a professional translator. Analyze this image and translate any \(sourceLang) text you find into \(targetLang).
        
        Instructions:
        - Output ONLY the translated text
        - Preserve formatting (line breaks, bullet points, etc.)
        - If there's no readable text, respond with "No text found"
        - Be concise and accurate
        - Do NOT add explanations or commentary
        
        Translate now:
        """
    }
}

// MARK: - Response Models

struct ClaudeResponse: Codable {
    let content: [ContentBlock]
}

struct ContentBlock: Codable {
    let type: String
    let text: String?
}
