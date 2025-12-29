/*
 * CameraTranslationView.swift
 * Ray-Ban Meta Translation App
 *
 * Main view for real-time camera-based translation.
 * Uses Gemini 2.0 Flash - 40x cheaper than Claude!
 */

import SwiftUI
import MWDATCore

struct CameraTranslationView: View {
    @StateObject private var viewModel: TranslationViewModel
    @State private var showSettings = false
    
    init() {
        _viewModel = StateObject(wrappedValue: TranslationViewModel(wearables: Wearables.shared))
    }
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Header with status
                headerView
                
                // Video feed
                videoFeedView
                
                // Translation display
                translationView
                
                // Controls
                controlsView
                
                // Performance metrics (debug)
                #if DEBUG
                metricsView
                #endif
            }
        }
        .alert("Translation Error", isPresented: .constant(viewModel.translationError != nil)) {
            Button("OK") {
                viewModel.translationError = nil
            }
        } message: {
            if let error = viewModel.translationError {
                Text(error)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(viewModel: viewModel)
        }
    }
    
    // MARK: - Header
    
    private var headerView: some View {
        HStack {
            Text("Ray-Ban Translate")
                .font(.headline)
                .foregroundColor(.white)
            
            Spacer()
            
            // Connection status
            Circle()
                .fill(viewModel.hasActiveDevice ? Color.green : Color.red)
                .frame(width: 10, height: 10)
            
            Text(viewModel.hasActiveDevice ? "Connected" : "Disconnected")
                .font(.caption)
                .foregroundColor(.white)
            
            Button(action: { showSettings = true }) {
                Image(systemName: "gear")
                    .foregroundColor(.white)
            }
        }
        .padding()
        .background(Color.black.opacity(0.5))
    }
    
    // MARK: - Video Feed
    
    private var videoFeedView: some View {
        Group {
            if let frame = viewModel.currentVideoFrame {
                Image(uiImage: frame)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .overlay(
                        viewModel.isTranslating ?
                        ProgressView()
                            .scaleEffect(1.5)
                            .tint(.white) : nil
                    )
            } else {
                VStack(spacing: 20) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.gray)
                    
                    Text(viewModel.hasActiveDevice ?
                         "Waiting for video..." :
                         "Connect Ray-Ban glasses")
                        .foregroundColor(.gray)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxHeight: .infinity)
    }
    
    // MARK: - Translation Display
    
    private var translationView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(viewModel.sourceLang) → \(viewModel.targetLang)")
                    .font(.caption)
                    .foregroundColor(.gray)
                
                Spacer()
                
                if viewModel.lastTranslationTime > 0 {
                    Text("⚡️ \(String(format: "%.2fs", viewModel.lastTranslationTime))")
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }
            
            ScrollView {
                Text(viewModel.currentTranslation.isEmpty ?
                     "Point at text to translate..." :
                     viewModel.currentTranslation)
                    .font(.title3)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            }
            .frame(height: 120)
        }
        .padding()
        .background(Color.black.opacity(0.8))
    }
    
    // MARK: - Controls
    
    private var controlsView: some View {
        HStack(spacing: 30) {
            // History button
            Button(action: {}) {
                VStack(spacing: 4) {
                    Image(systemName: "clock.fill")
                        .font(.system(size: 24))
                    Text("History")
                        .font(.caption)
                }
            }
            .foregroundColor(.white)
            .disabled(viewModel.translationHistory.isEmpty)
            
            // Start/Stop button
            Button(action: {
                Task {
                    if viewModel.isStreaming {
                        await viewModel.stopSession()
                    } else {
                        await viewModel.handleStartStreaming()
                    }
                }
            }) {
                VStack(spacing: 4) {
                    Image(systemName: viewModel.isStreaming ? "stop.circle.fill" : "play.circle.fill")
                        .font(.system(size: 50))
                    Text(viewModel.isStreaming ? "Stop" : "Start")
                        .font(.caption)
                }
            }
            .foregroundColor(viewModel.isStreaming ? .red : .green)
            
            // Settings button
            Button(action: { showSettings = true }) {
                VStack(spacing: 4) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 24))
                    Text("Settings")
                        .font(.caption)
                }
            }
            .foregroundColor(.white)
        }
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.5))
    }
    
    // MARK: - Debug Metrics
    
    private var metricsView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("🔍 Debug Metrics")
                .font(.caption2)
                .foregroundColor(.yellow)
            
            Text("Processed: \(viewModel.framesProcessed) | Skipped: \(viewModel.framesSkipped)")
                .font(.caption2)
                .foregroundColor(.white)
            
            Text("Efficiency: \(viewModel.throttleEfficiency)")
                .font(.caption2)
                .foregroundColor(.white)
            
            Text("💰 Model: Gemini 2.5 Flash (Concise)")
                .font(.caption2)
                .foregroundColor(.green)
        }
        .padding(8)
        .background(Color.black.opacity(0.7))
        .cornerRadius(8)
        .padding()
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @ObservedObject var viewModel: TranslationViewModel
    @Environment(\.dismiss) var dismiss

    // API Keys
    @State private var geminiAPIKey: String = ""
    @State private var openAIAPIKey: String = ""
    @State private var claudeAPIKey: String = ""
    @State private var showAPIKeys: Bool = false
    @State private var showSaveConfirmation: Bool = false

    // Languages
    @State private var sourceLang: String = "Thai"
    @State private var targetLang: String = "English"

    // Provider selection
    @State private var primaryProvider: LLMProvider = .gemini

    let languages = ["English", "Thai", "Japanese", "Chinese", "Korean", "Spanish", "French", "German"]

    var body: some View {
        NavigationView {
            Form {
                // MARK: - Provider Selection
                Section {
                    Picker("Primary Provider", selection: $primaryProvider) {
                        ForEach(LLMProvider.allCases) { provider in
                            HStack {
                                Text(provider.displayName)
                                if hasAPIKey(for: provider) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                        .font(.caption)
                                }
                            }
                            .tag(provider)
                        }
                    }

                    Text(primaryProvider.description)
                        .font(.caption)
                        .foregroundColor(.gray)

                    if primaryProvider == .openAIRealtime {
                        Label("Sub-second latency with built-in STT/TTS", systemImage: "bolt.fill")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                } header: {
                    Text("LLM Provider")
                } footer: {
                    Text("Other providers will be used as fallback if primary fails")
                }

                // MARK: - OpenAI Configuration
                Section {
                    APIKeyInputView(
                        label: "OpenAI API Key",
                        key: $openAIAPIKey,
                        showKey: showAPIKeys,
                        prefix: "sk-",
                        placeholder: "sk-..."
                    )

                    Button("Save OpenAI Key") {
                        saveAPIKey(openAIAPIKey, forKey: "openaiAPIKey")
                    }
                    .disabled(openAIAPIKey.isEmpty)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Get your API key:")
                            .font(.caption)
                            .foregroundColor(.gray)
                        Link("platform.openai.com/api-keys", destination: URL(string: "https://platform.openai.com/api-keys")!)
                            .font(.caption)
                        Text("⚡️ Realtime API: ~$0.06/min for voice")
                            .font(.caption2)
                            .foregroundColor(.blue)
                    }
                } header: {
                    HStack {
                        Text("OpenAI (Realtime)")
                        Spacer()
                        if hasAPIKey(for: .openAIRealtime) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        }
                    }
                }

                // MARK: - Gemini Configuration
                Section {
                    APIKeyInputView(
                        label: "Gemini API Key",
                        key: $geminiAPIKey,
                        showKey: showAPIKeys,
                        prefix: "AIza",
                        placeholder: "AIza..."
                    )

                    Button("Save Gemini Key") {
                        saveAPIKey(geminiAPIKey, forKey: "geminiAPIKey")
                    }
                    .disabled(geminiAPIKey.isEmpty)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Get your FREE API key:")
                            .font(.caption)
                            .foregroundColor(.gray)
                        Link("aistudio.google.com/apikey", destination: URL(string: "https://aistudio.google.com/apikey")!)
                            .font(.caption)
                        Text("💰 Flash 2.5: ~$2-5/month for vision")
                            .font(.caption2)
                            .foregroundColor(.green)
                    }
                } header: {
                    HStack {
                        Text("Gemini (Vision)")
                        Spacer()
                        if hasAPIKey(for: .gemini) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        }
                    }
                }

                // MARK: - Claude Configuration (Optional)
                Section {
                    APIKeyInputView(
                        label: "Claude API Key",
                        key: $claudeAPIKey,
                        showKey: showAPIKeys,
                        prefix: "sk-ant-",
                        placeholder: "sk-ant-..."
                    )

                    Button("Save Claude Key") {
                        saveAPIKey(claudeAPIKey, forKey: "claudeAPIKey")
                    }
                    .disabled(claudeAPIKey.isEmpty)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Get your API key:")
                            .font(.caption)
                            .foregroundColor(.gray)
                        Link("console.anthropic.com", destination: URL(string: "https://console.anthropic.com/")!)
                            .font(.caption)
                    }
                } header: {
                    HStack {
                        Text("Claude (Fallback)")
                        Spacer()
                        if hasAPIKey(for: .claude) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        }
                    }
                }

                // MARK: - Show/Hide Keys Toggle
                Section {
                    Toggle("Show API Keys", isOn: $showAPIKeys)
                }

                // MARK: - Languages
                Section("Languages") {
                    Picker("From", selection: $sourceLang) {
                        ForEach(languages, id: \.self) { lang in
                            Text(lang).tag(lang)
                        }
                    }

                    Picker("To", selection: $targetLang) {
                        ForEach(languages, id: \.self) { lang in
                            Text(lang).tag(lang)
                        }
                    }

                    Button("Apply") {
                        viewModel.setLanguages(source: sourceLang, target: targetLang)
                    }
                }

                // MARK: - History
                Section("Translation History") {
                    Text("\(viewModel.translationHistory.count) translations saved")
                        .foregroundColor(.gray)

                    Button("Clear History", role: .destructive) {
                        viewModel.clearHistory()
                    }
                }

                // MARK: - Provider Status
                Section("Provider Status") {
                    ForEach(LLMProvider.allCases) { provider in
                        HStack {
                            Text(provider.displayName)
                            Spacer()
                            if hasAPIKey(for: provider) {
                                Label("Ready", systemImage: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundColor(.green)
                            } else {
                                Label("No Key", systemImage: "xmark.circle")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                        }
                    }
                }

                // MARK: - About
                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("2.0.0 (Multi-Provider)")
                            .foregroundColor(.gray)
                    }

                    HStack {
                        Text("Primary Model")
                        Spacer()
                        Text(primaryProvider.displayName)
                            .foregroundColor(.blue)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        // Save provider preference
                        UserDefaults.standard.set(primaryProvider.rawValue, forKey: "primaryLLMProvider")
                        dismiss()
                    }
                }
            }
            .alert("Saved", isPresented: $showSaveConfirmation) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("API Key saved successfully!")
            }
        }
        .onAppear {
            loadSettings()
        }
    }

    // MARK: - Helpers

    private func loadSettings() {
        geminiAPIKey = UserDefaults.standard.string(forKey: "geminiAPIKey") ?? ""
        openAIAPIKey = UserDefaults.standard.string(forKey: "openaiAPIKey") ?? ""
        claudeAPIKey = UserDefaults.standard.string(forKey: "claudeAPIKey") ?? ""
        sourceLang = viewModel.sourceLang
        targetLang = viewModel.targetLang

        if let savedProvider = UserDefaults.standard.string(forKey: "primaryLLMProvider"),
           let provider = LLMProvider(rawValue: savedProvider) {
            primaryProvider = provider
        }
    }

    private func saveAPIKey(_ key: String, forKey userDefaultsKey: String) {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(trimmedKey, forKey: userDefaultsKey)
        showSaveConfirmation = true
    }

    private func hasAPIKey(for provider: LLMProvider) -> Bool {
        switch provider {
        case .openAIRealtime:
            return !openAIAPIKey.isEmpty || UserDefaults.standard.string(forKey: "openaiAPIKey")?.isEmpty == false
        case .gemini:
            return !geminiAPIKey.isEmpty || UserDefaults.standard.string(forKey: "geminiAPIKey")?.isEmpty == false
        case .claude:
            return !claudeAPIKey.isEmpty || UserDefaults.standard.string(forKey: "claudeAPIKey")?.isEmpty == false
        }
    }
}

// MARK: - API Key Input View

struct APIKeyInputView: View {
    let label: String
    @Binding var key: String
    let showKey: Bool
    let prefix: String
    let placeholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showKey {
                TextField(label, text: $key)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                    .textContentType(.password)
                    .font(.system(size: 14, design: .monospaced))
            } else {
                SecureField(label, text: $key)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
            }

            if !key.isEmpty {
                HStack {
                    Text("Length: \(key.count)")
                        .font(.caption2)
                        .foregroundColor(.gray)

                    if key.hasPrefix(prefix) {
                        Text("✅ Valid format")
                            .font(.caption2)
                            .foregroundColor(.green)
                    } else {
                        Text("⚠️ Should start with '\(prefix)'")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                }
            }
        }
    }
}

#Preview {
    CameraTranslationView()
}
