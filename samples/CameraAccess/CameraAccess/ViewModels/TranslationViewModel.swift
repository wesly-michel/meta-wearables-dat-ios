/*
 * TranslationViewModel.swift
 * Ray-Ban Meta Translation App
 *
 * Handles real-time translation using Gemini 2.0 Flash API.
 * 40x cheaper than Claude (~$2-5/month vs $81-126/month for 30min/day usage)
 */

import MWDATCamera
import MWDATCore
import SwiftUI

@MainActor
class TranslationViewModel: ObservableObject {
    // MARK: - Published Properties
    
    @Published var currentVideoFrame: UIImage?
    @Published var hasReceivedFirstFrame: Bool = false
    @Published var streamingStatus: StreamingStatus = .stopped
    @Published var showError: Bool = false
    @Published var errorMessage: String = ""
    @Published var hasActiveDevice: Bool = false
    
    @Published var currentTranslation: String = ""
    @Published var translationHistory: [Translation] = []
    @Published var isTranslating = false
    @Published var translationError: String?
    
    // Language settings
    @Published var sourceLang: String = "Thai"
    @Published var targetLang: String = "English"
    
    // Performance metrics
    @Published var lastTranslationTime: TimeInterval = 0
    @Published var framesProcessed: Int = 0
    @Published var framesSkipped: Int = 0
    
    var isStreaming: Bool {
        streamingStatus != .stopped
    }
    
    // MARK: - Services
    
    private let geminiAPI: GeminiAPIService
    private let frameThrottler: FrameThrottler
    private let ttsService: TTSService
    
    // SDK components
    private var streamSession: StreamSession
    private var stateListenerToken: AnyListenerToken?
    private var videoFrameListenerToken: AnyListenerToken?
    private var errorListenerToken: AnyListenerToken?
    private let wearables: WearablesInterface
    private let deviceSelector: AutoDeviceSelector
    private var deviceMonitorTask: Task<Void, Never>?
    
    // Settings
    private let enableTTS: Bool = true
    private let throttleInterval: TimeInterval = 2.0
    
    // MARK: - Initialization
    
    init(wearables: WearablesInterface) {
        self.wearables = wearables
        
        // Initialize services with Gemini
        let apiKey = UserDefaults.standard.string(forKey: "geminiAPIKey") ?? ""
        // Use Flash 2.5 with CONCISE prompt for fastest real-time translation
        // (Testing tab can use detailed prompts, but real-time needs speed)
        self.geminiAPI = GeminiAPIService(apiKey: apiKey, model: .flash2_5, promptStrategy: .concise)
        self.frameThrottler = FrameThrottler(interval: throttleInterval)
        self.ttsService = TTSService()
        
        // Setup streaming session
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
        
        // Setup listeners
        setupListeners()
        
        // Load translation history
        loadTranslationHistory()
    }
    
    // MARK: - Setup
    
    private func setupListeners() {
        // State listener
        stateListenerToken = streamSession.statePublisher.listen { [weak self] state in
            Task { @MainActor [weak self] in
                self?.updateStatusFromState(state)
            }
        }
        
        // Video frame listener with translation
        videoFrameListenerToken = streamSession.videoFramePublisher.listen { [weak self] videoFrame in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                
                if let image = videoFrame.makeUIImage() {
                    self.currentVideoFrame = image
                    if !self.hasReceivedFirstFrame {
                        self.hasReceivedFirstFrame = true
                    }
                    
                    // Process frame for translation
                    await self.processFrameForTranslation(image)
                }
            }
        }
        
