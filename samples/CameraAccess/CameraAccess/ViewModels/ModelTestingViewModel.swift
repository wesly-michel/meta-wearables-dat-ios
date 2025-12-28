/*
 * ModelTestingViewModel.swift
 * Ray-Ban Meta Translation App
 *
 * Manages model testing, comparison, and result tracking.
 */

import MWDATCamera
import MWDATCore
import SwiftUI
import Foundation

struct TestResult: Identifiable {
    let id = UUID()
    let timestamp: Date
    let testType: TestType
    let translation: String
    let model: String?
    let promptStrategy: String?
    let duration: TimeInterval
    let isSuccess: Bool
    let error: String?
    
    enum TestType {
        case modelComparison
        case promptComparison
        case consistency
        case single
    }
    
    var title: String {
        switch testType {
        case .modelComparison:
            return model ?? "Model Test"
        case .promptComparison:
            return promptStrategy ?? "Prompt Test"
        case .consistency:
            return "Consistency Run"
        case .single:
            return "Single Translation"
        }
    }
    
    var icon: String {
        switch testType {
        case .modelComparison: return "cpu"
        case .promptComparison: return "text.bubble"
        case .consistency: return "arrow.triangle.2.circlepath"
        case .single: return "checkmark"
        }
    }
    
    var color: Color {
        isSuccess ? .green : .red
    }
}

@MainActor
class ModelTestingViewModel: ObservableObject {
    // MARK: - Published Properties
    
    @Published var currentVideoFrame: UIImage?
    @Published var capturedFrame: UIImage?
    @Published var hasActiveDevice: Bool = false
    @Published var isTesting: Bool = false
    @Published var testResults: [TestResult] = []
    
    // Settings
    @Published var apiKey: String = ""
    @Published var selectedModel: GeminiModel = .flash2_0
    @Published var selectedPrompt: PromptStrategy = .detailed
    @Published var sourceLang: String = "Thai"
    @Published var targetLang: String = "English"
    
    var isStreaming: Bool {
        streamSession.state == .streaming
    }
    
    // MARK: - Services
    
    private var geminiService: GeminiAPIService {
        GeminiAPIService(apiKey: apiKey, model: selectedModel, promptStrategy: selectedPrompt)
    }
    
    // SDK components
    private var streamSession: StreamSession
    private var stateListenerToken: AnyListenerToken?
    private var videoFrameListenerToken: AnyListenerToken?
    private let wearables: WearablesInterface
    private let deviceSelector: AutoDeviceSelector
    private var deviceMonitorTask: Task<Void, Never>?
    
    // MARK: - Initialization
    
    init(wearables: WearablesInterface) {
        self.wearables = wearables
        
        // Load API key
        self.apiKey = UserDefaults.standard.string(forKey: "geminiAPIKey") ?? ""
        
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
    }
    
    // MARK: - Setup
    
