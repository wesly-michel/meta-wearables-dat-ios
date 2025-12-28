/*
 * FrameThrottler.swift
 * Ray-Ban Meta Translation App
 *
 * Throttles video frames to prevent excessive API calls and optimize costs.
 * Processes at most 1 frame per configured interval (default: 2 seconds).
 */

import Foundation

class FrameThrottler {
    private let interval: TimeInterval
    private var lastProcessedTime: Date?
    
    /// Initialize frame throttler
    /// - Parameter interval: Minimum time in seconds between processed frames (default: 2.0)
    init(interval: TimeInterval = 2.0) {
        self.interval = interval
    }
    
    /// Check if enough time has passed to process another frame
    /// - Returns: true if frame should be processed, false otherwise
    func shouldProcess() -> Bool {
        let now = Date()
        
        if let lastTime = lastProcessedTime {
            if now.timeIntervalSince(lastTime) < interval {
                return false
            }
        }
        
        lastProcessedTime = now
        return true
    }
    
    /// Reset the throttler (useful when starting/stopping streaming)
    func reset() {
        lastProcessedTime = nil
    }
    
    /// Get the time remaining until next frame can be processed
    /// - Returns: Seconds remaining, or 0 if ready to process
    func timeUntilNextFrame() -> TimeInterval {
        guard let lastTime = lastProcessedTime else {
            return 0
        }
        
        let elapsed = Date().timeIntervalSince(lastTime)
        return max(0, interval - elapsed)
    }
}
