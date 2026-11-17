import AVFoundation
import Foundation
import VQCore

/// Measures the microphone level so the app can tell when the user has stopped talking.
/// Only levels are computed; no audio is stored or sent anywhere.
final class MicLevelMonitor: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private var session: AVCaptureSession?
    private let queue = DispatchQueue(label: "vq.mic")
    private var onLevel: ((Double) -> Void)?
    private(set) var deviceName: String?

    static var permission: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static var permissionName: String {
        switch permission {
        case .authorized: return "granted"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }

    static func requestPermission(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    /// `preference`: "auto" follows Wispr Flow's microphone; anything else is matched against device names.
    static func device(preference: String) -> AVCaptureDevice? {
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
        if preference != "auto", !preference.isEmpty,
           let match = devices.first(where: { $0.localizedName.localizedCaseInsensitiveContains(preference) }) {
            return match
        }
        // Wispr's "Built-in mic" stays on the laptop microphone even when a headset is plugged in.
        let wispr = (WisprController.selectedMicrophoneName() ?? "").lowercased()
        if wispr.contains("built-in"), let builtIn = devices.first(where: { $0.uniqueID == "BuiltInMicrophoneDevice" }) {
            return builtIn
        }
        if wispr.contains("headphones"), let headset = devices.first(where: { $0.uniqueID == "BuiltInHeadphoneInputDevice" }) {
            return headset
        }
        return AVCaptureDevice.default(for: .audio)
    }

    /// Starts delivering levels (dBFS) on the main thread. False without permission or a device.
    @discardableResult
    func start(preference: String, onLevel: @escaping (Double) -> Void) -> Bool {
        stop()
        guard MicLevelMonitor.permission == .authorized, let device = MicLevelMonitor.device(preference: preference),
              let input = try? AVCaptureDeviceInput(device: device) else { return false }

        let session = AVCaptureSession()
        let output = AVCaptureAudioDataOutput()
        // 16-bit mono keeps the level maths trivial.
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
        ]
        guard session.canAddInput(input), session.canAddOutput(output) else { return false }
        session.addInput(input)
        session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: queue)

        self.onLevel = onLevel
        self.session = session
        deviceName = device.localizedName
        queue.async { session.startRunning() }
        return true
    }

    func stop() {
        guard let session else { return }
        self.session = nil
        onLevel = nil
        queue.async { session.stopRunning() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let level = MicLevelMonitor.level(of: sampleBuffer) else { return }
        DispatchQueue.main.async { [weak self] in self?.onLevel?(level) }
    }

    /// RMS of a 16-bit PCM buffer in dBFS (0 = full scale).
    private static func level(of sampleBuffer: CMSampleBuffer) -> Double? {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == kCMBlockBufferNoErr,
              let pointer, length >= 2 else { return nil }
        let count = length / 2
        var sum = 0.0
        pointer.withMemoryRebound(to: Int16.self, capacity: count) { samples in
            for index in 0..<count {
                let sample = Double(samples[index]) / 32768.0
                sum += sample * sample
            }
        }
        let rms = (sum / Double(count)).squareRoot()
        return rms > 0 ? max(20 * log10(rms), -120) : -120
    }
}