        // Error listener
        errorListenerToken = streamSession.errorPublisher.listen { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let newErrorMessage = formatStreamingError(error)
                if newErrorMessage != self.errorMessage {
                    showStreamError(newErrorMessage)
                }
            }
        }
        
        updateStatusFromState(streamSession.state)
    }
    
    // MARK: - Session Control
    
    func handleStartStreaming() async {
        let permission = Permission.camera
        do {
            let status = try await wearables.checkPermissionStatus(permission)
            if status == .granted {
                await startSession()
                return
            }
            let requestStatus = try await wearables.requestPermission(permission)
            if requestStatus == .granted {
                await startSession()
                return
            }
            showStreamError("Permission denied")
        } catch {
            showStreamError("Permission error: \(error.localizedDescription)")
        }
    }
    
    func startSession() async {
        frameThrottler.reset()
        framesProcessed = 0
        framesSkipped = 0
        await streamSession.start()
    }
    
    func stopSession() async {
        ttsService.stop()
        await streamSession.stop()
    }
    
    // MARK: - Frame Processing
    
    private func processFrameForTranslation(_ image: UIImage) async {
        // Check throttle
        guard frameThrottler.shouldProcess() else {
            framesSkipped += 1
            return
        }
        
        // Don't translate if already in progress
        guard !isTranslating else {
            framesSkipped += 1
            return
        }
        
        framesProcessed += 1
        isTranslating = true
        translationError = nil
        
        let startTime = Date()
        
        do {
            let translation = try await geminiAPI.translateImage(
                image,
                sourceLang: sourceLang,
                targetLang: targetLang
            )
            
            // Calculate latency
            lastTranslationTime = Date().timeIntervalSince(startTime)
            
            // Update UI
            currentTranslation = translation
            
            // Add to history
            let translationRecord = Translation(
                sourceText: "[Image]",
                translatedText: translation,
                sourceLang: sourceLang,
                targetLang: targetLang,
                mode: .camera
            )
            translationHistory.insert(translationRecord, at: 0)
            saveTranslationHistory()
            
            // Speak translation through glasses
            if enableTTS && !translation.isEmpty && translation != "No text found" {
                let languageCode = TTSService.languageCode(for: targetLang)
                await ttsService.speak(translation, language: languageCode)
            }
            
        } catch let error as GeminiTranslationError {
            translationError = error.localizedDescription
            print("❌ Translation failed: \(error.localizedDescription)")
        } catch {
            translationError = "Unknown error: \(error.localizedDescription)"
            print("❌ Translation failed: \(error)")
        }
        
        isTranslating = false
    }
    
    // MARK: - Language Management
    
    func setLanguages(source: String, target: String) {
        sourceLang = source
        targetLang = target
        
        // Save preferences
        UserDefaults.standard.set(source, forKey: "sourceLang")
        UserDefaults.standard.set(target, forKey: "targetLang")
    }
    
    // MARK: - History Management
    
    private func loadTranslationHistory() {
        if let data = UserDefaults.standard.data(forKey: "translationHistory"),
           let history = try? JSONDecoder().decode([Translation].self, from: data) {
            translationHistory = history
        }
    }
    
    private func saveTranslationHistory() {
        // Keep only last 100 translations
        let recentHistory = Array(translationHistory.prefix(100))
        if let data = try? JSONEncoder().encode(recentHistory) {
            UserDefaults.standard.set(data, forKey: "translationHistory")
        }
    }
    
    func clearHistory() {
        translationHistory.removeAll()
        UserDefaults.standard.removeObject(forKey: "translationHistory")
    }
    
    // MARK: - Helper Methods
    
    private func updateStatusFromState(_ state: StreamSessionState) {
        switch state {
        case .stopped:
            currentVideoFrame = nil
            streamingStatus = .stopped
        case .waitingForDevice, .starting, .stopping, .paused:
            streamingStatus = .waiting
        case .streaming:
            streamingStatus = .streaming
        }
    }
    
    private func showStreamError(_ message: String) {
        errorMessage = message
        showError = true
    }
    
    func dismissError() {
        showError = false
        errorMessage = ""
    }
    
    private func formatStreamingError(_ error: StreamSessionError) -> String {
        switch error {
        case .internalError:
            return "An internal error occurred. Please try again."
        case .deviceNotFound:
            return "Device not found. Please ensure your device is connected."
        case .deviceNotConnected:
            return "Device not connected. Please check your connection and try again."
        case .timeout:
            return "The operation timed out. Please try again."
        case .videoStreamingError:
            return "Video streaming failed. Please try again."
        case .audioStreamingError:
            return "Audio streaming failed. Please try again."
        case .permissionDenied:
            return "Camera permission denied. Please grant permission in Settings."
        @unknown default:
            return "An unknown streaming error occurred."
        }
    }
    
    // MARK: - Performance Metrics
    
    var throttleEfficiency: String {
        let total = framesProcessed + framesSkipped
        guard total > 0 else { return "N/A" }
        let processed = Double(framesProcessed) / Double(total) * 100
        return String(format: "%.1f%% processed", processed)
    }
    
    var averageLatency: String {
        guard lastTranslationTime > 0 else { return "N/A" }
        return String(format: "%.2fs", lastTranslationTime)
    }
}
