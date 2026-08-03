import AVFoundation
import Foundation

/// Recording and playing back a voice memo, and the levels the waveform draws.
///
/// One object rather than a recorder and a player, because the banner it serves
/// is one thing with three states and only ever does one of these at a time.
/// Keeping them together is what makes "retry" able to tear down whichever was
/// running without the caller knowing which that was.
@MainActor
final class VoiceMemo: NSObject, ObservableObject {

    /// **Sixty seconds, and the recorder enforces it as well as the timer.**
    ///
    /// A held button can be held by a pocket. `AVAudioRecorder.record(forDuration:)`
    /// stops on its own even if the app is busy, which the display timer cannot
    /// promise — so the cap is set on the recorder and the UI merely agrees
    /// with it.
    static let maxDuration: TimeInterval = 60

    /// How often a level is sampled, and so how quickly the waveform grows.
    ///
    /// Twelve a second: fast enough to follow speech, slow enough that a minute
    /// is 720 bars rather than something a `Path` has to think about.
    private static let sampleRate: TimeInterval = 1.0 / 12.0

    @Published private(set) var isRecording = false
    @Published private(set) var isPlaying = false
    /// Seconds recorded, or — during playback — seconds played.
    @Published private(set) var elapsed: TimeInterval = 0
    /// One bar per sample, already normalised to 0...1.
    @Published private(set) var levels: [CGFloat] = []
    /// The finished recording, ready to send. `nil` until one exists.
    @Published private(set) var recording: URL?
    @Published var failure: String?

    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var ticker: Task<Void, Never>?

    // MARK: - Permission

