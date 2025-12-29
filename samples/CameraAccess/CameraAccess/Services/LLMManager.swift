/*
 * LLMManager.swift
 * Ray-Ban Meta Translation App
 *
 * Unified LLM interface with automatic fallback support.
 * Manages OpenAI Realtime, Gemini, and Claude providers.
 * Provides seamless switching and fallback when providers fail.
 */

import Foundation
import UIKit

// MARK: - Provider Types

enum LLMProvider: String, CaseIterable, Identifiable {
    case openAIRealtime = "openai_realtime"
    case gemini = "gemini"
    case claude = "claude"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAIRealtime: return "OpenAI Realtime"
        case .gemini: return "Gemini Flash"
        case .claude: return "Claude"
        }
    }

    var description: String {
        switch self {
        case .openAIRealtime: return "Sub-second latency, bidirectional audio"
        case .gemini: return "Fast, cost-effective, good vision"
        case .claude: return "High quality, detailed responses"
        }
    }

    var supportsRealtime: Bool {
        self == .openAIRealtime
    }

    var supportsVision: Bool {
        true  // All providers support vision
    }
}

// MARK: - LLM Response

struct LLMResponse {
    let text: String
    let provider: LLMProvider
    let latencyMs: Int
    let isFromFallback: Bool
}

// MARK: - LLM Manager Configuration

struct LLMManagerConfig {
    var primaryProvider: LLMProvider = .openAIRealtime
    var fallbackProviders: [LLMProvider] = [.gemini, .claude]
    var enableFallback: Bool = true
    var maxRetries: Int = 2
    var timeoutSeconds: TimeInterval = 10.0

    static var `default`: LLMManagerConfig {
        LLMManagerConfig()
    }

    static var geminiFirst: LLMManagerConfig {
        LLMManagerConfig(
            primaryProvider: .gemini,
            fallbackProviders: [.openAIRealtime, .claude]
        )
    }
}

// MARK: - LLM Manager

@MainActor
class LLMManager: ObservableObject {

    // MARK: - Published Properties

    @Published var currentProvider: LLMProvider
    @Published var isConnected: Bool = false
    @Published var isProcessing: Bool = false
    @Published var lastError: String?
    @Published var lastLatencyMs: Int = 0

    // Provider status
    @Published var providerStatus: [LLMProvider: Bool] = [:]

    // MARK: - Private Properties

    private var config: LLMManagerConfig
    private var openAIService: OpenAIRealtimeService?
    private var geminiService: GeminiAPIService?
    private var claudeService: ClaudeAPIService?

    // API Keys
    private var openAIKey: String { UserDefaults.standard.string(forKey: "openaiAPIKey") ?? "" }
    private var geminiKey: String { UserDefaults.standard.string(forKey: "geminiAPIKey") ?? "" }
    private var claudeKey: String { UserDefaults.standard.string(forKey: "claudeAPIKey") ?? "" }

    // Callbacks for realtime mode
    var onTranscription: ((String, Bool) -> Void)?
    var onResponse: ((String) -> Void)?
    var onAudioStarted: (() -> Void)?
    var onAudioCompleted: (() -> Void)?
    var onError: ((Error) -> Void)?

    // MARK: - Initialization

    init(config: LLMManagerConfig = .default) {
        self.config = config
        self.currentProvider = config.primaryProvider
        initializeProviderStatus()
    }

    private func initializeProviderStatus() {
        for provider in LLMProvider.allCases {
            providerStatus[provider] = hasAPIKey(for: provider)
        }
    }

    private func hasAPIKey(for provider: LLMProvider) -> Bool {
        switch provider {
        case .openAIRealtime: return !openAIKey.isEmpty
        case .gemini: return !geminiKey.isEmpty
        case .claude: return !claudeKey.isEmpty
        }
    }

    // MARK: - Configuration

    func updateConfig(_ newConfig: LLMManagerConfig) {
        config = newConfig
        currentProvider = newConfig.primaryProvider
    }

    func setPrimaryProvider(_ provider: LLMProvider) {
        config.primaryProvider = provider
        currentProvider = provider
    }

    // MARK: - Connection (for Realtime providers)

    func connect() async throws {
        guard currentProvider.supportsRealtime else {
            // Non-realtime providers don't need connection
            isConnected = true
            return
        }

        switch currentProvider {
        case .openAIRealtime:
            try await connectOpenAI()
        default:
            isConnected = true
        }
    }

