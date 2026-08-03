import SwiftUI

/// The sheet that covers the composer while a voice memo is being made.
///
/// **Four states, not three** — the count is the correction. Holding the
/// composer's microphone gives a growing waveform and a running clock; letting
/// go gives the take, with play, retry and send. Retry empties the track and
/// leaves a red disc alone in the row. Tapping *that* records again, and a
/// tapped take is stopped by a black square rather than by lifting a finger —
/// so the two recording states look different and are driven differently.
///
/// Gold throughout rather than the reference's yellow — `GardenPalette.badgeGold`
/// is already the app's one accent, on the plant's badges and on your own chat
/// bubbles, and a second yellow beside it would read as a different thing.
struct VoiceMemoBanner: View {

    @ObservedObject var memo: VoiceMemo

    /// Whether the take in progress was started by holding the composer's
    /// microphone, as opposed to by tapping the red disc after a retry.
    ///
    /// **The two are different controls with different rules**, which is the
    /// thing this banner got wrong first time round. A held take ends when the
    /// finger lifts and shows no buttons at all — there is no free hand to press
    /// one with. A tapped take runs until the square is tapped, and offers the
    /// send arrow the whole time.
    var isHeld: Bool

    var onStartTapped: () -> Void
    var onStopTapped: () -> Void
    var onRetry: () -> Void
    var onSend: () -> Void

    /// The sheet's own width, which every size below is a fraction of.
    ///
    /// **Ratios, not points.** Measured off the reference — a 3x capture of a
    /// 440pt screen — and kept as fractions so the sheet has the same
    /// proportions on an SE as on a Pro Max. Hardcoding the points would be
    /// correct on exactly one phone, and the first attempt at this was built by
    /// eye and came out half again too tall.
    @State private var width: CGFloat = 393

    /// 1224 of 1320 across, 156 tall: the pill is nearly the full width and
    /// about an eighth of it high.
    private var pillHeight: CGFloat { width * 0.118 }
    private var sideInset: CGFloat { width * 0.036 }
    /// 120 of 1320. The first version was 60pt on a 393pt sheet — 0.153, which
    /// is two thirds too big.
    private var sendSize: CGFloat { width * 0.091 }
    private var retryGlyph: CGFloat { width * 0.055 }
    /// 97px between the pill's foot and the top of the controls.
    private var controlGap: CGFloat { width * 0.073 }

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(GardenPalette.muted.opacity(0.35))
                .frame(width: width * 0.083, height: 5)
                .padding(.top, 8)

            // Measured off the reference: a 12.3pt cap height at 440pt wide,
            // which is a 17pt bold — mine was rendering nearer 14pt of cap and
            // reading as a headline rather than a label. Width-relative like
            // everything else here, so the whole sheet scales together.
            Text("Voice Memo")
                .font(.system(size: width * 0.039, weight: .bold))
                .foregroundStyle(GardenPalette.ink)
                .padding(.top, 12)

            track
                .padding(.horizontal, sideInset)
                .padding(.top, controlGap * 0.6)

