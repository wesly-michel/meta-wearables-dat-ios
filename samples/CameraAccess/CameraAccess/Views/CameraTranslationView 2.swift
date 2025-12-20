/*
 * CameraTranslationView.swift
 * Ray-Ban Meta Translation App
 *
 * Main view for real-time camera-based translation.
 * Displays live video feed and translated text with performance metrics.
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
    
    @State private var apiKey: String = ""
    @State private var sourceLang: String = "Thai"
    @State private var targetLang: String = "English"
    
    let languages = ["English", "Thai", "Japanese", "Chinese", "Korean", "Spanish", "French", "German"]
    
    var body: some View {
        NavigationView {
            Form {
                Section("API Configuration") {
                    SecureField("Claude API Key", text: $apiKey)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                    
                    Button("Save API Key") {
                        UserDefaults.standard.set(apiKey, forKey: "claudeAPIKey")
                    }
                    .disabled(apiKey.isEmpty)
                    
                    Text("Get your API key from console.anthropic.com")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
                
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
                
                Section("Translation History") {
                    Text("\(viewModel.translationHistory.count) translations saved")
                        .foregroundColor(.gray)
                    
                    Button("Clear History", role: .destructive) {
                        viewModel.clearHistory()
                    }
                }
                
                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundColor(.gray)
                    }
                    
                    Link("Documentation", destination: URL(string: "https://docs.claude.com")!)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            apiKey = UserDefaults.standard.string(forKey: "claudeAPIKey") ?? ""
            sourceLang = viewModel.sourceLang
            targetLang = viewModel.targetLang
        }
    }
}

#Preview {
    CameraTranslationView()
}
