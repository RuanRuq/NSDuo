//
//  BaseController+Motion.swift
//  MeloNX
//
//  Created by Stossy11 on 16/11/2025.
//

import Foundation
import CoreMotion
import GameController
import UIKit

extension BaseController {
    func setMotionActive(_ active: Bool, useDeviceMotion: Bool = false) {
        guard let generation = motionSession.setActive(active && isActive, useDeviceMotion: useDeviceMotion) else { return }
        motionQueue.async { [weak self] in
            guard let self else { return }
            if active && self.isActive {
                self.motionSession.withActive(generation) {
                    self.stopMotion()
                    self.lastAccel = SIMD3(repeating: .nan)
                    self.lastGyro = SIMD3(repeating: .nan)
                    self.motionErrorReported = false
                    self.setupMotion(generation: generation, useDeviceMotion: useDeviceMotion)
                }
            } else {
                self.stopMotion()
                // Do not leave the last angular velocity active when a game disables motion.
                self.lastAccel = .zero
                self.lastGyro = .zero
                if self.isActive {
                    Ryujinx.setGamepadMotionSample(self.pointer, accelerometer: .zero, gyroscope: .zero)
                }
            }
        }
    }

    private func setupMotion(generation: UInt64, useDeviceMotion: Bool) {
        if !useDeviceMotion, let nativeController, nativeController.motion != nil, !self.usesDeviceHandlers {
            nativeController.motion?.sensorsActive = true
            
            // Thank you @BXYMartin :3
            nativeController.motion?.valueChangedHandler = { [weak self] m in
                guard let self = self else { return }
                let rawAccelX = Float(m.acceleration.x)
                let rawAccelY = Float(m.acceleration.y)
                let rawAccelZ = Float(m.acceleration.z)

                let rawGyroDeg = SIMD3<Float>(
                    Float(m.rotationRate.x),
                    Float(m.rotationRate.y),
                    Float(m.rotationRate.z)
                ) * 180.0 / .pi

                let accel = SIMD3(-rawAccelX, -rawAccelZ, rawAccelY)
                let gyro = SIMD3(rawGyroDeg.x, rawGyroDeg.z, -rawGyroDeg.y)

                self.submitMotion(accelerometer: accel, gyroscope: gyro, generation: generation, source: 2)
            }
        } else {
            guard self.motionManager.isDeviceMotionAvailable else {
                NSDuoDiagnostics.recordMotion(source: 1, state: -1)
                print("NSDuo motion: phone device motion unavailable")
                return
            }

            self.motionManager.deviceMotionUpdateInterval = 1.0 / 60.0 // 60Hz
            // Relative attitude needs no compass. Serialize callbacks with native submissions
            // so rotation samples cannot overtake one another under rendering load.
            self.motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: self.motionOperation) { [weak self] (data, error) in
                guard let self else { return }
                if error != nil {
                    self.motionSession.withActive(generation) {
                        if !self.motionErrorReported {
                            self.motionErrorReported = true
                            NSDuoDiagnostics.recordMotion(source: 1, state: -2)
                        }
                    }
                    return
                }
                guard let m = data else { return }

                let rawAccel = SIMD3<Float>(
                    -Float(m.gravity.x + m.userAcceleration.x),
                    -Float(m.gravity.y + m.userAcceleration.y),
                    -Float(m.gravity.z + m.userAcceleration.z)
                )
                
                let rawGyro = SIMD3<Float>(
                    Float(m.rotationRate.x),
                    -Float(m.rotationRate.y),
                    -Float(m.rotationRate.z)
                ) * (180.0 / .pi)

                let (mappedAccel, mappedGyro) = self.remapToSwitchCoords(accel: rawAccel, gyro: rawGyro)
                self.submitMotion(accelerometer: mappedAccel, gyroscope: mappedGyro, generation: generation, source: 1)
            }
        }
    }

    private func stopMotion() {
        nativeController?.motion?.valueChangedHandler = nil
        nativeController?.motion?.sensorsActive = false

        if motionManager.isDeviceMotionActive {
            motionManager.stopDeviceMotionUpdates()
        }
    }

    private func submitMotion(accelerometer: SIMD3<Float>, gyroscope: SIMD3<Float>, generation: UInt64, source: Int32) {
        guard isActive,
              accelerometer.x.isFinite, accelerometer.y.isFinite, accelerometer.z.isFinite,
              gyroscope.x.isFinite, gyroscope.y.isFinite, gyroscope.z.isFinite else { return }
        
        let pointer = self.pointer
        
        motionQueue.async { [weak self] in
            guard let self, self.isActive else { return }
            self.motionSession.withActive(generation) {
                guard self.lastAccel != accelerometer || self.lastGyro != gyroscope else { return }
                if self.lastAccel.x.isNaN { NSDuoDiagnostics.recordMotion(source: source, state: 1) }
                self.lastAccel = accelerometer
                self.lastGyro = gyroscope
                Ryujinx.setGamepadMotionSample(pointer, accelerometer: accelerometer, gyroscope: gyroscope)
            }
        }
    }

    private func remapToSwitchCoords(accel: SIMD3<Float>, gyro: SIMD3<Float>) -> (SIMD3<Float>, SIMD3<Float>) {
        let orientation = currentMotionOrientation()

        var finalAccel: SIMD3<Float>
        var finalGyro: SIMD3<Float>

        switch orientation {
        case .landscapeLeft:
            finalAccel = SIMD3<Float>(accel.y, -accel.x, accel.z)
            finalGyro = SIMD3<Float>(gyro.y, -gyro.x, gyro.z)
        case .landscapeRight:
            finalAccel = SIMD3<Float>(-accel.y, accel.x, accel.z)
            finalGyro = SIMD3<Float>(-gyro.y, gyro.x, gyro.z)
        case .portraitUpsideDown:
            finalAccel = SIMD3<Float>(-accel.x, accel.z, accel.y)
            finalGyro = SIMD3<Float>(-gyro.x, gyro.z, gyro.y)
        default:
            finalAccel = SIMD3<Float>(accel.x, accel.z, -accel.y)
            finalGyro = SIMD3<Float>(gyro.x, gyro.z, -gyro.y)
        }

        return (finalAccel, finalGyro)
    }

    private func currentMotionOrientation() -> UIDeviceOrientation {
        let currentOrientation = UIDevice.current.orientation

        if currentOrientation.isValidInterfaceOrientation {
            orientation = currentOrientation
        }

        return orientation
    }
}