            controls
                .padding(.horizontal, sideInset)
                .padding(.top, controlGap)
                .padding(.bottom, controlGap * 0.55)
        }
        .frame(maxWidth: .infinity)
        .background(GardenPalette.card)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: .black.opacity(0.14), radius: 18, y: -4)
        // Measured in a `background`, so reading the width costs no layout.
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { width = proxy.size.width }
                    .onChange(of: proxy.size.width) { width = $0 }
            }
        )
    }

    // MARK: - The pill

    /// Gold once there is something in it, grey when there is not — which is
    /// the whole difference between the reference's second and third states.
    private var track: some View {
        HStack(spacing: pillHeight * 0.2) {
            if memo.recording != nil {
                Button(action: memo.togglePlayback) {
                    Image(systemName: memo.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: pillHeight * 0.42))
                        .foregroundStyle(GardenPalette.ink)
                        .frame(width: pillHeight * 0.5)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(memo.isPlaying ? "Pause" : "Play")
            }

            // Just over half the pill's height, which is what leaves the bars
            // room to breathe inside it rather than filling it edge to edge.
            Waveform(levels: memo.levels, isLive: memo.isRecording)
                .frame(maxWidth: .infinity, minHeight: pillHeight * 0.54, maxHeight: pillHeight * 0.54)

            // 11.3pt digits at 440pt wide. Was 0.38 of the pill, which put it
            // a third over.
            Text(Self.clock(memo.elapsed))
                .font(.system(size: pillHeight * 0.30, weight: .semibold).monospacedDigit())
                .foregroundStyle(hasContent ? GardenPalette.ink : GardenPalette.muted)
        }
        .padding(.horizontal, pillHeight * 0.34)
        // **The pill's height is set, not accumulated.** Padding plus content
        // is how it came out half again too thick — the measurement is of the
        // whole pill, so the whole pill is what gets the number.
        .frame(height: pillHeight)
        .background(
            hasContent ? GardenPalette.badgeGold : GardenPalette.muted.opacity(0.14),
            in: RoundedRectangle(cornerRadius: pillHeight * 0.38, style: .continuous)
        )
    }

    private var hasContent: Bool { memo.isRecording || memo.recording != nil }

    // MARK: - The row beneath

    @ViewBuilder
    private var controls: some View {
        if memo.isRecording, isHeld {
            // **A held take offers nothing to press.** The finger that would
            // press it is the one holding the microphone. So the row says what
            // to do next, and the gold disc sits on the right exactly where that
            // finger already is — it is the composer's own microphone button,
            // wearing a waveform and lit up, rather than a new control.
            HStack {
                Text("Remove your hand to stop recording.")
                    .font(.system(size: width * 0.032))
                    .foregroundStyle(GardenPalette.muted)
                    .frame(maxWidth: .infinity)

                // The same size and place as the send button, because it is the
                // same corner — and the same corner as the microphone the finger
                // is still on.
                RecordingHalo(diameter: sendSize)
            }
        } else if memo.isRecording {
            // Started by the red disc, so it runs until the square is tapped —
            // and the send arrow is already there, because a tapped take can be
            // sent without stopping it first.
            centreAndSend {
                Button(action: onStopTapped) {
                    RoundedRectangle(cornerRadius: retryGlyph * 0.2, style: .continuous)
                        .fill(GardenPalette.ink)
                        .frame(width: retryGlyph, height: retryGlyph)
                        .frame(width: sendSize, height: sendSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop recording")
            }
        } else if memo.recording != nil {
            centreAndSend {
                Button(action: onRetry) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: retryGlyph, weight: .medium))
                        .foregroundStyle(GardenPalette.ink)
                        .frame(width: sendSize, height: sendSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Record again")
            }
        } else {
            // Thrown away, waiting. **Tap, not hold** — the reference is
            // explicit, and it is the right asymmetry: holding is for the
            // gesture that began at the microphone, and by the time you are
            // here your finger left the screen a while ago. Red because this is
            // the one control that starts something rather than finishing it.
            //
            // Alone in the row: no send arrow, because there is nothing yet
            // to send.
            Button(action: onStartTapped) {
                ZStack {
                    Circle().fill(.white)
                        .frame(width: sendSize * 1.12, height: sendSize * 1.12)
                        .shadow(color: .black.opacity(0.10), radius: 4)
                    Circle().fill(Color(red: 0.85, green: 0.33, blue: 0.18))
                        .frame(width: sendSize * 0.9, height: sendSize * 0.9)
                }
                .frame(width: sendSize * 1.65, height: sendSize * 1.65)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Record")
        }
    }

    /// The two-button row: one control in the middle, the send arrow on the
    /// right. Shared so the recording and review states cannot drift apart —
    /// only the middle button differs between them.
    private func centreAndSend<Middle: View>(@ViewBuilder middle: () -> Middle) -> some View {
        // **A `ZStack`, not an `HStack` with spacers.** Spacers centre the middle
        // control in whatever is left *beside* the send button, which pushed it
        // visibly left of the sheet's centre. In the reference the retry sits on
        // the sheet's exact midline — 660 of 1320 — with the send button
        // overlaid at the trailing edge, and those are two independent
        // placements rather than one row sharing its width.
        ZStack {
            middle()

            HStack {
                Spacer(minLength: 0)
                Button(action: onSend) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: sendSize * 0.5, weight: .bold))
                        .foregroundStyle(GardenPalette.ink)
                        .frame(width: sendSize, height: sendSize)
                        .background(GardenPalette.badgeGold, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Send voice message")
            }
        }
        .frame(height: sendSize * 1.65)
    }

    /// `00:03`. Minutes and seconds even under a minute, because the field must
    /// not change width as it counts — a clock that reflows is read as broken.
    static func clock(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded(.down)))
        return String(format: "%02d:%02d", whole / 60, whole % 60)
    }
}

