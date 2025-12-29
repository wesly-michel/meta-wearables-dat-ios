/*
 * ContinuousVisionViewModel.swift
 * Ray-Ban Meta Translation App
 *
 * Orchestrates Continuous Vision Mode:
 * - Background scene tracking (Gemini)
 * - Voice query detection and processing (OpenAI Realtime)
 * - Conversation management
 * - Integration with Ray-Ban glasses streaming
 *
 * Uses OpenAI Realtime API for sub-second voice latency.
 * Server-side VAD, STT, and TTS eliminate audio tap conflicts.
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

    // OpenAI Realtime connection state
    @Published var isRealtimeConnected: Bool = false
    @Published var currentResponseText: String = ""

    // Settings
    @Published var sourceLang: String = "Thai"
    @Published var targetLang: String = "English"

    // Error handling
    @Published var showError: Bool = false
    @Published var errorMessage: String = ""

    // MARK: - Services

    private let sceneManager: SceneContextManager
    private var openAIService: OpenAIRealtimeService?  // OpenAI Realtime for voice (handles STT + TTS)
    private let geminiAPI: GeminiAPIService  // Gemini for visual Q&A (better vision than GPT-4o)

    // Mode toggle: true = use OpenAI Realtime for full voice flow (natural TTS)
    //              false = use iOS speech recognition + Gemini + iOS TTS (fallback)
    private var useOpenAIRealtime: Bool = true

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

        // Load API keys
        let geminiKey = UserDefaults.standard.string(forKey: "geminiAPIKey") ?? ""
        let openAIKey = UserDefaults.standard.string(forKey: "openaiAPIKey") ?? ""

        // Initialize services
        // Gemini for background scene tracking (every 5 seconds)
        self.sceneManager = SceneContextManager(apiKey: geminiKey, updateInterval: 5.0)
        // Gemini API for scene context only (not voice Q&A)
        self.geminiAPI = GeminiAPIService(apiKey: geminiKey, model: .flash2_5, promptStrategy: .detailed)

        // OpenAI Realtime for voice interactions (sub-second latency, natural voice)
        if !openAIKey.isEmpty {
            self.openAIService = OpenAIRealtimeService(apiKey: openAIKey, voice: .alloy)
            self.useOpenAIRealtime = true
        } else {
            self.useOpenAIRealtime = false
        }

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
        setupOpenAICallbacks()
        setupStreamingListeners()
    }
    
    // MARK: - Setup
    
    private func setupSceneManager() {
        sceneManager.onSceneUpdate = { [weak self] context in
            Task { @MainActor in
                self?.sceneContext = context
                // Keep OpenAI Realtime updated with scene context
                self?.openAIService?.updateSceneContext(context.description)
            }
        }
    }

    private func setupOpenAICallbacks() {
        guard let openAIService = openAIService else { return }
        
        // Connection state changes
        openAIService.onConnectionStateChanged = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .connected:
                    self?.isRealtimeConnected = true
                    print("✅ OpenAI Realtime connected")
                case .disconnected:
                    self?.isRealtimeConnected = false
                    print("🔌 OpenAI Realtime disconnected")
                case .connecting:
                    print("🔄 OpenAI Realtime connecting...")
                case .error(let message):
                    self?.isRealtimeConnected = false
                    print("❌ OpenAI Realtime error: \(message)")
                    self?.showErrorMessage("Realtime connection error: \(message)")
                }
            }
        }
        
        // Transcription updates (user's speech)
        openAIService.onTranscriptionReceived = { [weak self] (text: String, isFinal: Bool) in
            Task { @MainActor in
                guard let self = self else { return }

                self.currentTranscription = text

                if isFinal && !text.isEmpty {
                    print("📝 OpenAI Final: '\(text)'")
                    // Add user message to conversation history
                    let userMessage = Message(role: .user, text: text)
                    self.conversationHistory.append(userMessage)
                    self.currentSession?.addMessage(userMessage)
                    self.voiceQueryState = .processing
                } else {
                    if self.voiceQueryState == .idle {
                        self.voiceQueryState = .listening
                    }
                    print("📝 OpenAI Partial: '\(text)'")
                }
            }
        }

        // Response text (assistant's response)
        openAIService.onResponseReceived = { [weak self] (response: String) in
            Task { @MainActor in
                guard let self = self else { return }

                self.currentResponseText = response
                print("🤖 OpenAI Response: '\(response.prefix(100))...'")

                // Add assistant message to conversation history
                if !response.isEmpty {
                    let assistantMessage = Message(role: .assistant, text: response)
                    self.conversationHistory.append(assistantMessage)
                    self.currentSession?.addMessage(assistantMessage)
                }
            }
        }

        // Audio output events (OpenAI's natural TTS)
        openAIService.onAudioOutputStarted = { [weak self] in
            Task { @MainActor in
                self?.voiceQueryState = .speaking
                print("🔊 OpenAI natural voice started")
            }
        }

        openAIService.onAudioOutputCompleted = { [weak self] in
            Task { @MainActor in
                self?.voiceQueryState = .idle
                self?.currentTranscription = ""
                print("🔊 OpenAI natural voice completed")
            }
        }
        
        // Errors
        openAIService.onError = { [weak self] (error: Error) in
            Task { @MainActor in
                print("❌ OpenAI error: \(error.localizedDescription)")
                self?.showErrorMessage("OpenAI error: \(error.localizedDescription)")
            }
        }
    }
    
    private func setupStreamingListeners() {
        var frameCount = 0

        videoFrameListenerToken = streamSession.videoFramePublisher.listen { [weak self] videoFrame in
            Task { @MainActor [weak self] in
                guard let self = self else { return }

                if let image = videoFrame.makeUIImage() {
                    self.currentVideoFrame = image
                    frameCount += 1

                    // Update scene context (Gemini) if tracking
                    if self.isTrackingScene {
                        await self.sceneManager.updateSceneContext(from: image)
                    }

                    // Update OpenAI with current frame every 1 second (~24 frames at 24fps)
                    // More frequent updates ensure fresh visual context for voice queries
                    if frameCount % 24 == 0 {
                        self.openAIService?.updateCurrentImage(image)
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
    
    // MARK: - Service Reinitialization

    /// Reinitialize OpenAI service if API key was added after ViewModel creation
    private func ensureOpenAIServiceInitialized() -> Bool {
        // If already initialized, we're good
        if openAIService != nil {
            return true
        }

        // Try to load API key from UserDefaults (in case it was added later)
        let openAIKey = UserDefaults.standard.string(forKey: "openaiAPIKey") ?? ""
        if !openAIKey.isEmpty {
            self.openAIService = OpenAIRealtimeService(apiKey: openAIKey, voice: .alloy)
            setupOpenAICallbacks()
            print("✅ OpenAI service initialized with newly added API key")
            return true
        }

        return false
    }

    // MARK: - Continuous Vision Control

    func startContinuousVision() async {
        // Try to initialize OpenAI service if not already done
        guard ensureOpenAIServiceInitialized(), let openAIService = openAIService else {
            showErrorMessage("OpenAI API key not configured. Please add it in Settings (Translation tab).")
            return
        }

        // Connect to OpenAI Realtime API
        do {
            print("🔄 Connecting to OpenAI Realtime...")
            try await openAIService.connect()
            print("✅ OpenAI Realtime connected")
        } catch {
            showErrorMessage("Failed to connect to OpenAI: \(error.localizedDescription)")
            return
        }

        // Start video streaming from glasses
        await startStreamingSession()

        // Wait for stream to be ready
        try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5 seconds

        // Start scene tracking (Gemini for background context)
        isTrackingScene = true

        // Start audio capture for voice input
        do {
            try openAIService.startAudioCapture()
            print("🎤 Audio capture started - speak naturally!")
        } catch {
            showErrorMessage("Failed to start audio: \(error.localizedDescription)")
            return
        }

        // Create new session
        currentSession = ConversationSession()
        voiceQueryState = .idle

        print("✅ Continuous Vision Mode started with OpenAI Realtime")
        print("   🎤 Server-side VAD - no wake word needed")
        print("   🔊 Natural voice TTS (alloy)")
    }
    
    func stopContinuousVision() async {
        // Stop scene tracking
        isTrackingScene = false
        sceneManager.clearContext()

        // Stop OpenAI Realtime (audio capture + connection)
        openAIService?.stopAudioCapture()
        await openAIService?.disconnect()

        // Stop video streaming
        await streamSession.stop()

        voiceQueryState = .idle
        currentTranscription = ""
        currentResponseText = ""

        print("🛑 Continuous Vision Mode stopped")
    }
    
    // MARK: - Voice Handling
    //
    // With OpenAI Realtime, voice handling is automatic:
    // 1. Server-side VAD detects speech
    // 2. Whisper transcribes (onTranscriptionReceived callback)
    // 3. GPT-4o generates response (onResponseReceived callback)
    // 4. Natural TTS plays audio (onAudioOutputStarted/Completed callbacks)
    //
    // The current frame is periodically sent to OpenAI for visual context.

    /// Send current video frame to OpenAI for visual context
    func updateVisualContext() {
        guard let frame = currentVideoFrame else { return }
        openAIService?.updateCurrentImage(frame)
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
