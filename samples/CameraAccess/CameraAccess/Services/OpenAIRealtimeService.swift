/*
 * OpenAIRealtimeService.swift
 * Ray-Ban Meta Translation App
 *
 * Handles real-time bidirectional audio streaming with OpenAI Realtime API.
 * Provides sub-second latency for voice queries with built-in STT and TTS.
 */

import Foundation
import AVFoundation
import UIKit

// MARK: - Error Types

enum OpenAIRealtimeError: Error {
    case invalidAPIKey
    case connectionFailed(String)
    case audioSetupFailed(String)
    case sessionError(String)
    case responseError(String)

    var localizedDescription: String {
        switch self {
        case .invalidAPIKey:
            return "Invalid or missing OpenAI API key"
        case .connectionFailed(let message):
            return "Connection failed: \(message)"
        case .audioSetupFailed(let message):
            return "Audio setup failed: \(message)"
        case .sessionError(let message):
            return "Session error: \(message)"
        case .responseError(let message):
            return "Response error: \(message)"
        }
    }
}

// MARK: - Connection State

enum RealtimeConnectionState {
    case disconnected
    case connecting
    case connected
    case error(String)
}

// MARK: - Voice Options

/// Available voices for OpenAI Realtime TTS
/// Each voice has different characteristics - experiment to find the best fit
enum OpenAIVoice: String, CaseIterable {
    case alloy = "alloy"        // Neutral, balanced (default)
    case echo = "echo"          // Warm, conversational
    case shimmer = "shimmer"    // Clear, expressive
    case ash = "ash"            // Calm, measured
    case ballad = "ballad"      // Soft, gentle
    case coral = "coral"        // Friendly, upbeat
    case sage = "sage"          // Wise, thoughtful
    case verse = "verse"        // Dynamic, engaging

    var description: String {
        switch self {
        case .alloy: return "Neutral and balanced"
        case .echo: return "Warm and conversational"
        case .shimmer: return "Clear and expressive"
        case .ash: return "Calm and measured"
        case .ballad: return "Soft and gentle"
        case .coral: return "Friendly and upbeat"
        case .sage: return "Wise and thoughtful"
        case .verse: return "Dynamic and engaging"
        }
    }
}

// MARK: - OpenAI Realtime Service

class OpenAIRealtimeService: NSObject {

    // MARK: - Properties

    private let apiKey: String
    private let model: String
    private(set) var voice: OpenAIVoice
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?

    // Audio handling
    private let audioEngine = AVAudioEngine()
    private var audioPlayer: AVAudioPlayerNode?
    private var audioFormat: AVAudioFormat?
    private var isCapturingAudio = false

    // State
    private(set) var connectionState: RealtimeConnectionState = .disconnected
    private var currentResponseId: String?
    private var pendingAudioData: [Data] = []

    // Scene context for visual queries
    private var currentSceneContext: String = ""
    private var currentImageBase64: String?

    // Callbacks
    var onConnectionStateChanged: ((RealtimeConnectionState) -> Void)?
    var onTranscriptionReceived: ((String, Bool) -> Void)?  // (text, isFinal)
    var onResponseReceived: ((String) -> Void)?
    var onAudioOutputStarted: (() -> Void)?
    var onAudioOutputCompleted: (() -> Void)?
    var onError: ((Error) -> Void)?

    // MARK: - Initialization

    init(apiKey: String, model: String = "gpt-4o-realtime-preview-2024-12-17", voice: OpenAIVoice = .alloy) {
        self.apiKey = apiKey
        self.model = model
        self.voice = voice
        super.init()
    }

    // MARK: - Voice Configuration

    /// Change the voice used for TTS responses
    /// Note: This will take effect on the next session configuration update
    func setVoice(_ newVoice: OpenAIVoice) {
        voice = newVoice
        print("🔊 Voice changed to: \(newVoice.rawValue) - \(newVoice.description)")
    }