    func disconnect() async {
        if let openAIService = openAIService {
            await openAIService.disconnect()
        }
        openAIService = nil
        isConnected = false
    }

    private func connectOpenAI() async throws {
        guard !openAIKey.isEmpty else {
            throw LLMManagerError.missingAPIKey(.openAIRealtime)
        }

        openAIService = OpenAIRealtimeService(apiKey: openAIKey)
        setupOpenAICallbacks()
        try await openAIService?.connect()
        isConnected = true
    }

    private func setupOpenAICallbacks() {
        openAIService?.onTranscriptionReceived = { [weak self] text, isFinal in
            self?.onTranscription?(text, isFinal)
        }
        openAIService?.onResponseReceived = { [weak self] text in
            self?.onResponse?(text)
        }
        openAIService?.onAudioOutputStarted = { [weak self] in
            self?.onAudioStarted?()
        }
        openAIService?.onAudioOutputCompleted = { [weak self] in
            self?.onAudioCompleted?()
        }
        openAIService?.onError = { [weak self] error in
            self?.onError?(error)
        }
    }

    // MARK: - Audio Capture (Realtime mode)

    func startAudioCapture() throws {
        guard currentProvider == .openAIRealtime else { return }
        try openAIService?.startAudioCapture()
    }

    func stopAudioCapture() {
        openAIService?.stopAudioCapture()
    }

    // MARK: - Visual Q&A

    func answerVisualQuestion(
        image: UIImage,
        question: String,
        sceneContext: String = "",
        conversationHistory: [ConversationMessage] = []
    ) async throws -> LLMResponse {
        isProcessing = true
        lastError = nil
        defer { isProcessing = false }

        let startTime = Date()

        // Try primary provider first
        do {
            let response = try await queryProvider(
                currentProvider,
                image: image,
                question: question,
                sceneContext: sceneContext,
                conversationHistory: conversationHistory
            )
            let latency = Int(Date().timeIntervalSince(startTime) * 1000)
            lastLatencyMs = latency

            return LLMResponse(
                text: response,
                provider: currentProvider,
                latencyMs: latency,
                isFromFallback: false
            )

        } catch {
            print("⚠️ Primary provider \(currentProvider.displayName) failed: \(error)")
            lastError = error.localizedDescription

            // Try fallbacks if enabled
            if config.enableFallback {
                return try await tryFallbacks(
                    image: image,
                    question: question,
                    sceneContext: sceneContext,
                    conversationHistory: conversationHistory,
                    startTime: startTime
                )
            }

            throw error
        }
    }

    private func tryFallbacks(
        image: UIImage,
        question: String,
        sceneContext: String,
        conversationHistory: [ConversationMessage],
        startTime: Date
    ) async throws -> LLMResponse {

        for fallbackProvider in config.fallbackProviders {
            guard hasAPIKey(for: fallbackProvider) else {
                print("⏭️ Skipping \(fallbackProvider.displayName) - no API key")
                continue
            }

            do {
                print("🔄 Trying fallback: \(fallbackProvider.displayName)")

                let response = try await queryProvider(
                    fallbackProvider,
                    image: image,
                    question: question,
                    sceneContext: sceneContext,
                    conversationHistory: conversationHistory
                )

                let latency = Int(Date().timeIntervalSince(startTime) * 1000)
                lastLatencyMs = latency

                return LLMResponse(
                    text: response,
                    provider: fallbackProvider,
                    latencyMs: latency,
                    isFromFallback: true
                )

            } catch {
                print("⚠️ Fallback \(fallbackProvider.displayName) failed: \(error)")
                continue
            }
        }

        throw LLMManagerError.allProvidersFailed
    }

    private func queryProvider(
        _ provider: LLMProvider,
        image: UIImage,
        question: String,
        sceneContext: String,
        conversationHistory: [ConversationMessage]
    ) async throws -> String {

        switch provider {
        case .openAIRealtime:
            // For visual Q&A, use text-based query with image
            guard let openAIService = openAIService else {
                throw LLMManagerError.providerNotInitialized(.openAIRealtime)
            }
            // Note: OpenAI Realtime handles this via sendTextQuery
            try await openAIService.sendTextQuery(question, withImage: image)
            // For non-realtime flow, we'd need to wait for response
            // This is a simplified version - full implementation would use callbacks
            throw LLMManagerError.realtimeRequiresCallbacks

        case .gemini:
            let service = getOrCreateGeminiService()
            return try await service.answerVisualQuestion(
                image: image,
                sceneContext: sceneContext,
                question: question,
                conversationHistory: conversationHistory
            )

        case .claude:
            // Claude doesn't have visual Q&A in current implementation
            // Fall through to translation-style query
            let service = getOrCreateClaudeService()
            return try await service.translateImage(image, sourceLang: "Image", targetLang: "Description")
        }
    }

