/*
 * ContinuousVisionViewModel.swift
 * Ray-Ban Meta Translation App
 *
 * Orchestrates Continuous Vision Mode:
 * - Background scene tracking
 * - Voice query detection and processing
 * - Conversation management
 * - Integration with Ray-Ban glasses streaming
 */

import MWDATCamera
import MWDATCore
import SwiftUI
import AVFoundation

@MainActor
class ContinuousVisionViewModel: ObservableObject {
    
    // MARK: - Published Properties
    
    // Video streaming
    @Published var currentVideoFrame: UIImage?
    @Published var hasActiveDevice: Bool = false
    @Published var isStreaming: Bool = false
    
    // Scene tracking
    @Published var sceneContext: SceneContext = SceneContext()
    @Published var isTrackingScene: Bool = false
    
    // Voice & conversation
    @Published var voiceQueryState: VoiceQueryState = .idle
    @Published var currentTranscription: String = ""
    @Published var conversationHistory: [Message] = []
    @Published var currentSession: ConversationSession?
    
    // Audio visualization
    @Published var audioLevel: Float = 0.0
    
    // Settings
    @Published var sourceLang: String = "Thai"
    @Published var targetLang: String = "English"
    
    // Error handling
    @Published var showError: Bool = false
    @Published var errorMessage: String = ""
    
    // MARK: - Services
    
    private let sceneManager: SceneContextManager
    private let voiceDetector: VoiceActivationDetector
    private let voiceQuery: VoiceQueryService
    private let geminiAPI: GeminiAPIService
    private let ttsService: TTSService
    
    // SDK components
    private var streamSession: StreamSession
    private var videoFrameListenerToken: AnyListenerToken?
    private var stateListenerToken: AnyListenerToken?
    private let wearables: WearablesInterface
    private let deviceSelector: AutoDeviceSelector
    private var deviceMonitorTask: Task<Void, Never>?
    
    // Background tasks
    private var sceneTrackingTask: Task<Void, Never>?
    
    // MARK: - Initialization
    
    init(wearables: WearablesInterface) {
        self.wearables = wearables
        
        // Load API key
        let apiKey = UserDefaults.standard.string(forKey: "geminiAPIKey") ?? ""
        
        // Initialize services
        self.sceneManager = SceneContextManager(apiKey: apiKey, updateInterval: 2.5)
        self.voiceDetector = VoiceActivationDetector()
        self.voiceQuery = VoiceQueryService()
        self.geminiAPI = GeminiAPIService(apiKey: apiKey)
        self.ttsService = TTSService()
        
        // Setup streaming
        self.deviceSelector = AutoDeviceSelector(wearables: wearables)
        let config = StreamSessionConfig(
            videoCodec: VideoCodec.raw,
            resolution: StreamingResolution.low,
            frameRate: 24
        )
        self.streamSession = StreamSession(streamSessionConfig: config, deviceSelector: deviceSelector)
        
        // Monitor device availability
        deviceMonitorTask = Task { @MainActor in
            for await device in deviceSelector.activeDeviceStream() {
                self.hasActiveDevice = device != nil
            }
        }
        
        // Setup services
        setupSceneManager()
        setupVoiceDetector()
        setupVoiceQuery()
        setupStreamingListeners()
    }
    
    // MARK: - Setup
    
    private func setupSceneManager() {
        sceneManager.onSceneUpdate = { [weak self] context in
            Task { @MainActor in
                self?.sceneContext = context
            }
        }
    }
    
    private func setupVoiceDetector() {
        voiceDetector.onSpeechStarted = { [weak self] in
            Task { @MainActor in
                await self?.handleSpeechStarted()
            }
        }
        
        voiceDetector.onSpeechEnded = { [weak self] in
            Task { @MainActor in
                await self?.handleSpeechEnded()
            }
        }
        
        voiceDetector.onAudioLevel = { [weak self] level in
            Task { @MainActor in
                self?.audioLevel = VoiceActivationDetector.normalizeAudioLevel(level)
            }
        }
    }
    
    private func setupVoiceQuery() {
        voiceQuery.onPartialTranscription = { [weak self] text in
            Task { @MainActor in
                self?.currentTranscription = text
            }
        }
        
        voiceQuery.onFinalTranscription = { [weak self] text in
            Task { @MainActor in
                await self?.handleVoiceQuery(text)
            }
        }
        
        voiceQuery.onError = { [weak self] error in
            Task { @MainActor in
                self?.showErrorMessage("Voice recognition error: \(error.localizedDescription)")
            }
        }
    }
    
    private func setupStreamingListeners() {
        videoFrameListenerToken = streamSession.videoFramePublisher.listen { [weak self] videoFrame in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                
                if let image = videoFrame.makeUIImage() {
                    self.currentVideoFrame = image
                    
                    // Update scene if tracking
                    if self.isTrackingScene {
                        await self.sceneManager.updateSceneContext(from: image)
                    }
                }
            }
        }
        
