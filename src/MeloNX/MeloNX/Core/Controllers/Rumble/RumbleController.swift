//
//  RumbleController.swift
//  MeloNX
//
//  Created by MediaMoots on 2025/5/24.
//

import CoreHaptics
import Foundation

// Channel operations are confined to RumbleController's serial queue.
nonisolated protocol RumbleChannel: AnyObject {
    @discardableResult func restart() -> Bool
    func stop()
    func update(lowAmplitude: Float, lowFrequency: Float, highAmplitude: Float,
                highFrequency: Float, rumbleMultiplier: Float)
}

nonisolated final class RumbleController: @unchecked Sendable {
    private final class HapticChannel: RumbleChannel {
        private let engine: CHHapticEngine
        private let hapticEventDuration: TimeInterval
        private var lowHapticPlayer: CHHapticPatternPlayer?
        private var highHapticPlayer: CHHapticPatternPlayer?
        
        init?(engine: CHHapticEngine?, hapticEventDuration: TimeInterval) {
            guard let engine else { return nil }
            
            self.engine = engine
            self.hapticEventDuration = hapticEventDuration
            
            engine.isAutoShutdownEnabled = true
            engine.playsHapticsOnly = true
        }

        @discardableResult
        func restart() -> Bool {
            stop()
            do {
                try engine.start()
                try createPlayers()
                return true
            } catch {
                stop()
                return false
            }
        }

        func stop() {
            try? lowHapticPlayer?.stop(atTime: CHHapticTimeImmediate)
            try? highHapticPlayer?.stop(atTime: CHHapticTimeImmediate)
            lowHapticPlayer = nil
            highHapticPlayer = nil
            // Auto-shutdown idles the engine without racing a subsequent start.
        }

        func update(lowAmplitude: Float, lowFrequency: Float, highAmplitude: Float,
                    highFrequency: Float, rumbleMultiplier: Float) {
            if lowHapticPlayer == nil || highHapticPlayer == nil {
                guard restart() else { return }
            }
            do {
                try sendParameters(lowAmplitude: lowAmplitude, lowFrequency: lowFrequency,
                                   highAmplitude: highAmplitude, highFrequency: highFrequency,
                                   rumbleMultiplier: rumbleMultiplier)
            } catch {
                guard restart() else { return }
                try? sendParameters(lowAmplitude: lowAmplitude, lowFrequency: lowFrequency,
                                    highAmplitude: highAmplitude, highFrequency: highFrequency,
                                    rumbleMultiplier: rumbleMultiplier)
            }
        }

        private func sendParameters(
            lowAmplitude: Float,
            lowFrequency: Float,
            highAmplitude: Float,
            highFrequency: Float,
            rumbleMultiplier: Float
        ) throws {
            let lowIntensity = Self.clamp(lowAmplitude * rumbleMultiplier)
            let highIntensity = Self.clamp(highAmplitude * rumbleMultiplier)
            
            try lowHapticPlayer?.sendParameters([
                CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: lowIntensity, relativeTime: 0),
                CHHapticDynamicParameter(parameterID: .hapticSharpnessControl, value: Self.sharpness(for: lowFrequency, fallback: 0), relativeTime: 0),
            ], atTime: 0)
            
            try highHapticPlayer?.sendParameters([
                CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: highIntensity, relativeTime: 0),
                CHHapticDynamicParameter(parameterID: .hapticSharpnessControl, value: Self.sharpness(for: highFrequency, fallback: 1), relativeTime: 0),
            ], atTime: 0)
        }
        
        private func createPlayers() throws {
            lowHapticPlayer = try createPlayer(sharpness: 0)
            highHapticPlayer = try createPlayer(sharpness: 1)
            
            try sendParameters(lowAmplitude: 0, lowFrequency: 160, highAmplitude: 0, highFrequency: 320, rumbleMultiplier: 1)
            
            try lowHapticPlayer?.start(atTime: 0)
            try highHapticPlayer?.start(atTime: 0)
        }
        
        private func createPlayer(sharpness: Float) throws -> CHHapticPatternPlayer {
            let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: 1)
            let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
            let event = CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [intensity, sharpness],
                relativeTime: 0,
                duration: hapticEventDuration
            )
            
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            
            return try engine.makePlayer(with: pattern)
        }
        
        private static func sharpness(for frequency: Float, fallback: Float) -> Float {
            guard frequency.isFinite, frequency > 0 else { return fallback }
            
            let minHz: Float = 40
            let maxHz: Float = 1252
            let normalized = (log2(clamp(frequency, minHz, maxHz)) - log2(minHz)) / (log2(maxHz) - log2(minHz))
            
            return clamp(normalized)
        }
        
        private static func clamp(_ value: Float, _ lower: Float = 0, _ upper: Float = 1) -> Float {
            min(upper, max(lower, value))
        }
    }
    
    private var leftChannel: (any RumbleChannel)?
    private var rightChannel: (any RumbleChannel)?
    private var fallbackChannel: (any RumbleChannel)?
    private let rumbleMultiplier: Float
    private let hapticQueue = DispatchQueue(label: "com.stossy11.MeloNX.rumble", qos: .userInteractive)
    
    private let hapticEventDuration: TimeInterval = 20
    private var restartInterval: TimeInterval = 19
    private var restartTimer: DispatchSourceTimer?
    private var durationTimer: DispatchSourceTimer?
    private var enabled = false
    private var playbackID: UInt = 0
    private var commandID: UInt = 0
    private var current: (left: RumbleData.VibrationValue, right: RumbleData.VibrationValue)?

    init(engine: CHHapticEngine?, rumbleMultiplier: Float) {
        self.rumbleMultiplier = rumbleMultiplier
        fallbackChannel = HapticChannel(engine: engine, hapticEventDuration: hapticEventDuration)
    }

    init(leftEngine: CHHapticEngine?, rightEngine: CHHapticEngine?, fallbackEngine: CHHapticEngine?, rumbleMultiplier: Float) {
        self.rumbleMultiplier = rumbleMultiplier
        leftChannel = HapticChannel(engine: leftEngine, hapticEventDuration: hapticEventDuration)
        rightChannel = HapticChannel(engine: rightEngine, hapticEventDuration: hapticEventDuration)
        if leftChannel == nil || rightChannel == nil {
            leftChannel = nil
            rightChannel = nil
            fallbackChannel = HapticChannel(engine: fallbackEngine, hapticEventDuration: hapticEventDuration)
        }
    }

    // Also permits lifecycle checks without requiring physical haptic hardware.
    init(channel: any RumbleChannel, rumbleMultiplier: Float, restartInterval: TimeInterval = 19) {
        precondition(restartInterval > 0)
        self.rumbleMultiplier = rumbleMultiplier
        self.restartInterval = restartInterval
        fallbackChannel = channel
    }

    deinit {
        restartTimer?.cancel()
        durationTimer?.cancel()
        leftChannel?.stop()
        rightChannel?.stop()
        fallbackChannel?.stop()
    }

    func setActive(_ active: Bool) {
        hapticQueue.async { [weak self] in
            guard let self else { return }
            enabled = active
            if !active { stopPlayback() }
        }
    }

    private func stopPlayback() {
        playbackID &+= 1
        commandID &+= 1
        restartTimer?.cancel()
        restartTimer = nil
        durationTimer?.cancel()
        durationTimer = nil
        current = nil
        leftChannel?.stop()
        rightChannel?.stop()
        fallbackChannel?.stop()
    }

    public func rumble(lowFreq: Float, highFreq: Float, durationMs: UInt32? = nil) {
        let vibration = RumbleData.VibrationValue(
            amplitudeLow: lowFreq,
            frequencyLow: 160,
            amplitudeHigh: highFreq,
            frequencyHigh: 320
        )
        
        rumble(left: vibration, right: vibration, durationMs: durationMs)
    }
    
    public func rumble(data: RumbleData) {
        rumble(left: data.left, right: data.right, durationMs: data.durationMs)
    }
    
    private func rumble(left: RumbleData.VibrationValue, right: RumbleData.VibrationValue, durationMs: UInt32?) {
        hapticQueue.async { [weak self] in
            guard let self, enabled, rumbleMultiplier > 0,
                  leftChannel != nil || rightChannel != nil || fallbackChannel != nil else { return }
            guard [left.amplitudeLow, left.amplitudeHigh, right.amplitudeLow, right.amplitudeHigh]
                .contains(where: { $0.isFinite && $0 > 0 }) else {
                stopPlayback()
                return
            }
            current = (left, right)
            applyCurrent()
            scheduleRestartIfNeeded()
            scheduleStop(durationMs: durationMs)
        }
    }

    // All player mutations and timers share one queue, including pause/exit.
    private func applyCurrent() {
        guard let (left, right) = current else { return }
        if leftChannel != nil, rightChannel != nil {
            leftChannel?.update(lowAmplitude: left.amplitudeLow, lowFrequency: left.frequencyLow,
                                highAmplitude: left.amplitudeHigh, highFrequency: left.frequencyHigh,
                                rumbleMultiplier: rumbleMultiplier)
            rightChannel?.update(lowAmplitude: right.amplitudeLow, lowFrequency: right.frequencyLow,
                                 highAmplitude: right.amplitudeHigh, highFrequency: right.frequencyHigh,
                                 rumbleMultiplier: rumbleMultiplier)
        } else {
            fallbackChannel?.update(
                lowAmplitude: max(left.amplitudeLow, right.amplitudeLow),
                lowFrequency: weightedFrequency(left.frequencyLow, left.amplitudeLow, right.frequencyLow, right.amplitudeLow, fallback: 160),
                highAmplitude: max(left.amplitudeHigh, right.amplitudeHigh),
                highFrequency: weightedFrequency(left.frequencyHigh, left.amplitudeHigh, right.frequencyHigh, right.amplitudeHigh, fallback: 320),
                rumbleMultiplier: rumbleMultiplier)
        }
    }

    private func scheduleRestartIfNeeded() {
        guard restartTimer == nil else { return }
        let id = playbackID
        let timer = DispatchSource.makeTimerSource(queue: hapticQueue)
        timer.schedule(deadline: .now() + restartInterval, repeating: restartInterval, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self, enabled, playbackID == id, current != nil else { return }
            leftChannel?.restart()
            rightChannel?.restart()
            fallbackChannel?.restart()
            applyCurrent()
        }
        restartTimer = timer
        timer.resume()
    }

    private func scheduleStop(durationMs: UInt32?) {
        commandID &+= 1
        durationTimer?.cancel()
        durationTimer = nil
        guard let durationMs, durationMs > 0, durationMs != UInt32.max else { return }
        let id = commandID
        let timer = DispatchSource.makeTimerSource(queue: hapticQueue)
        timer.schedule(deadline: .now() + Double(durationMs) / 1000)
        timer.setEventHandler { [weak self] in
            guard let self, commandID == id else { return }
            stopPlayback()
        }
        durationTimer = timer
        timer.resume()
    }

    private func weightedFrequency(_ firstFrequency: Float, _ firstAmplitude: Float, _ secondFrequency: Float, _ secondAmplitude: Float, fallback: Float) -> Float {
        let totalAmplitude = firstAmplitude + secondAmplitude
        
        guard totalAmplitude > 0 else { return fallback }
        
        return ((firstFrequency * firstAmplitude) + (secondFrequency * secondAmplitude)) / totalAmplitude
    }
}
