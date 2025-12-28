/*
 * ContinuousVisionView.swift
 * Ray-Ban Meta Translation App
 *
 * UI for Continuous Vision Mode - ask questions about what you see.
 */

import SwiftUI
import MWDATCore

struct ContinuousVisionView: View {
    @StateObject private var viewModel: ContinuousVisionViewModel
    @State private var showSettings = false
    
    init() {
        _viewModel = StateObject(wrappedValue: ContinuousVisionViewModel(wearables: Wearables.shared))
    }
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Header
                headerView
                
                // Compact video feed
                videoFeedView
                    .frame(height: 150)
                
                // Scene context banner
                sceneContextBanner
                
                // Conversation history
                conversationView
                
                // Voice status bar
                voiceStatusBar
                
                // Controls
                controlsView
            }
        }
        .alert("Error", isPresented: $viewModel.showError) {
            Button("OK") {
                viewModel.dismissError()
            }
        } message: {
            Text(viewModel.errorMessage)
        }
        .sheet(isPresented: $showSettings) {
            VisionSettingsView(viewModel: viewModel)
        }
    }
    
    // MARK: - Header
    
    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Continuous Vision")
                    .font(.headline)
                    .foregroundColor(.white)
                
                if viewModel.isActive {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                        Text("Active • \(viewModel.sessionDuration)")
                            .font(.caption2)
                            .foregroundColor(.green)
                    }
                }
            }
            
            Spacer()
            
            // Device status
            HStack(spacing: 6) {
                Circle()
                    .fill(viewModel.hasActiveDevice ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(viewModel.hasActiveDevice ? "Connected" : "No Device")
                    .font(.caption)
                    .foregroundColor(.white)
            }
            
            Button(action: { showSettings = true }) {
                Image(systemName: "gear")
                    .foregroundColor(.white)
            }
        }
        .padding()
        .background(Color.black.opacity(0.8))
    }
    
    // MARK: - Video Feed
    
    private var videoFeedView: some View {
        Group {
            if let frame = viewModel.currentVideoFrame {
                Image(uiImage: frame)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .clipped()
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 30))
                        .foregroundColor(.gray)
                    Text("No video feed")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.gray.opacity(0.2))
    }
    
    // MARK: - Scene Context Banner
    
    private var sceneContextBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye.fill")
                .foregroundColor(sceneContextColor)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("What I see:")
                    .font(.caption2)
                    .foregroundColor(.gray)
                
                Text(viewModel.sceneContext.description)
                    .font(.caption)
                    .foregroundColor(.white)
                    .lineLimit(2)
            }
            
            Spacer()
            
            // Confidence indicator
            Circle()
                .fill(sceneContextColor)
                .frame(width: 6, height: 6)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.7))
    }
    
    private var sceneContextColor: Color {
        switch viewModel.sceneContext.confidence {
        case .high: return .green
        case .medium: return .orange
        case .low: return .red
        }
    }
    
    // MARK: - Conversation View
    
    private var conversationView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 12) {
                    if viewModel.conversationHistory.isEmpty {
                        emptyConversationView
                    } else {
                        ForEach(viewModel.conversationHistory) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                    }
                }
                .padding()
            }
            .onChange(of: viewModel.conversationHistory.count) {
                if let lastMessage = viewModel.conversationHistory.last {
                    withAnimation {
                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                    }
                }
            }
        }
    }
    
    private var emptyConversationView: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 50))
                .foregroundColor(.gray)
            
            Text("Ask questions about what you see")
                .font(.headline)
                .foregroundColor(.white)
            
            Text("Just speak naturally - I'm listening!")
                .font(.subheadline)
                .foregroundColor(.gray)
            
            VStack(alignment: .leading, spacing: 8) {
                ExampleQuestion(text: "What's this dish?")
                ExampleQuestion(text: "How much does this cost?")
                ExampleQuestion(text: "What are the ingredients?")
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
    
    // MARK: - Voice Status Bar
    
    private var voiceStatusBar: some View {
        HStack(spacing: 12) {
            // Status icon
            Image(systemName: viewModel.voiceQueryState.systemImage)
                .foregroundColor(statusColor)
                .font(.system(size: 20))
            
            // Status text
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.voiceQueryState.displayText)
                    .font(.subheadline)
                    .foregroundColor(.white)
                
                if !viewModel.currentTranscription.isEmpty {
                    Text(viewModel.currentTranscription)
                        .font(.caption)
                        .foregroundColor(.gray)
                        .lineLimit(1)
                }
            }
            
            Spacer()
            
            // Audio level indicator
            if viewModel.voiceQueryState == .listening {
                AudioLevelIndicator(level: viewModel.audioLevel)
            }
        }
        .padding()
        .background(statusBackgroundColor)
    }
    
    private var statusColor: Color {
        switch viewModel.voiceQueryState {
        case .idle: return .gray
        case .listening: return .blue
        case .processing: return .orange
        case .speaking: return .green
        case .error: return .red
        }
    }
    
    private var statusBackgroundColor: Color {
        switch viewModel.voiceQueryState {
        case .listening, .processing, .speaking:
            return Color.black.opacity(0.9)
        default:
            return Color.black.opacity(0.5)
        }
    }
    
    // MARK: - Controls
    
    private var controlsView: some View {
        HStack(spacing: 20) {
            // Clear conversation
            Button(action: {
                viewModel.clearConversation()
            }) {
                VStack(spacing: 4) {
                    Image(systemName: "trash")
                        .font(.system(size: 20))
                    Text("Clear")
                        .font(.caption)
                }
            }
            .foregroundColor(.white)
            .disabled(viewModel.conversationHistory.isEmpty)
            
            Spacer()
            
            // Start/Stop button
            Button(action: {
                Task {
                    if viewModel.isActive {
                        await viewModel.stopContinuousVision()
                    } else {
                        await viewModel.startContinuousVision()
                    }
                }
            }) {
                VStack(spacing: 4) {
                    Image(systemName: viewModel.isActive ? "stop.circle.fill" : "play.circle.fill")
                        .font(.system(size: 50))
                    Text(viewModel.isActive ? "Stop" : "Start")
                        .font(.caption)
                }
            }
            .foregroundColor(viewModel.isActive ? .red : .green)
            
            Spacer()
            
            // Settings
            Button(action: { showSettings = true }) {
                VStack(spacing: 4) {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 20))
                    Text("Settings")
                        .font(.caption)
                }
            }
            .foregroundColor(.white)
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 30)
        .background(Color.black.opacity(0.8))
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: Message
    
    var body: some View {
        HStack {
            if message.role == .user {
                Spacer()
            }
            
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                Text(message.text)
                    .font(.body)
                    .foregroundColor(.white)
                    .padding(12)
                    .background(bubbleColor)
                    .cornerRadius(16)
                
                Text(message.formattedTime)
                    .font(.caption2)
                    .foregroundColor(.gray)
            }
            .frame(maxWidth: 280, alignment: message.role == .user ? .trailing : .leading)
            
            if message.role == .assistant {
                Spacer()
            }
        }
    }
    
    private var bubbleColor: Color {
        message.role == .user ? Color.blue.opacity(0.8) : Color.gray.opacity(0.6)
    }
}