/// The gold disc under the finger while a held take is running, breathing.
///
/// **A clock, not `withAnimation(.repeatForever())`.** The sheet around this is
/// animated — `isMemoOpen` carries a spring, the controls swap between states —
/// and an ambient transaction *replaces* an in-flight repeating animation
/// permanently, since nothing restarts it. That is exactly how the plant's
/// badges came to sit still, and the fix there was the same: derive the value
/// from the date and there is no animation to interrupt.
///
/// It ebbs rather than pulsing to a beat. Two rings a little out of step, on a
/// slow sine — the point is to look alive while nothing else on the sheet moves,
/// not to count anything out.
struct RecordingHalo: View {

    let diameter: CGFloat

    /// One breath, in seconds.
    private static let period: Double = 1.8

    var body: some View {
        TimelineView(.animation) { context in
            let turns = context.date.timeIntervalSinceReferenceDate / Self.period
            // 0...1, easing at both ends: `sin` alone spends most of its time
            // near the extremes, which reads as a throb.
            let breath = (sin(turns * 2 * .pi) + 1) / 2

            ZStack {
                ring(scale: 1.35 + 0.45 * breath, opacity: 0.34 * (1 - breath))
                ring(scale: 1.10 + 0.35 * breath, opacity: 0.42 - 0.18 * breath)

                Circle()
                    .fill(GardenPalette.badgeGold)
                    .frame(width: diameter, height: diameter)

                Image(systemName: "waveform")
                    .font(.system(size: diameter * 0.45, weight: .semibold))
                    .foregroundStyle(GardenPalette.ink)
            }
            // The frame is the *disc*, not the halo. The rings are allowed to
            // spill outside it, so a breathing glow cannot shove the row it
            // sits in about as it grows.
            .frame(width: diameter, height: diameter)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }

    private func ring(scale: Double, opacity: Double) -> some View {
        Circle()
            .fill(GardenPalette.badgeGold.opacity(opacity))
            .frame(width: diameter * scale, height: diameter * scale)
    }
}

/// The bars inside the pill.
///
/// Drawn from levels rather than from the audio file: the recorder hands over a
/// meter reading twelve times a second and that is the same series both the
/// live state and the finished one show, so a take looks the same before and
/// after the finger comes up.
struct Waveform: View {

    let levels: [CGFloat]
    /// Live recording pins the newest bar to the right and lets the oldest
    /// scroll off; a finished take is squeezed to fit so the whole thing shows.
    var isLive = false
    var tint: Color = GardenPalette.ink

    private let barWidth: CGFloat = 3
    private let spacing: CGFloat = 2

    var body: some View {
        GeometryReader { proxy in
            let capacity = max(1, Int(proxy.size.width / (barWidth + spacing)))
            let shown = Self.fit(levels, into: capacity, live: isLive)

            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(tint)
                        // A floor, so silence is a dot on the line rather than
                        // nothing at all — the reference's quiet passages read
                        // as a dotted rule, not as a gap.
                        .frame(width: barWidth,
                               height: max(barWidth, level * proxy.size.height))
                }
            }
            .frame(width: proxy.size.width,
                   height: proxy.size.height,
                   alignment: isLive ? .trailing : .leading)
        }
    }

    /// Either the last `capacity` samples, or all of them averaged down to fit.
    ///
    /// Averaging rather than sampling every nth: a minute of speech dropped to
    /// 90 bars by picking one in eight is a waveform of whatever happened to be
    /// true at those instants, which looks nothing like the recording.
    static func fit(_ levels: [CGFloat], into capacity: Int, live: Bool) -> [CGFloat] {
        guard !levels.isEmpty else { return [] }
        if levels.count <= capacity { return levels }
        if live { return Array(levels.suffix(capacity)) }

        let stride = Double(levels.count) / Double(capacity)
        return (0..<capacity).map { index in
            let start = Int(Double(index) * stride)
            let end = min(levels.count, max(start + 1, Int(Double(index + 1) * stride)))
            let slice = levels[start..<end]
            return slice.reduce(0, +) / CGFloat(slice.count)
        }
    }
}

