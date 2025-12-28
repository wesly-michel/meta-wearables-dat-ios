/*
 * ModelTestingView.swift
 * Ray-Ban Meta Translation App
 *
 * Testing interface for comparing:
 * - Different Gemini models (2.0 Flash, 1.5 Flash, 1.5 Pro)
 * - Different prompt strategies (Concise, Detailed, Structured)
 * - Temperature settings
 * - Translation consistency (multiple runs on same image)
 */

import SwiftUI
import MWDATCore

struct ModelTestingView: View {
    @StateObject private var viewModel: ModelTestingViewModel
    @State private var showSettings = false
    
    init() {
        _viewModel = StateObject(wrappedValue: ModelTestingViewModel(wearables: Wearables.shared))
    }
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Header
                headerView
                
                // Video feed (smaller)
                videoFeedView
                    .frame(height: 200)
                
                // Testing controls
                testingControlsView
                
                // Results
                resultsView
            }
        }
        .sheet(isPresented: $showSettings) {
            TestingSettingsView(viewModel: viewModel)
        }
    }
    
    // MARK: - Header
    
    private var headerView: some View {
        HStack {
            Text("Model Testing")
                .font(.headline)
                .foregroundColor(.white)
            
            Spacer()
            
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
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.gray)
                    Text("Waiting for video...")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }
        }
        .background(Color.gray.opacity(0.2))
    }
    
    // MARK: - Testing Controls
    
    private var testingControlsView: some View {
        VStack(spacing: 12) {
            // Capture button
            Button(action: {
                viewModel.captureFrameForTesting()
            }) {
                HStack {
                    Image(systemName: "camera.shutter.button")
                    Text("Capture Frame")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(10)
            }
            .disabled(!viewModel.hasActiveDevice || viewModel.isTesting)
            
            HStack(spacing: 12) {
                // Test all models
                Button(action: {
                    Task {
                        await viewModel.testAllModels()
                    }
                }) {
                    VStack(spacing: 4) {
                        Image(systemName: "cpu")
                        Text("Test All Models")
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.green)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
                .disabled(viewModel.capturedFrame == nil || viewModel.isTesting)
                
                // Test all prompts
                Button(action: {
                    Task {
                        await viewModel.testAllPrompts()
                    }
                }) {
                    VStack(spacing: 4) {
                        Image(systemName: "text.bubble")
                        Text("Test All Prompts")
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.orange)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
                .disabled(viewModel.capturedFrame == nil || viewModel.isTesting)
            }
            
            // Test consistency (3x same settings)
            Button(action: {
                Task {
                    await viewModel.testConsistency(runs: 3)
                }
            }) {
                HStack {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("Test Consistency (3 runs)")
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.purple)
                .foregroundColor(.white)
                .cornerRadius(10)
            }
            .disabled(viewModel.capturedFrame == nil || viewModel.isTesting)
            
            if viewModel.isTesting {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.2)
            }
        }
        .padding()
        .background(Color.black.opacity(0.5))
    }
    
    // MARK: - Results
    
    private var resultsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if viewModel.testResults.isEmpty {
                    Text("No results yet. Capture a frame and run tests.")
                        .foregroundColor(.gray)
                        .padding()
                } else {
                    ForEach(viewModel.testResults) { result in
                        TestResultCard(result: result)
                    }
                }
            }
            .padding()
        }
    }
}

// MARK: - Test Result Card

struct TestResultCard: View {
    let result: TestResult
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header with test type
            HStack {
                Image(systemName: result.icon)
                    .foregroundColor(result.color)
                
                Text(result.title)
                    .font(.headline)
                    .foregroundColor(.white)
                
                Spacer()
                
                Text(String(format: "%.2fs", result.duration))
                    .font(.caption)
                    .foregroundColor(.gray)
            }
            
            // Translation
            Text(result.translation)
                .font(.body)
                .foregroundColor(.white)
                .padding()
                .background(Color.gray.opacity(0.2))
                .cornerRadius(8)
            
            // Metadata
            HStack {
                if let model = result.model {
                    Label(model, systemImage: "cpu")
                        .font(.caption2)
                }
                
                if let strategy = result.promptStrategy {
                    Label(strategy, systemImage: "text.bubble")
                        .font(.caption2)
                }
                
                Spacer()
                
                if result.isSuccess {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                } else {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.red)
                }
            }
            .foregroundColor(.gray)
        }
        .padding()
        .background(Color.black.opacity(0.7))
        .cornerRadius(12)
    }
}

// MARK: - Settings View

struct TestingSettingsView: View {
    @ObservedObject var viewModel: ModelTestingViewModel
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            Form {
                Section("API Configuration") {
                    SecureField("Gemini API Key", text: $viewModel.apiKey)
                        .autocapitalization(.none)
                }
                
                Section("Default Model") {
                    Picker("Model", selection: $viewModel.selectedModel) {
                        Text("Gemini 2.0 Flash").tag(GeminiModel.flash2_0)
                        Text("Gemini 1.5 Flash").tag(GeminiModel.flash1_5)
                        Text("Gemini 1.5 Pro").tag(GeminiModel.pro1_5)
                    }
                }
                
                Section("Default Prompt") {
                    Picker("Strategy", selection: $viewModel.selectedPrompt) {
                        Text("Concise").tag(PromptStrategy.concise)
                        Text("Detailed").tag(PromptStrategy.detailed)
                        Text("Structured").tag(PromptStrategy.structured)
                    }
                }
                
                Section("Languages") {
                    Picker("From", selection: $viewModel.sourceLang) {
                        ForEach(["Thai", "Japanese", "Chinese", "Korean"], id: \.self) { lang in
                            Text(lang).tag(lang)
                        }
                    }
                    
                    Picker("To", selection: $viewModel.targetLang) {
                        ForEach(["English", "Spanish", "French"], id: \.self) { lang in
                            Text(lang).tag(lang)
                        }
                    }
                }
                
                Section("Testing") {
                    Button("Clear Results") {
                        viewModel.clearResults()
                    }
                    .foregroundColor(.red)
                    
                    Button("Start Streaming") {
                        Task {
                            await viewModel.startSession()
                        }
                    }
                    .disabled(viewModel.isStreaming)
                    
                    Button("Stop Streaming") {
                        Task {
                            await viewModel.stopSession()
                        }
                    }
                    .disabled(!viewModel.isStreaming)
                }
            }
            .navigationTitle("Testing Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    ModelTestingView()
}