    /// Whether the microphone question has been answered at all, either way.
    ///
    /// Synchronous, and it has to be. The very first hold otherwise raises the
    /// system prompt, which takes the touch — so the finger is long gone by the
    /// time permission is granted and recording begins, and the release that
    /// should have ended it was delivered to an alert. The caller uses this to
    /// ask *first* and record on the next hold.
    var isPermissionDecided: Bool {
        if #available(iOS 17.0, *) {
            return AVAudioApplication.shared.recordPermission != .undetermined
        } else {
            return AVAudioSession.sharedInstance().recordPermission != .undetermined
        }
    }

    /// Whether the microphone may be used, asking once if it has never been.
    ///
    /// A denied microphone is **not** the same as a failed recording and must not
    /// be reported as one: nothing the user does in this app will fix it, so the
    /// message has to send them to Settings. The HealthKit lesson in CLAUDE.md is
    /// the same shape — a refused permission that looks like empty data is the
    /// hardest kind of failure to diagnose.
    func hasPermission() async -> Bool {
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted: return true
            case .denied:
                failure = "Written can't use the microphone. Turn it on in Settings."
                return false
            default:
                return await AVAudioApplication.requestRecordPermission()
            }
        } else {
            switch AVAudioSession.sharedInstance().recordPermission {
            case .granted: return true
            case .denied:
                failure = "Written can't use the microphone. Turn it on in Settings."
                return false
            default:
                return await withCheckedContinuation { continuation in
                    AVAudioSession.sharedInstance().requestRecordPermission {
                        continuation.resume(returning: $0)
                    }
                }
            }
        }
    }

    // MARK: - Recording

    func startRecording() async {
        guard !isRecording, await hasPermission() else { return }
        stopPlayback()

        // A fresh file per take, so a retry cannot half-overwrite the last one
        // and leave a header describing a length that is no longer there.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("written-memo-\(UUID().uuidString).m4a")

        do {
            let session = AVAudioSession.sharedInstance()
            // `.playAndRecord`, not `.record`: the review state plays the take
            // back without tearing the session down, and switching category
            // mid-flight drops the first fraction of a second.
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)

            let recorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 48_000,
            ])
            recorder.isMeteringEnabled = true
            recorder.delegate = self
            guard recorder.record(forDuration: Self.maxDuration) else {
                failure = "Couldn't start recording."
                return
            }
            self.recorder = recorder
            self.recording = nil
            levels = []
            elapsed = 0
            isRecording = true
            startTicking()
        } catch {
            failure = "Couldn't start recording — \(error.localizedDescription)"
        }
    }

    /// Ends the take and keeps it. Safe to call when nothing is recording.
    func stopRecording() {
        guard isRecording, let recorder else { return }
        isRecording = false
        ticker?.cancel(); ticker = nil
        recorder.stop()
        // Read the length off the recorder rather than the timer: the timer is
        // a display and can miss a tick, and this number ends up on the message.
        elapsed = min(elapsed, Self.maxDuration)
        recording = recorder.url
        self.recorder = nil
        // A take under a moment is a slip of the finger, not a message.
        if elapsed < 0.4 { discard() }
    }

    /// Throws the take away and returns to an empty state — the retry button.
    func discard() {
        stopPlayback()
        if isRecording { recorder?.stop(); isRecording = false }
        ticker?.cancel(); ticker = nil
        if let recording { try? FileManager.default.removeItem(at: recording) }
        recorder = nil
        recording = nil
        levels = []
        elapsed = 0
    }

    /// Everything down, session released. Called when the banner closes.
    func reset() {
        discard()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - Playback

    func togglePlayback() {
        if isPlaying { stopPlayback(); return }
        guard let recording else { return }
        do {
            let player = try AVAudioPlayer(contentsOf: recording)
            player.delegate = self
            player.play()
            self.player = player
            isPlaying = true
            elapsed = 0
            startTicking()
        } catch {
            failure = "Couldn't play that back."
        }
    }

    func stopPlayback() {
        guard isPlaying || player != nil else { return }
        player?.stop()
        player = nil
        isPlaying = false
        ticker?.cancel(); ticker = nil
        // Back to the take's full length, so the label reads as a duration
        // again rather than as wherever playback happened to stop.
        elapsed = duration
    }

    /// The take's length, which outlives playback's `elapsed`.
    private(set) var duration: TimeInterval = 0

    // MARK: - The tick

    /// One timer for both jobs: while recording it samples the meter and grows
    /// the waveform, while playing it just advances `elapsed`.
    private func startTicking() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.sampleRate))
                guard !Task.isCancelled, let self else { return }
                await MainActor.run { self.tick() }
            }
        }
    }

    private func tick() {
        if let recorder, isRecording {
            recorder.updateMeters()
            levels.append(Self.normalise(recorder.averagePower(forChannel: 0)))
            elapsed = recorder.currentTime
            duration = elapsed
        } else if let player, isPlaying {
            elapsed = player.currentTime
        }
    }

    /// Decibels to a bar height.
    ///
    /// `averagePower` is dBFS: 0 at full scale and −160 at silence, and it is
    /// **logarithmic**, so plotting it raw gives a waveform that is all tall
    /// bars — ordinary speech sits around −20. The floor is −50 rather than
    /// −160 because everything below it is room noise, and mapping it would
    /// spend most of the bar's height on the difference between two kinds of
    /// quiet.
    private static func normalise(_ decibels: Float) -> CGFloat {
        let floor: Float = -50
        guard decibels.isFinite else { return 0 }
        let clamped = max(floor, min(0, decibels))
        // Square-rooted so quiet speech still moves the bar; a linear map makes
        // everything but a shout look flat.
        return CGFloat(sqrt((clamped - floor) / -floor))
    }
}