/// A voice memo in the thread: play, waveform, length.
///
/// The same three parts as the review pill in the sheet, so what you approved
/// before sending is what appears — in bubble colours rather than always gold,
/// because a received memo is not yours and must not look like it is.
///
/// **The waveform here is drawn from the file, not from the recording session.**
/// The levels the recorder metered live only in the sender's memory and are
/// gone by the next launch; the recipient never had them at all. Rather than
/// add a column for them, the bars are derived from the audio once it is on the
/// device — the same series either way, and nothing new in the schema.
struct VoiceBubble: View {

    let message: ChatService.Message
    let isMine: Bool

    /// The waveform's width, and so the width the two labels bracket.
    private static let column: CGFloat = 148

    /// `00:04` as `0:04`.
    ///
    /// The sheet writes two-digit minutes because its clock counts up and a
    /// field that changes width as it counts reads as broken. A finished length
    /// is not counting, and the reference drops the leading zero.
    static func compact(_ body: String) -> String {
        guard !body.isEmpty else { return "0:00" }
        guard body.hasPrefix("0"), body.count > 4 else { return body }
        return String(body.dropFirst())
    }

    @State private var levels: [CGFloat] = []
    @State private var player: VoicePlayback?
    @State private var isPlaying = false

    private var fill: Color { isMine ? GardenPalette.bubbleMine : GardenPalette.bubbleTheirs }
    private var ink: Color { isMine ? GardenPalette.bubbleMineText : GardenPalette.bubbleTheirsText }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                Task { await toggle() }
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(ink)
                    .frame(width: 20)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? "Pause voice message" : "Play voice message")

            // **The two labels sit under the waveform, not beside it.**
            //
            // Measured off the reference: the duration's left edge lands on the
            // waveform's left edge and the timestamp's right edge on its right,
            // so the pair brackets the bars rather than stacking in a corner.
            // Both live in this column for that reason — the play button is
            // outside it, which is why the duration starts clear of the
            // triangle rather than under it.
            VStack(alignment: .leading, spacing: 3) {
                Waveform(levels: levels, tint: ink.opacity(0.75))
                    .frame(width: Self.column, height: 24)

                HStack(spacing: 6) {
                    // The length travels in the body, written when the memo was
                    // sent, so this reads correctly before the audio has been
                    // downloaded at all.
                    Text(Self.compact(message.body))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(ink.opacity(0.7))

                    Spacer(minLength: 6)

                    // Every other kind of message carries one. A text bubble
                    // draws it in its bottom corner and a photo overlays it on
                    // the picture — the photo's own comment says a captionless
                    // one would otherwise be "the one kind of message with no
                    // time on it". A voice memo was the third kind, and was.
                    Text(RelativeTime.clock(message.sentAt))
                        .font(.system(size: 11))
                        .foregroundStyle(ink.opacity(0.55))
                }
                .frame(width: Self.column)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .background(fill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .task { await loadWaveform() }
        .onDisappear { player?.stop(); isPlaying = false }
    }

    private func toggle() async {
        if isPlaying { player?.stop(); isPlaying = false; return }
        guard let path = message.attachmentPath,
              let data = await MediaService.shared.data(for: path)
        else { return }
        player = VoicePlayback(data: data) { isPlaying = false }
        isPlaying = player?.start() ?? false
    }

    private func loadWaveform() async {
        guard levels.isEmpty, let path = message.attachmentPath,
              let data = await MediaService.shared.data(for: path)
        else { return }
        levels = await VoicePlayback.levels(from: data)
    }
}
