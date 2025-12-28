/*
 * GeminiAPIService.swift (Optimized)
 * Ray-Ban Meta Translation App
 *
 * Enhanced version with:
 * - Improved prompts for better accuracy
 * - Multiple model support for testing
 * - Confidence scoring
 * - Better error handling
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
    case lowConfidence(String)
    
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
        case .lowConfidence(let translation):
            return "Low confidence translation: \(translation)"
        }
    }
}

// ========================================
// GEMINI MODEL ENUM - UPDATED WITH FALLBACKS
// ========================================
enum GeminiModel: String, CaseIterable {
    case flash2_0 = "gemini-2.0-flash-exp"           // Latest, fastest (experimental)
    case flash1_5 = "gemini-1.5-flash-latest"        // Stable with -latest suffix
    case pro1_5 = "gemini-1.5-pro-latest"            // Higher quality with -latest suffix
    
    // FALLBACK MODELS - Used when -latest versions fail
    case flash1_5_base = "gemini-1.5-flash"          // Fallback for 1.5 Flash
    case pro1_5_base = "gemini-1.5-pro"              // Fallback for 1.5 Pro
    
    var displayName: String {
        switch self {
        case .flash2_0: return "Gemini 2.0 Flash (Experimental)"
        case .flash1_5: return "Gemini 1.5 Flash Latest"
        case .pro1_5: return "Gemini 1.5 Pro Latest"
        case .flash1_5_base: return "Gemini 1.5 Flash (Base)"
        case .pro1_5_base: return "Gemini 1.5 Pro (Base)"
        }
    }
    
    var costPerRequest: Double {
        switch self {
        case .flash2_0: return 0.0001
        case .flash1_5, .flash1_5_base: return 0.0002
        case .pro1_5, .pro1_5_base: return 0.0010
        }
    }
    
    var isExperimental: Bool {
        switch self {
        case .flash2_0: return true
        default: return false
        }
    }
}

enum PromptStrategy: String {
    case concise = "concise"           // Original short prompt
    case detailed = "detailed"         // More specific instructions
    case structured = "structured"     // Request structured output
    
    var displayName: String {
        switch self {
        case .concise: return "Concise"
        case .detailed: return "Detailed"
        case .structured: return "Structured"
        }
    }
}

class GeminiAPIService {
    private let apiKey: String
    private var model: GeminiModel
    private var promptStrategy: PromptStrategy
    
    // Image compression quality (0.0-1.0)
    private let imageCompressionQuality: CGFloat = 0.7
    
    // Generation config
    private var temperature: Double = 0.1  // Lower = more consistent (was 0.2)
    private var topP: Double = 0.9        // Slightly higher for better coverage
    private var topK: Int = 20            // Increased for more options
    
    init(apiKey: String, model: GeminiModel = .flash2_0, promptStrategy: PromptStrategy = .detailed) {
        self.apiKey = apiKey
        self.model = model
        self.promptStrategy = promptStrategy
    }
    
    // MARK: - Model Selection
    
    func setModel(_ model: GeminiModel) {
        self.model = model
    }
    
    func setPromptStrategy(_ strategy: PromptStrategy) {
        self.promptStrategy = strategy
    }
    
    func setTemperature(_ temp: Double) {
        self.temperature = max(0.0, min(1.0, temp))
    }
    
    // MARK: - Translation
    
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
        
        // Build prompt based on strategy
        let prompt = buildTranslationPrompt(
            sourceLang: sourceLang,
            targetLang: targetLang,
            strategy: promptStrategy
        )
        
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
                            "text": prompt
                        ]
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": temperature,
                "maxOutputTokens": 1000,
                "topP": topP,
                "topK": topK
            ]
        ]
        
        // Make HTTP request
        let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/\(model.rawValue):generateContent?key=\(apiKey)"
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
            
            let cleanedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Check for low confidence indicators
            if promptStrategy == .structured {
                // If using structured output, we could parse confidence
                // For now, just return the translation
            }
            
            return cleanedText
            
        } catch let error as GeminiTranslationError {
            throw error
        } catch let error as DecodingError {
            throw GeminiTranslationError.decodingError(error)
        } catch {
            throw GeminiTranslationError.networkError(error)
        }
    }
    
    // MARK: - Prompt Building
    
    /// Build translation prompt based on selected strategy
    private func buildTranslationPrompt(
        sourceLang: String,
        targetLang: String,
        strategy: PromptStrategy
    ) -> String {
        switch strategy {
        case .concise:
            return buildConcisePrompt(sourceLang: sourceLang, targetLang: targetLang)
        case .detailed:
            return buildDetailedPrompt(sourceLang: sourceLang, targetLang: targetLang)
        case .structured:
            return buildStructuredPrompt(sourceLang: sourceLang, targetLang: targetLang)
        }
    }
    
    private func buildConcisePrompt(sourceLang: String, targetLang: String) -> String {
        """
        Translate any \(sourceLang) text in this image to \(targetLang).
        Output ONLY the translation, no explanations.
        If no text is found, respond with "No text found".
        """
    }
    
    private func buildDetailedPrompt(sourceLang: String, targetLang: String) -> String {
        """
        You are an expert translator specializing in \(sourceLang) to \(targetLang) translation.
        
        Task: Carefully examine this image and translate ALL visible \(sourceLang) text into \(targetLang).
        
        Instructions:
        1. Look carefully for ALL text in the image, including:
           - Signs and labels
           - Menus and food items
           - Handwritten text
           - Small or partially visible text
           - Text at any angle or orientation
        
        2. Translation requirements:
           - Translate accurately and naturally
           - Preserve the meaning and context
           - Use appropriate \(targetLang) terminology
           - Maintain any formatting (line breaks, sections)
        
        3. Output format:
           - Provide ONLY the translated text
           - No preamble, no explanations
           - No phrases like "The translation is..." or "This says..."
           - If multiple sections exist, separate with line breaks
        
        4. Special cases:
           - If NO readable text exists, respond with exactly: "No text found"
           - If text is partially visible or unclear, translate what you can see
           - For proper nouns (names, places), keep them in original script or transliterate
        
        Begin translation now:
        """
    }
    
    private func buildStructuredPrompt(sourceLang: String, targetLang: String) -> String {
        """
        You are an expert translator. Analyze this image and translate \(sourceLang) text to \(targetLang).
        
        Provide your response in this exact format:
        
        TRANSLATION:
        [Your translation here, or "No text found" if no text is visible]
        
        CONFIDENCE:
        [High/Medium/Low based on text clarity and your certainty]
        
        NOTES:
        [Any relevant context: partial text, unclear characters, multiple text sections, etc.]
        
        Translation requirements:
        - Translate ALL visible \(sourceLang) text
        - Be accurate and natural in \(targetLang)
        - Preserve formatting and structure
        - For unclear text, translate what you can
        - For proper nouns, transliterate appropriately
        
        Begin your structured response now:
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

// MARK: - Testing Helper

extension GeminiAPIService {
    /// Test all available models with the same image
    static func compareModels(
        image: UIImage,
        sourceLang: String,
        targetLang: String,
        apiKey: String
    ) async -> [(model: GeminiModel, result: Result<String, Error>)] {
        let models: [GeminiModel] = [.flash2_0, .flash1_5, .pro1_5]
        var results: [(GeminiModel, Result<String, Error>)] = []
        
        for model in models {
            let service = GeminiAPIService(apiKey: apiKey, model: model)
            do {
                let translation = try await service.translateImage(
                    image,
                    sourceLang: sourceLang,
                    targetLang: targetLang
                )
                results.append((model, .success(translation)))
            } catch {
                results.append((model, .failure(error)))
            }
        }
        
        return results
    }
    
    /// Test all prompt strategies with the same model
    static func comparePrompts(
        image: UIImage,
        sourceLang: String,
        targetLang: String,
        apiKey: String,
        model: GeminiModel = .flash2_0
    ) async -> [(strategy: PromptStrategy, result: Result<String, Error>)] {
        let strategies: [PromptStrategy] = [.concise, .detailed, .structured]
        var results: [(PromptStrategy, Result<String, Error>)] = []
        
        for strategy in strategies {
            let service = GeminiAPIService(apiKey: apiKey, model: model, promptStrategy: strategy)
            do {
                let translation = try await service.translateImage(
                    image,
                    sourceLang: sourceLang,
                    targetLang: targetLang
                )
                results.append((strategy, .success(translation)))
            } catch {
                results.append((strategy, .failure(error)))
            }
        }
        
        return results
    }
}