    // MARK: - Translation

    func translateImage(
        _ image: UIImage,
        sourceLang: String,
        targetLang: String
    ) async throws -> LLMResponse {
        isProcessing = true
        lastError = nil
        defer { isProcessing = false }

        let startTime = Date()

        // For translation, prefer Gemini (optimized for this)
        let translationProviders: [LLMProvider] = [.gemini, .claude]

        for provider in translationProviders {
            guard hasAPIKey(for: provider) else { continue }

            do {
                let response = try await translateWithProvider(
                    provider,
                    image: image,
                    sourceLang: sourceLang,
                    targetLang: targetLang
                )

                let latency = Int(Date().timeIntervalSince(startTime) * 1000)
                lastLatencyMs = latency

                return LLMResponse(
                    text: response,
                    provider: provider,
                    latencyMs: latency,
                    isFromFallback: provider != .gemini
                )

            } catch {
                print("⚠️ Translation with \(provider.displayName) failed: \(error)")
                continue
            }
        }

        throw LLMManagerError.allProvidersFailed
    }

    private func translateWithProvider(
        _ provider: LLMProvider,
        image: UIImage,
        sourceLang: String,
        targetLang: String
    ) async throws -> String {

        switch provider {
        case .gemini:
            let service = getOrCreateGeminiService()
            return try await service.translateImage(image, sourceLang: sourceLang, targetLang: targetLang)

        case .claude:
            let service = getOrCreateClaudeService()
            return try await service.translateImage(image, sourceLang: sourceLang, targetLang: targetLang)

        case .openAIRealtime:
            throw LLMManagerError.operationNotSupported("Translation not optimized for realtime API")
        }
    }

    // MARK: - Service Management

    private func getOrCreateGeminiService() -> GeminiAPIService {
        if geminiService == nil {
            geminiService = GeminiAPIService(
                apiKey: geminiKey,
                model: .flash2_5,
                promptStrategy: .detailed
            )
        }
        return geminiService!
    }

    private func getOrCreateClaudeService() -> ClaudeAPIService {
        if claudeService == nil {
            claudeService = ClaudeAPIService(apiKey: claudeKey)
        }
        return claudeService!
    }

    // MARK: - Scene Context (for Realtime mode)

    func updateSceneContext(_ context: String) {
        openAIService?.updateSceneContext(context)
    }

    func updateCurrentImage(_ image: UIImage) {
        openAIService?.updateCurrentImage(image)
    }

    // MARK: - Provider Health Check

    func checkProviderHealth() async -> [LLMProvider: Bool] {
        var results: [LLMProvider: Bool] = [:]

        for provider in LLMProvider.allCases {
            results[provider] = hasAPIKey(for: provider)
        }

        providerStatus = results
        return results
    }

    // MARK: - Available Providers

    var availableProviders: [LLMProvider] {
        LLMProvider.allCases.filter { hasAPIKey(for: $0) }
    }

    var realtimeAvailable: Bool {
        hasAPIKey(for: .openAIRealtime)
    }
}

// MARK: - Errors

enum LLMManagerError: Error {
    case missingAPIKey(LLMProvider)
    case providerNotInitialized(LLMProvider)
    case allProvidersFailed
    case operationNotSupported(String)
    case realtimeRequiresCallbacks

    var localizedDescription: String {
        switch self {
        case .missingAPIKey(let provider):
            return "Missing API key for \(provider.displayName)"
        case .providerNotInitialized(let provider):
            return "\(provider.displayName) is not initialized"
        case .allProvidersFailed:
            return "All LLM providers failed"
        case .operationNotSupported(let reason):
            return "Operation not supported: \(reason)"
        case .realtimeRequiresCallbacks:
            return "Realtime API requires callback-based flow"
        }
    }
}