        stateListenerToken = streamSession.statePublisher.listen { [weak self] state in
            Task { @MainActor [weak self] in
                self?.isStreaming = (state == .streaming)
            }
        }
    }
    
    // MARK: - Continuous Vision Control
    
    func startContinuousVision() async {
        // Start streaming
        await startStreamingSession()
        
        // Start scene tracking
        isTrackingScene = true
        
        // Start voice detection
        do {
            try voiceDetector.startMonitoring()
        } catch {
            showErrorMessage("Failed to start voice detection: \(error.localizedDescription)")
            return
        }
        
        // Request speech recognition permission
        let authorized = await voiceQuery.requestAuthorization()
        if !authorized {
            showErrorMessage("Speech recognition not authorized. Please enable in Settings.")
            return
        }
        
        // Create new session
        currentSession = ConversationSession()
        
        voiceQueryState = .idle
        
        print("✅ Continuous Vision Mode started")
    }
    
    func stopContinuousVision() async {
        // Stop scene tracking
        isTrackingScene = false
        sceneManager.clearContext()
        
        // Stop voice detection
        voiceDetector.stopMonitoring()
        
        // Stop any ongoing voice query
        await voiceQuery.stopListening()
        
        // Stop TTS
        ttsService.stop()
        
        // Stop streaming
        await streamSession.stop()
        
        voiceQueryState = .idle
        currentTranscription = ""
        
        print("🛑 Continuous Vision Mode stopped")
    }
    
    // MARK: - Voice Handling
    
    private func handleSpeechStarted() async {
        guard voiceQueryState == .idle else { return }
        
        voiceQueryState = .listening
        currentTranscription = ""
        
        // Start speech recognition
        do {
            try await voiceQuery.startListening()
        } catch {
            showErrorMessage("Failed to start listening: \(error.localizedDescription)")
            voiceQueryState = .error("Listen failed")
        }
    }
    
    private func handleSpeechEnded() async {
        guard voiceQueryState == .listening else { return }
        
        // Finalize transcription
        await voiceQuery.finalizeTranscription()
    }
    
    private func handleVoiceQuery(_ question: String) async {
        guard !question.isEmpty else {
            voiceQueryState = .idle
            return
        }
        
        // Add user message to conversation
        let userMessage = Message(role: .user, text: question)
        conversationHistory.append(userMessage)
        currentSession?.addMessage(userMessage)
        
        voiceQueryState = .processing
        
        // Get current frame for analysis
        guard let frame = currentVideoFrame else {
            voiceQueryState = .error("No video")
            return
        }
        
        // Convert conversation history
        let history = conversationHistory.suffix(6).map { ConversationMessage(from: $0) }
        
        do {
            // Get answer from Gemini
            let answer = try await geminiAPI.answerVisualQuestion(
                image: frame,
                sceneContext: sceneContext.description,
                question: question,
                conversationHistory: Array(history)
            )
            
            // Add assistant response to conversation
            let assistantMessage = Message(role: .assistant, text: answer)
            conversationHistory.append(assistantMessage)
            currentSession?.addMessage(assistantMessage)
            
            // Speak the answer
            voiceQueryState = .speaking
            let languageCode = TTSService.languageCode(for: targetLang)
            await ttsService.speak(answer, language: languageCode)
            
            voiceQueryState = .idle
            currentTranscription = ""
            
        } catch {
            showErrorMessage("Failed to answer question: \(error.localizedDescription)")
            voiceQueryState = .error("Answer failed")
            
            // Return to idle after error
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            voiceQueryState = .idle
        }
    }
    
    // MARK: - Streaming Control
    
    private func startStreamingSession() async {
        let permission = Permission.camera
        do {
            let status = try await wearables.checkPermissionStatus(permission)
            if status == .granted {
                await streamSession.start()
                return
            }
            let requestStatus = try await wearables.requestPermission(permission)
            if requestStatus == .granted {
                await streamSession.start()
            }
        } catch {
            showErrorMessage("Permission error: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Conversation Management
    
    func clearConversation() {
        conversationHistory.removeAll()
        currentSession = ConversationSession()
        sceneManager.clearContext()
    }
    
    func saveConversation() {
        // TODO: Implement conversation saving to UserDefaults or file
    }
    
    // MARK: - Error Handling
    
    private func showErrorMessage(_ message: String) {
        errorMessage = message
        showError = true
    }
    
    func dismissError() {
        showError = false
        errorMessage = ""
    }
    
    // MARK: - Computed Properties
    
    var isActive: Bool {
        return isStreaming && isTrackingScene
    }
    
    var sessionDuration: String {
        currentSession?.formattedDuration ?? "00:00"
    }
    
    var messageCount: Int {
        conversationHistory.count
    }
}
