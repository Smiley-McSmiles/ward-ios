import Combine
import Foundation
import AVFoundation
import CryptoKit
import UIKit

// MARK: - Attachment cache and downloads

final class AttachmentStore {
    static let shared = AttachmentStore()
    @Published private(set) var downloading: Set<String> = []

    private var cacheFolder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = support.appendingPathComponent("Media", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func localFile(for attachment: Attachment, settings: SettingsStore) async -> URL? {
        if let path = attachment.localPath, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        let cached = cachedFile(for: attachment)
        if FileManager.default.fileExists(atPath: cached.path) { return cached }
        guard shouldAutoDownload(attachment, settings: settings) else { return nil }
        return try? await download(attachment)
    }

    func cachedFile(for attachment: Attachment) -> URL {
        let hash = SHA256.hash(data: Data(attachment.url.utf8)).map { String(format: "%02x", $0) }.joined()
        let ext = (attachment.name as NSString).pathExtension
        return cacheFolder.appendingPathComponent(hash + (ext.isEmpty ? "" : "." + ext))
    }

    private func shouldAutoDownload(_ attachment: Attachment, settings: SettingsStore) -> Bool {
        let limit = Int64(settings.int("attachments.auto_download")) * 1024
        if attachment.isVoice { return true }
        if attachment.size == 0 { return false }
        if limit == 0 { return false }
        return attachment.size <= limit
    }

    @discardableResult
    func download(_ attachment: Attachment) async throws -> URL {
        guard !attachment.url.isEmpty else { throw WardError.network("This attachment has no download address.") }
        var urlString = attachment.url
        let aesgcm = FileCrypto.parse(attachment.url)
        if let aesgcm { urlString = aesgcm.httpsURL }
        guard let url = URL(string: urlString) else { throw WardError.network("Invalid attachment address.") }
        let destination = cachedFile(for: attachment)
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        await MainActor.run { _ = self.downloading.insert(attachment.id) }
        defer { Task { @MainActor in self.downloading.remove(attachment.id) } }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw WardError.network("The file could not be downloaded.")
        }
        let plaintext: Data
        if let aesgcm {
            do {
                plaintext = try FileCrypto.decrypt(data, key: aesgcm.key, iv: aesgcm.iv)
            } catch {
                throw WardError.encryption("This encrypted file could not be decrypted.")
            }
        } else {
            plaintext = data
        }
        try plaintext.write(to: destination, options: .atomic)
        return destination
    }

    func deleteAll() {
        try? FileManager.default.removeItem(at: cacheFolder)
    }

    func cacheSize() -> Int64 {
        let enumerator = FileManager.default.enumerator(at: cacheFolder, includingPropertiesForKeys: [.fileSizeKey])
        var total: Int64 = 0
        while let file = enumerator?.nextObject() as? URL {
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }
}

// MARK: - Audio playback

final class AudioPlayback: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = AudioPlayback()
    @Published private(set) var playingID: String? = nil
    @Published private(set) var progress: Double = 0
    @Published private(set) var duration: Double = 0
    private var player: AVAudioPlayer?
    private var timer: Timer?

    func toggle(url: URL, id: String, duration knownDuration: Double = 0) {
        if playingID == id {
            stop()
            return
        }
        stop()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.prepareToPlay()
            player.play()
            self.player = player
            duration = player.duration
            playingID = id
            progress = 0
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                guard let self, let player = self.player, player.duration > 0 else { return }
                self.progress = player.currentTime / player.duration
            }
        } catch {
            stop()
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        player?.stop(); player = nil
        playingID = nil
        progress = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.stop() }
    }
}

// MARK: - Voice recording

final class VoiceRecorder: NSObject, ObservableObject {
    @Published private(set) var recording = false
    @Published private(set) var duration: Double = 0
    @Published private(set) var levels: [Float] = Array(repeating: 0.08, count: 42)
    @Published var permissionDenied = false

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var fileURL: URL?

    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func start() async -> Bool {
        guard !recording else { return true }
        guard await requestPermission() else {
            permissionDenied = true
            return false
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("ward-voice-\(UUID().uuidString).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.isMeteringEnabled = true
            recorder.record()
            self.recorder = recorder
            self.fileURL = url
            recording = true
            duration = 0
            levels = Array(repeating: 0.08, count: 42)
            timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        } catch {
            permissionDenied = true
            recording = false
        }
        return recording
    }

    private func tick() {
        guard let recorder else { return }
        recorder.updateMeters()
        duration = recorder.currentTime
        let power = recorder.averagePower(forChannel: 0)
        let normalized = max(0.05, min(1, Float(pow(10.0, Double(power) / 42.0))))
        levels.removeFirst()
        levels.append(normalized)
        if duration > 300 { _ = stop() }
    }

    func stop() -> (URL, Double)? {
        guard let recorder else { return nil }
        recorder.stop()
        let url = fileURL
        let length = duration
        cleanUp()
        guard let url else { return nil }
        return (url, length)
    }

    func cancel() {
        recorder?.stop()
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        cleanUp()
    }

    private func cleanUp() {
        timer?.invalidate(); timer = nil
        recorder = nil
        fileURL = nil
        recording = false
        duration = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