    /// Update voice and reconfigure the session (if connected)
    func setVoiceAndReconfigure(_ newVoice: OpenAIVoice) async throws {
        voice = newVoice
        if case .connected = connectionState {
            try await configureSession()
            print("🔊 Voice updated to: \(newVoice.rawValue) and session reconfigured")
        }
    }

    // MARK: - Connection Management

    func connect() async throws {
        guard !apiKey.isEmpty else {
            throw OpenAIRealtimeError.invalidAPIKey
        }

        updateConnectionState(.connecting)

        // Create WebSocket URL
        guard let url = URL(string: "wss://api.openai.com/v1/realtime?model=\(model)") else {
            throw OpenAIRealtimeError.connectionFailed("Invalid URL")
        }

        // Create URL session with custom configuration
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300

        urlSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)

        // Create WebSocket request with auth headers
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")

        webSocketTask = urlSession?.webSocketTask(with: request)
        webSocketTask?.resume()

        // Start receiving messages
        receiveMessages()

        // Wait for connection confirmation
        try await Task.sleep(nanoseconds: 500_000_000)  // 0.5 seconds

        if case .error(let message) = connectionState {
            throw OpenAIRealtimeError.connectionFailed(message)
        }

        // Configure session
        try await configureSession()

        updateConnectionState(.connected)
        print("✅ OpenAI Realtime: Connected")
    }

    func disconnect() async {
        stopAudioCapture()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        updateConnectionState(.disconnected)
        print("🔌 OpenAI Realtime: Disconnected")
    }

    private func updateConnectionState(_ state: RealtimeConnectionState) {
        connectionState = state
        Task { @MainActor in
            onConnectionStateChanged?(state)
        }
    }

    // MARK: - Session Configuration

    private func configureSession() async throws {
        let sessionConfig: [String: Any] = [
            "type": "session.update",
            "session": [
                "modalities": ["text", "audio"],
                "instructions": buildSystemPrompt(),
                "voice": voice.rawValue,  // Use configurable voice
                "input_audio_format": "pcm16",
                "output_audio_format": "pcm16",
                "input_audio_transcription": [
                    "model": "whisper-1"
                ],
                "turn_detection": [
                    "type": "server_vad",
                    "threshold": 0.5,
                    "prefix_padding_ms": 300,
                    "silence_duration_ms": 500
                ]
            ]
        ]

        try await sendMessage(sessionConfig)
        print("📝 OpenAI Realtime: Session configured with voice: \(voice.rawValue)")
    }

    private func buildSystemPrompt() -> String {
        """
        You are a helpful visual assistant integrated with Ray-Ban Meta smart glasses.

        Your role:
        - Answer questions about what the user is looking at
        - Provide concise, spoken responses (keep under 2-3 sentences)
        - Be conversational and natural
        - If you receive scene context, use it to inform your answers

        Current scene context: \(currentSceneContext.isEmpty ? "No scene context available" : currentSceneContext)

        Guidelines:
        - Respond quickly and naturally
        - Don't mention technical details about how you work
        - If you can't see something clearly, say so briefly
        - Focus on being helpful and informative
        """
    }

    // MARK: - Scene Context

    func updateSceneContext(_ context: String) {
        currentSceneContext = context
    }

    func updateCurrentImage(_ image: UIImage) {
        // Resize and encode image for context
        let resized = resizeImage(image, targetWidth: 512)
        if let data = resized.jpegData(compressionQuality: 0.6) {
            currentImageBase64 = data.base64EncodedString()
        }
    }

    // MARK: - Audio Capture

    func startAudioCapture() throws {
        guard !isCapturingAudio else { return }

        // Configure audio session for HFP (Ray-Ban glasses)
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetoothHFP, .defaultToSpeaker])
        try audioSession.setActive(true)

        // Get input format
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Convert to PCM16 format expected by OpenAI (24kHz mono)
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true) else {
            throw OpenAIRealtimeError.audioSetupFailed("Failed to create target format")
        }

        // Install tap on input node
        inputNode.installTap(onBus: 0, bufferSize: 2400, format: inputFormat) { [weak self] buffer, _ in
            self?.processAudioBuffer(buffer, from: inputFormat, to: targetFormat)
        }

        try audioEngine.start()
        isCapturingAudio = true
        print("🎤 OpenAI Realtime: Audio capture started")
    }

    func stopAudioCapture() {
        guard isCapturingAudio else { return }

        if audioEngine.isRunning {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }
        isCapturingAudio = false
        print("🎤 OpenAI Realtime: Audio capture stopped")
    }

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer, from inputFormat: AVAudioFormat, to targetFormat: AVAudioFormat) {
        // Convert buffer to PCM16 data
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else { return }

        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio)

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCapacity) else { return }

        var error: NSError?
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        if let error = error {
            print("⚠️ Audio conversion error: \(error)")
            return
        }

        // Convert to base64 and send
        guard let int16Data = outputBuffer.int16ChannelData else { return }
        let data = Data(bytes: int16Data[0], count: Int(outputBuffer.frameLength) * 2)
        let base64Audio = data.base64EncodedString()

        // Send audio append event
        let audioEvent: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": base64Audio
        ]

        Task {
            try? await sendMessage(audioEvent)
        }
    }

    // MARK: - Audio Playback

    private func setupAudioPlayer() throws {
        guard audioPlayer == nil else { return }

        audioPlayer = AVAudioPlayerNode()
        audioEngine.attach(audioPlayer!)

        // Output format for playback (PCM16 24kHz mono)
        guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true) else {
            throw OpenAIRealtimeError.audioSetupFailed("Failed to create output format")
        }
        audioFormat = outputFormat

        audioEngine.connect(audioPlayer!, to: audioEngine.mainMixerNode, format: outputFormat)
    }

    private func playAudioData(_ base64Audio: String) {
        guard let data = Data(base64Encoded: base64Audio) else { return }
        guard let format = audioFormat else { return }

        // Convert data to audio buffer
        let frameCount = UInt32(data.count / 2)  // PCM16 = 2 bytes per sample
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }

        buffer.frameLength = frameCount

        data.withUnsafeBytes { rawBuffer in
            guard let int16Pointer = rawBuffer.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            buffer.int16ChannelData?[0].update(from: int16Pointer, count: Int(frameCount))
        }

        // Schedule and play
        audioPlayer?.scheduleBuffer(buffer, completionHandler: nil)

        if audioPlayer?.isPlaying == false {
            audioPlayer?.play()
        }
    }

    // MARK: - Message Handling

    private func sendMessage(_ message: [String: Any]) async throws {
        guard let webSocketTask = webSocketTask else {
            throw OpenAIRealtimeError.connectionFailed("Not connected")
        }

        let jsonData = try JSONSerialization.data(withJSONObject: message)
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            throw OpenAIRealtimeError.sessionError("Failed to encode message")
        }

        try await webSocketTask.send(.string(jsonString))
    }

    private func receiveMessages() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .success(let message):
                self?.handleMessage(message)
                // Continue receiving
                self?.receiveMessages()

            case .failure(let error):
                print("❌ WebSocket receive error: \(error)")
                self?.updateConnectionState(.error(error.localizedDescription))
                Task { @MainActor in
                    self?.onError?(error)
                }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            handleJSONMessage(text)
        case .data(let data):
            if let text = String(data: data, encoding: .utf8) {
                handleJSONMessage(text)
            }
        @unknown default:
            break
        }
    }

    private func handleJSONMessage(_ json: String) {
        guard let data = json.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else {
            return
        }

        switch type {
        case "session.created":
            print("✅ OpenAI Realtime: Session created")

        case "session.updated":
            print("✅ OpenAI Realtime: Session updated")

        case "input_audio_buffer.speech_started":
            print("🎤 Speech started")

        case "input_audio_buffer.speech_stopped":
            print("🎤 Speech stopped")
            // When speech ends, inject current image context for visual Q&A
            Task {
                await self.injectImageContext()
            }

        case "conversation.item.input_audio_transcription.completed":
            if let transcript = event["transcript"] as? String {
                print("📝 Transcription: \(transcript)")
                Task { @MainActor in
                    self.onTranscriptionReceived?(transcript, true)
                }
            }

        case "response.created":
            if let response = event["response"] as? [String: Any],
               let id = response["id"] as? String {
                currentResponseId = id
                print("🤖 Response started: \(id)")
            }

        case "response.audio_transcript.delta":
            if let delta = event["delta"] as? String {
                Task { @MainActor in
                    self.onResponseReceived?(delta)
                }
            }

        case "response.audio.delta":
            if let delta = event["delta"] as? String {
                // Play audio chunk
                playAudioData(delta)
            }

        case "response.audio.done":
            print("🔊 Audio response complete")
            Task { @MainActor in
                self.onAudioOutputCompleted?()
            }

        case "response.done":
            print("✅ Response complete")
            currentResponseId = nil

        case "error":
            if let error = event["error"] as? [String: Any],
               let message = error["message"] as? String {
                print("❌ OpenAI error: \(message)")
                Task { @MainActor in
                    self.onError?(OpenAIRealtimeError.responseError(message))
                }
            }

        default:
            // Ignore other events
            break
        }
    }

    // MARK: - Image Context Injection

    /// Injects the current image into the conversation for visual Q&A
    /// Called when speech stops, before OpenAI generates a response
    private func injectImageContext() async {
        guard let imageBase64 = currentImageBase64, !imageBase64.isEmpty else {
            print("📷 No image context available")
            return
        }

        print("📷 Injecting image context for visual Q&A...")

        // Add image as a system/context message
        let imageItem: [String: Any] = [
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": [
                    [
                        "type": "input_image",
                        "image_url": [
                            "url": "data:image/jpeg;base64,\(imageBase64)"
                        ]
                    ],
                    [
                        "type": "input_text",
                        "text": "[This is what I'm currently looking at through my Ray-Ban glasses camera]"
                    ]
                ]
            ]
        ]

        do {
            try await sendMessage(imageItem)
            print("✅ Image context injected")
        } catch {
            print("⚠️ Failed to inject image context: \(error)")
        }
    }

    // MARK: - Send Text Query (with image context)

    func sendTextQuery(_ text: String, withImage image: UIImage? = nil) async throws {
        var content: [[String: Any]] = []

        // Add image if provided
        if let image = image,
           let imageData = resizeImage(image, targetWidth: 512).jpegData(compressionQuality: 0.6) {
            let base64 = imageData.base64EncodedString()
            content.append([
                "type": "input_image",
                "image_url": [
                    "url": "data:image/jpeg;base64,\(base64)"
                ]
            ])
        }

        // Add text
        content.append([
            "type": "input_text",
            "text": text
        ])

        // Create conversation item
        let itemEvent: [String: Any] = [
            "type": "conversation.item.create",
            "item": [
                "type": "message",
                "role": "user",
                "content": content
            ]
        ]

        try await sendMessage(itemEvent)

        // Request response
        let responseEvent: [String: Any] = [
            "type": "response.create"
        ]

        try await sendMessage(responseEvent)
    }

    // MARK: - Commit Audio Buffer

    func commitAudioBuffer() async throws {
        let commitEvent: [String: Any] = [
            "type": "input_audio_buffer.commit"
        ]
        try await sendMessage(commitEvent)
    }

    // MARK: - Cancel Response

    func cancelCurrentResponse() async throws {
        let cancelEvent: [String: Any] = [
            "type": "response.cancel"
        ]
        try await sendMessage(cancelEvent)
        audioPlayer?.stop()
    }

    // MARK: - Helpers

    private func resizeImage(_ image: UIImage, targetWidth: CGFloat) -> UIImage {
        let scale = targetWidth / image.size.width
        let newHeight = image.size.height * scale
        let newSize = CGSize(width: targetWidth, height: newHeight)

        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}

// MARK: - URLSessionWebSocketDelegate

extension OpenAIRealtimeService: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        print("✅ WebSocket connected")
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        print("🔌 WebSocket closed: \(closeCode)")
        updateConnectionState(.disconnected)
    }
}