    private func setupListeners() {
        // Video frame listener
        videoFrameListenerToken = streamSession.videoFramePublisher.listen { [weak self] videoFrame in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if let image = videoFrame.makeUIImage() {
                    self.currentVideoFrame = image
                }
            }
        }
    }
    
    // MARK: - Session Control
    
    func startSession() async {
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
            print("Permission error: \(error)")
        }
    }
    
    func stopSession() async {
        await streamSession.stop()
    }
    
    // MARK: - Frame Capture
    
    func captureFrameForTesting() {
        guard let frame = currentVideoFrame else { return }
        capturedFrame = frame
        print("✅ Frame captured for testing")
    }
    
    // MARK: - Testing Methods
    
    /// Test all available models with the captured frame
    func testAllModels() async {
        guard let frame = capturedFrame else { return }
        
        isTesting = true
        defer { isTesting = false }
        
        let models: [GeminiModel] = [.flash2_0, .flash1_5, .pro1_5]
        
        for model in models {
            let service = GeminiAPIService(
                apiKey: apiKey,
                model: model,
                promptStrategy: selectedPrompt
            )
            
            let startTime = Date()
            
            do {
                let translation = try await service.translateImage(
                    frame,
                    sourceLang: sourceLang,
                    targetLang: targetLang
                )
                
                let duration = Date().timeIntervalSince(startTime)
                
                let result = TestResult(
                    timestamp: Date(),
                    testType: .modelComparison,
                    translation: translation,
                    model: model.displayName,
                    promptStrategy: selectedPrompt.displayName,
                    duration: duration,
                    isSuccess: true,
                    error: nil
                )
                
                testResults.insert(result, at: 0)
                
            } catch {
                let duration = Date().timeIntervalSince(startTime)
                
                let result = TestResult(
                    timestamp: Date(),
                    testType: .modelComparison,
                    translation: "Error: \(error.localizedDescription)",
                    model: model.displayName,
                    promptStrategy: selectedPrompt.displayName,
                    duration: duration,
                    isSuccess: false,
                    error: error.localizedDescription
                )
                
                testResults.insert(result, at: 0)
            }
        }
    }
    
    /// Test all prompt strategies with the captured frame
    func testAllPrompts() async {
        guard let frame = capturedFrame else { return }
        
        isTesting = true
        defer { isTesting = false }
        
        let strategies: [PromptStrategy] = [.concise, .detailed, .structured]
        
        for strategy in strategies {
            let service = GeminiAPIService(
                apiKey: apiKey,
                model: selectedModel,
                promptStrategy: strategy
            )
            
            let startTime = Date()
            
            do {
                let translation = try await service.translateImage(
                    frame,
                    sourceLang: sourceLang,
                    targetLang: targetLang
                )
                
                let duration = Date().timeIntervalSince(startTime)
                
                let result = TestResult(
                    timestamp: Date(),
                    testType: .promptComparison,
                    translation: translation,
                    model: selectedModel.displayName,
                    promptStrategy: strategy.displayName,
                    duration: duration,
                    isSuccess: true,
                    error: nil
                )
                
                testResults.insert(result, at: 0)
                
            } catch {
                let duration = Date().timeIntervalSince(startTime)
                
                let result = TestResult(
                    timestamp: Date(),
                    testType: .promptComparison,
                    translation: "Error: \(error.localizedDescription)",
                    model: selectedModel.displayName,
                    promptStrategy: strategy.displayName,
                    duration: duration,
                    isSuccess: false,
                    error: error.localizedDescription
                )
                
                testResults.insert(result, at: 0)
            }
        }
    }
    
    /// Test consistency by running the same translation multiple times
    func testConsistency(runs: Int = 3) async {
        guard let frame = capturedFrame else { return }
        
        isTesting = true
        defer { isTesting = false }
        
        let service = GeminiAPIService(
            apiKey: apiKey,
            model: selectedModel,
            promptStrategy: selectedPrompt
        )
        
        for run in 1...runs {
            let startTime = Date()
            
            do {
                let translation = try await service.translateImage(
                    frame,
                    sourceLang: sourceLang,
                    targetLang: targetLang
                )
                
                let duration = Date().timeIntervalSince(startTime)
                
                let result = TestResult(
                    timestamp: Date(),
                    testType: .consistency,
                    translation: "Run \(run)/\(runs): \(translation)",
                    model: selectedModel.displayName,
                    promptStrategy: selectedPrompt.displayName,
                    duration: duration,
                    isSuccess: true,
                    error: nil
                )
                
                testResults.insert(result, at: 0)
                
            } catch {
                let duration = Date().timeIntervalSince(startTime)
                
                let result = TestResult(
                    timestamp: Date(),
                    testType: .consistency,
                    translation: "Run \(run)/\(runs): Error - \(error.localizedDescription)",
                    model: selectedModel.displayName,
                    promptStrategy: selectedPrompt.displayName,
                    duration: duration,
                    isSuccess: false,
                    error: error.localizedDescription
                )
                
                testResults.insert(result, at: 0)
            }
            
            // Small delay between runs to avoid rate limiting
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        }
    }
    
    // MARK: - Results Management
    
    func clearResults() {
        testResults.removeAll()
    }
    
    // MARK: - Analysis Helpers
    
    func analyzeConsistency() -> String {
        let consistencyResults = testResults.filter { $0.testType == .consistency }
        guard !consistencyResults.isEmpty else {
            return "No consistency tests run yet"
        }
        
        // Group by translation text to find variations
        let translations = consistencyResults.compactMap { $0.isSuccess ? $0.translation : nil }
        let uniqueTranslations = Set(translations)
        
        if uniqueTranslations.count == 1 {
            return "✅ Perfect consistency: All \(translations.count) runs produced identical results"
        } else {
            return "⚠️ Variation detected: \(uniqueTranslations.count) different translations across \(translations.count) runs"
        }
    }
    
    func compareBestModel() -> String {
        let modelResults = testResults.filter { $0.testType == .modelComparison && $0.isSuccess }
        guard !modelResults.isEmpty else {
            return "No model comparison tests run yet"
        }
        
        // Find fastest
        if let fastest = modelResults.min(by: { $0.duration < $1.duration }) {
            return "Fastest: \(fastest.model ?? "Unknown") at \(String(format: "%.2fs", fastest.duration))"
        }
        
        return "Unable to determine best model"
    }
}
