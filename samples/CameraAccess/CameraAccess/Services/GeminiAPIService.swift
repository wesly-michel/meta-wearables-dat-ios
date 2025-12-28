/*
 * GeminiAPIService.swift
 * Ray-Ban Meta Translation App
 *
 * Handles all interactions with the Google Gemini API for image-based translation.
 * Uses Gemini 2.0 Flash - 40x cheaper than Claude with good quality.
 * Cost: ~$0.0001-0.0005 per translation vs Claude's $0.005-0.01
 */

import Foundation
import UIKit

enum GeminiTranslationError: Error {
    case imageConversionFailed
    case invalidAPIKey
    case networkError(Error)
    case apiError(String)
    case decodingError(Error)
    case noContent
    
    var localizedDescription: String {
        switch self {
        case .imageConversionFailed:
            return "Failed to convert image for API request"
        case .invalidAPIKey:
            return "Invalid or missing Gemini API key"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .apiError(let message):
            return "API error: \(message)"
        case .decodingError(let error):
            return "Failed to decode response: \(error.localizedDescription)"
        case .noContent:
            return "No translation content in response"
        }
    }
}

class GeminiAPIService {
    private let apiKey: String
    private let model = "gemini-2.0-flash-exp"  // Latest, fastest, cheapest
    private var endpoint: String {
        "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)"
    }
    
    // Image compression quality (0.0-1.0)
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
            throw GeminiTranslationError.invalidAPIKey
        }
        
        // Convert UIImage to base64 JPEG
        guard let imageData = image.jpegData(compressionQuality: imageCompressionQuality) else {
            throw GeminiTranslationError.imageConversionFailed
        }
        let base64Image = imageData.base64EncodedString()
        
        // Construct Gemini API request
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
                            "text": buildTranslationPrompt(sourceLang: sourceLang, targetLang: targetLang)
                        ]
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": 0.2,  // Lower = more consistent
                "maxOutputTokens": 1000,
                "topP": 0.8,
                "topK": 10
            ]
        ]
        
        // Make HTTP request
        guard let url = URL(string: endpoint) else {
            throw GeminiTranslationError.apiError("Invalid endpoint URL")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            // Check HTTP status
            if let httpResponse = response as? HTTPURLResponse {
                guard (200...299).contains(httpResponse.statusCode) else {
                    let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
                    throw GeminiTranslationError.apiError("HTTP \(httpResponse.statusCode): \(errorBody)")
                }
            }
            
            // Parse response
            let geminiResponse = try JSONDecoder().decode(GeminiResponse.self, from: data)
            
            // Extract translated text
            guard let candidate = geminiResponse.candidates.first,
                  let part = candidate.content.parts.first,
                  let text = part.text else {
                throw GeminiTranslationError.noContent
            }
            
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
            
        } catch let error as GeminiTranslationError {
            throw error
        } catch let error as DecodingError {
            throw GeminiTranslationError.decodingError(error)
        } catch {
            throw GeminiTranslationError.networkError(error)
        }
    }
    
    /// Build optimized prompt for image translation
    /// Designed for speed and accuracy with Gemini
    private func buildTranslationPrompt(sourceLang: String, targetLang: String) -> String {
        """
        You are a professional translator. Analyze this image and translate any \(sourceLang) text you find into \(targetLang).
        
        Instructions:
        - Output ONLY the translated text
        - Preserve formatting (line breaks, bullet points, etc.)
        - If there's no readable text, respond with "No text found"
        - Be concise and accurate
        - Do NOT add explanations or commentary
        - Translate all visible text in the image
        
        Translate now:
        """
    }
}

// MARK: - Response Models

struct GeminiResponse: Codable {
    let candidates: [Candidate]
}

struct Candidate: Codable {
    let content: Content
}

struct Content: Codable {
    let parts: [Part]
}

struct Part: Codable {
    let text: String?
}