// MARK: - Example Question

struct ExampleQuestion: View {
    let text: String
    
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "lightbulb.fill")
                .font(.caption)
                .foregroundColor(.yellow)
            Text(text)
                .font(.caption)
                .foregroundColor(.gray)
        }
    }
}

// MARK: - Audio Level Indicator

struct AudioLevelIndicator: View {
    let level: Float
    
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(barColor(for: index))
                    .frame(width: 4, height: barHeight(for: index))
            }
        }
    }
    
    private func barHeight(for index: Int) -> CGFloat {
        let heights: [CGFloat] = [8, 12, 16, 12, 8]
        return heights[index]
    }
    
    private func barColor(for index: Int) -> Color {
        let threshold = Float(index) / 5.0
        return level >= threshold ? .blue : .gray.opacity(0.3)
    }
}

// MARK: - Settings View

struct VisionSettingsView: View {
    @ObservedObject var viewModel: ContinuousVisionViewModel
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            Form {
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
                
                Section("Session Info") {
                    HStack {
                        Text("Duration")
                        Spacer()
                        Text(viewModel.sessionDuration)
                            .foregroundColor(.gray)
                    }
                    
                    HStack {
                        Text("Messages")
                        Spacer()
                        Text("\(viewModel.messageCount)")
                            .foregroundColor(.gray)
                    }
                }
                
                Section("About") {
                    Text("Continuous Vision lets you ask questions about what you see through your Ray-Ban glasses. Just speak naturally - no wake word needed!")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }
            .navigationTitle("Vision Settings")
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
    ContinuousVisionView()
}