#if DEBUG
extension VoiceMemo {
    /// Fabricates a take so the sheet can be looked at without a microphone.
    ///
    /// Layout only — the URL points at nothing, so playback will fail. That is
    /// the right trade: what cannot be checked in a simulator is the *sound*,
    /// and what cannot be checked on a device without a lot of fiddling is the
    /// geometry. This covers the second.
    func seedForPreview(_ state: String) {
        let fake = (0..<64).map { CGFloat(0.25 + 0.7 * abs(sin(Double($0) * 0.7))) }
        switch state {
        case "empty":
            levels = []; elapsed = 0; duration = 0; recording = nil
        case "holding":
            levels = Array(fake.prefix(22)); elapsed = 4; duration = 4
            recording = nil; isRecording = true
        default:
            levels = fake; elapsed = 3; duration = 3
            recording = URL(fileURLWithPath: "/dev/null")
        }
    }
}
#endif

extension VoiceMemo: AVAudioRecorderDelegate, AVAudioPlayerDelegate {

    /// Fires when the sixty-second cap stops the recorder on its own, which the
    /// held button never learns about otherwise.
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            guard isRecording else { return }
            isRecording = false
            ticker?.cancel(); ticker = nil
            recording = flag ? recorder.url : nil
            self.recorder = nil
            if !flag { failure = "That recording didn't save." }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in stopPlayback() }
    }
}

/// Playing one received memo, and reading its shape off the file.
///
/// Separate from `VoiceMemo` because the two are used at different moments and
/// by different views: that one is a recorder the sheet owns, this is a small
/// thing a bubble makes and throws away. Sharing them would put a recorder in
/// every row of the thread.
final class VoicePlayback: NSObject, AVAudioPlayerDelegate {

    private var player: AVAudioPlayer?
    private let onFinish: () -> Void

    init(data: Data, onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        super.init()
        player = try? AVAudioPlayer(data: data)
        player?.delegate = self
    }

    @discardableResult
    func start() -> Bool {
        // `.playback`, so a memo is audible with the ring switch silenced —
        // somebody who taps play has asked to hear it, and the silent switch is
        // about sounds they did not ask for.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        return player?.play() ?? false
    }

    func stop() {
        player?.stop()
        player = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in onFinish() }
    }

    /// The bars for a memo that arrived as a file.
    ///
    /// The live meter readings only ever existed in the sender's memory, and the
    /// recipient never had them — so rather than add a column to carry them, the
    /// shape is read back out of the audio here. Same series, nothing new in the
    /// schema, and it costs one pass over a file that is at most a minute long.
    ///
    /// Reads the decoded samples rather than guessing from the file size:
    /// `AVAssetReader` hands over raw PCM, and the peak of each slice is what a
    /// waveform is. Off the main actor — a minute of 44.1kHz mono is 2.6 million
    /// samples, and folding those on the main thread would drop frames in the
    /// thread it is scrolling in.
    static func levels(from data: Data, bars: Int = 48) async -> [CGFloat] {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("written-wave-\(UUID().uuidString).m4a")
        guard (try? data.write(to: scratch)) != nil else { return [] }
        defer { try? FileManager.default.removeItem(at: scratch) }

        let asset = AVURLAsset(url: scratch)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset)
        else { return [] }

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
        ])
        reader.add(output)
        guard reader.startReading() else { return [] }

        var peaks: [CGFloat] = []
        while let buffer = output.copyNextSampleBuffer(),
              let block = CMSampleBufferGetDataBuffer(buffer) {
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(
                block, atOffset: 0, lengthAtOffsetOut: nil,
                totalLengthOut: &length, dataPointerOut: &pointer
            ) == noErr, let pointer else { continue }

            pointer.withMemoryRebound(to: Int16.self, capacity: length / 2) { samples in
                // One peak per 1024 frames rather than per sample: the bars are
                // an outline, and keeping every sample would be the file again.
                var index = 0
                while index < length / 2 {
                    let end = min(index + 1024, length / 2)
                    var peak: Int16 = 0
                    for i in index..<end { peak = max(peak, abs(samples[i])) }
                    peaks.append(CGFloat(peak) / CGFloat(Int16.max))
                    index = end
                }
            }
        }
        guard !peaks.isEmpty else { return [] }
        return Waveform.fit(peaks, into: bars, live: false)
    }
}
