/*
 * GeminiAPIService-VisualQA.swift
 * Ray-Ban Meta Translation App
 *
 * Enhanced Gemini API service for Continuous Vision Mode.
 * Adds visual question-answering capability with conversation context.
 */

import Foundation
import UIKit

extension GeminiAPIService {
    
    // MARK: - Visual Question Answering
    
    /// Answer a question about what's visible in the image, using scene context and conversation history
    /// - Parameters:
    ///   - image: Current frame from Ray-Ban glasses
    ///   - sceneContext: Lightweight scene description from background tracking
    ///   - question: User's question
    ///   - conversationHistory: Previous messages for context
    /// - Returns: Answer to the question
    func answerVisualQuestion(
        image: UIImage,
        sceneContext: String,
        question: String,
        conversationHistory: [ConversationMessage] = []
    ) async throws -> String {
        guard !apiKey.isEmpty else {
            throw GeminiTranslationError.invalidAPIKey
        }
        
        // Convert image
        guard let imageData = image.jpegData(compressionQuality: imageCompressionQuality) else {
            throw GeminiTranslationError.imageConversionFailed
        }
        let base64Image = imageData.base64EncodedString()
        
        // Build comprehensive prompt with context
        let prompt = buildVisualQAPrompt(
            sceneContext: sceneContext,
            question: question,
            conversationHistory: conversationHistory
        )
        
        // Construct API request
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
                "temperature": 0.2,  // Slightly higher for more natural responses
                "maxOutputTokens": 500,  // More tokens for detailed answers
                "topP": 0.9,
                "topK": 20
            ]
        ]
        
        // Make request
        guard let url = URL(string: endpoint) else {
            throw GeminiTranslationError.apiError("Invalid endpoint URL")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse {
                guard (200...299).contains(httpResponse.statusCode) else {
                    let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
                    throw GeminiTranslationError.apiError("HTTP \(httpResponse.statusCode): \(errorBody)")
                }
            }
            
            let geminiResponse = try JSONDecoder().decode(GeminiResponse.self, from: data)
            
            guard let candidate = geminiResponse.candidates.first,
                  let part = candidate.content.parts.first,
                  let text = part.text else {
                throw GeminiTranslationError.noContent
            }
            
            return text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            
        } catch let error as GeminiTranslationError {
            throw error
        } catch let error as DecodingError {
            throw GeminiTranslationError.decodingError(error)
        } catch {
            throw GeminiTranslationError.networkError(error)
        }
    }
    
    // MARK: - Prompt Building
    
    private func buildVisualQAPrompt(
        sceneContext: String,
        question: String,
        conversationHistory: [ConversationMessage]
    ) -> String {
        var prompt = """
        You are a helpful visual assistant for someone wearing smart glasses.
        
        """
        
        // Add scene context
        if !sceneContext.isEmpty && sceneContext != "No scene detected" {
            prompt += """
            SCENE CONTEXT:
            \(sceneContext)
            
            """
        }
        
        // Add conversation history if exists
        if !conversationHistory.isEmpty {
            prompt += "CONVERSATION HISTORY:\n"
            for message in conversationHistory.suffix(3) {  // Last 3 exchanges
                let role = message.role == "user" ? "User" : "Assistant"
                prompt += "\(role): \(message.text)\n"
            }
            prompt += "\n"
        }
        
        // Add current question and instructions
        prompt += """
        CURRENT QUESTION:
        \(question)
        
        INSTRUCTIONS:
        1. Look carefully at the image to answer the user's question
        2. The user is in Thailand - focus on identifying Thai text and language
        3. Use the scene context to understand what they're looking at
        4. Consider the conversation history for context
        5. Answer naturally and conversationally
        6. When asking about text: Translate Thai to English automatically
        7. When asking about prices: Show Thai baht (฿) and USD (~30฿ = $1)
        8. For menus: Identify Thai dishes, ingredients, and spice levels
        9. Be concise but helpful - the user is on the go
        10. If you can't see something clearly, say so honestly
        
        Answer the question now:
        """
        
        return prompt
    }
}

// MARK: - Conversation Message Model

struct ConversationMessage {
    let role: String  // "user" or "assistant"
    let text: String
    
    init(role: String, text: String) {
        self.role = role
        self.text = text
    }
    
    // Convert from Message model
    init(from message: Message) {
        self.role = message.role.rawValue
        self.text = message.text
    }
}

// MARK: - Quick Translation (Lightweight)

extension GeminiAPIService {
    /// Quick translation for simple text - uses lower temperature for consistency
    func quickTranslate(
        _ image: UIImage,
        from sourceLang: String,
        to targetLang: String
    ) async throws -> String {
        guard !apiKey.isEmpty else {
            throw GeminiTranslationError.invalidAPIKey
        }
        
        guard let imageData = image.jpegData(compressionQuality: imageCompressionQuality) else {
            throw GeminiTranslationError.imageConversionFailed
        }
        let base64Image = imageData.base64EncodedString()
        
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
                            "text": "Translate any \(sourceLang) text in this image to \(targetLang). Output ONLY the translation."
                        ]
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": 0.1,  // Very low for consistency
                "maxOutputTokens": 200,
                "topP": 0.8,
                "topK": 10
            ]
        ]
        
        guard let url = URL(string: endpoint) else {
            throw GeminiTranslationError.apiError("Invalid endpoint URL")
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse {
            guard (200...299).contains(httpResponse.statusCode) else {
                throw GeminiTranslationError.apiError("HTTP \(httpResponse.statusCode)")
            }
        }
        
        let geminiResponse = try JSONDecoder().decode(GeminiResponse.self, from: data)
        
        guard let text = geminiResponse.candidates.first?.content.parts.first?.text else {
            throw GeminiTranslationError.noContent
        }
        
        return text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }
}

// MARK: - Usage Examples

/*
 EXAMPLE 1: Simple visual question
 
 let answer = try await geminiAPI.answerVisualQuestion(
     image: currentFrame,
     sceneContext: "Thai restaurant menu with 8 items",
     question: "What vegetarian options are here?",
     conversationHistory: []
 )
 
 EXAMPLE 2: Follow-up question with context
 
 let history = [
     ConversationMessage(role: "user", text: "What's this dish?"),
     ConversationMessage(role: "assistant", text: "That's Pad Thai - rice noodles with shrimp")
 ]
 
 let answer = try await geminiAPI.answerVisualQuestion(
     image: currentFrame,
     sceneContext: "Thai restaurant menu, looking at dish #3",
     question: "What are the ingredients?",
     conversationHistory: history
 )
 
 EXAMPLE 3: Price inquiry
 
 let answer = try await geminiAPI.answerVisualQuestion(
     image: currentFrame,
     sceneContext: "Product package: spicy chips, 45 baht",
     question: "How much is this in dollars?",
     conversationHistory: []
 )
 // Expected: "This costs 45 baht, which is about $1.50 USD"
 */
