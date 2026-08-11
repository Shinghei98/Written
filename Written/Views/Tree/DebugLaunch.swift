#if DEBUG
import SwiftUI

/// Launch-argument overrides for looking at the illustration from the command
/// line. Debug-only, and deliberately all in one file so it can be deleted in
/// one move.
///
/// Iterating on the plant used to mean editing `TreeSkeleton.make` to force a
/// stage, building, screenshotting, editing it back and building again — two
/// full builds per look. `simctl` can't tap the `↻` stepper, so there was no
/// other way in. Arguments beginning with `-` land in `UserDefaults`' argument
/// domain, which gives us one:
///
/// ```
/// xcrun simctl launch <device> com.written.datingapp -stage 3
/// xcrun simctl launch <device> com.written.datingapp -stages all
/// ```
enum DebugLaunch {

    /// Launch arguments describe the *launch*, not every appearance of a view.
    ///
    /// Views get rebuilt: signing out and back in makes a fresh `HomeView`, and
    /// its `onAppear` would read `-screen dashboard` a second time and slide
    /// away to the dashboard again — the garden flashing past on every sign-in.
    /// Each flag fires once per process.
    @MainActor private static var fired: Set<String> = []

    @MainActor
    static func firesOnce(_ flag: String) -> Bool {
        guard !fired.contains(flag) else { return false }
        fired.insert(flag)
        return true
    }
    /// `-stage N` → the screen as though the first N modalities were connected.
    /// 0 is the bare sprout, 4 the full plant.
    static var forcedStage: Int? {
        UserDefaults.standard.string(forKey: "stage").flatMap(Int.init)
    }

    /// `-stages all` → every illustrated stage at once, so comparing against
    /// the reference art costs one launch and one screenshot instead of five.
    static var showsAllStages: Bool {
        UserDefaults.standard.string(forKey: "stages") == "all"
    }

    /// `-tab explore` / `-tab wish` / `-tab chat` / `-tab dashboard` → open the
    /// shell on that tab. The bar can only be reached by tapping, and `simctl`
    /// cannot tap, so without this every tab but Distill is unscreenshottable.
    static var forcedTab: String? {
        UserDefaults.standard.string(forKey: "tab")
    }

    /// `-onboarded 1` → draw the shell as though onboarding had finished.
    ///
    /// **The regular-use half of the app is otherwise unreachable without a
    /// real account**, and several things exist only there: the tab bar, the
    /// dashboard's sign-out and delete rows, and now the settings cog. Without
    /// this they can be checked on a device and nowhere else, which is the same
    /// hole `-route` was added to close for the onboarding pages.
    ///
    /// Note it does not fabricate a session — nothing that needs the server
    /// will work. It answers the layout question only.
    static var forcesOnboarded: Bool {
        UserDefaults.standard.string(forKey: "onboarded") == "1"
    }

    /// `-settings 1` → open the settings page over Memories on launch.
    ///
    /// Same reason as `-tab` and `-chat`: the cog can only be reached by
    /// tapping and `simctl` cannot tap, so the page and its five sections are
    /// otherwise unscreenshottable. Pair it with `-onboarded 1`, without which
    /// the cog is not drawn at all.
    /// **Any value opens it**, not only `1`. `-settings bottom` also has to
    /// present the page before it can scroll it, and testing `== "1"` here
    /// meant the scrolling variant opened nothing at all.
    static var opensSettings: Bool {
        UserDefaults.standard.string(forKey: "settings") != nil
    }

    /// `-settings bottom` → open Settings scrolled to Sign out and Delete
    /// account, which sit below the fold on every phone.
    static var scrollsSettingsToBottom: Bool {
        UserDefaults.standard.string(forKey: "settings") == "bottom"
    }

    /// `-settings gender|radius|ageRange|blockList|wordFilter` → open Settings
    /// with that sub-page already pushed. They are reachable only by tapping a
    /// row, which `simctl` cannot do.
    static var settingsPage: String? {
        let value = UserDefaults.standard.string(forKey: "settings")
        return ["gender", "radius", "ageRange", "blockList", "wordFilter"].contains(value ?? "")
            ? value : nil
    }

    /// `-words sample` → seed a few filtered words, so the tag layout can be
    /// looked at with strings of genuinely different lengths. Wrapping is the
    /// whole question and one-word test data never answers it.
    static var seedsFilteredWords: Bool {
        ["sample", "add"].contains(UserDefaults.standard.string(forKey: "words") ?? "")
    }

    /// `-words add` → raise the Add a word sheet, which is otherwise a tap away.
    static var opensAddWord: Bool {
        UserDefaults.standard.string(forKey: "words") == "add"
    }

    /// `-screen dashboard` → plays the move to the dashboard shortly after
    /// launch. It is otherwise only reachable by tapping "View Dashboard", and
    /// `simctl` cannot tap; screenshotting during the delay and after it covers
    /// both the transition and the screen it lands on.
    /// `-memories-tutorial 1`. The four-page Memories tutorial otherwise needs
    /// onboarding, a distillation and a pull-up gesture, none of which `simctl`
    /// can produce.
    static var opensMemoriesTutorial: Bool {
        UserDefaults.standard.string(forKey: "memories-tutorial") == "1"
    }

    /// `-probe-isrc <ISRC>` → ask Apple Music's catalog for one recording's
    /// composer and print the answer.
    ///
    /// **This settles a premise rather than showing a screen**, which is why it
    /// is here rather than in a test: `filter[isrc]` needs the developer and
    /// music-user tokens, which only exist inside a signed, installed build on
    /// a device with an Apple Music account. Nothing in the composer path is
    /// worth trusting until this prints a name.
    ///
    /// ```
    /// xcrun simctl launch <device> com.written.datingapp -probe-isrc DEN962300581
    /// ```
    ///
    /// If it prints no composer, the fallback is MusicBrainz — measured at one
    /// request per second against roughly a hundred per request here, and
    /// returning `composer` for classical but several `writer` credits for pop.
    static var probeISRC: String? {
        UserDefaults.standard.string(forKey: "probe-isrc")
    }

    /// `-tutorial badge` → open the coach mark that lights the connected badge,
    /// without connecting anything.
    ///
    /// **For measuring the hole rather than for looking at the mark.** Reaching
    /// that step honestly means a connection, a distillation and a plant that
    /// has finished growing, and `simctl` can send none of it — so the one
    /// invariant worth checking automatically, that the hole is exactly where
    /// the badge is, was checkable only by hand. `tools/badge_hole_check.py`
    /// reads the screenshot this produces.
    static var tutorialTarget: String? {
        UserDefaults.standard.string(forKey: "tutorial")
    }

    static var opensDashboard: Bool {
        ["dashboard", "profiles"].contains(UserDefaults.standard.string(forKey: "screen") ?? "")
    }

    /// `-screen profiles` → carries on past the dashboard to the profile
    /// previews, which are otherwise two taps in.
    static var opensProfiles: Bool {
        UserDefaults.standard.string(forKey: "screen") == "profiles"
    }

    /// How long the garden holds before it leaves, under `-screen dashboard`.
    static let dashboardDelay: Double = 1.2

    /// `-distill 1` → runs the preview distillation shortly after launch, so the
    /// choreography that only happens while one is running — the banner, the
    /// watering can, the badges' progress rings — can be screenshotted. It is
    /// the `↻` stepper's work, and `simctl` cannot tap it.
    static var playsDistillation: Bool {
        UserDefaults.standard.string(forKey: "distill") == "1"
    }

    /// Long enough for the plant to have settled first.
    static let distillDelay: Double = 2.5

    /// `-connect health` → run a *real* distillation of that source shortly
    /// after launch, permission sheet and all. `-distill` fakes one; this is the
    /// genuine path, for sources whose sheet can't be tapped from `simctl`.
    static var connectSource: String? {
        UserDefaults.standard.string(forKey: "connect")
    }

    /// `-push ask` → ask for notification permission shortly after launch, and
    /// print the device token when APNs answers.
    ///
    /// **Setting push up requires a token, and a token requires being liked.**
    /// `PushService.askIfNeeded` fires on the first admirer, which is the right
    /// moment for a user — somebody has just been liked, so being told sooner
    /// obviously pays — and an absurd prerequisite for the person wiring APNs,
    /// who has to arrange a like against an account that cannot yet receive
    /// anything.
    ///
    /// The print matters as much as the ask. A token is 64 characters of hex
    /// with no structure to check it against, and Apple's Push Notifications
    /// Console wants it pasted exactly — transcribing one off a phone screen is
    /// how an hour goes to `BadDeviceToken`.
    static var asksForPush: Bool {
        UserDefaults.standard.string(forKey: "push") == "ask"
    }

    /// Long enough for the shell to have settled, so the alert is not competing
    /// with a screen still being built. Notification permission draws its own
    /// alert rather than hosting a remote view, so it is nothing like as fragile
    /// as HealthKit's — but the standing rule in this app is still that two
    /// permission prompts must never be near each other.
    static let pushDelay: Double = 1.5

    /// `-survey media` → dump every field the media library exposes for
    /// podcasts and audiobooks to `Documents/media-survey.json`, for pulling off
    /// a connected device with `devicectl`. See `MediaFieldSurvey`; delete both
    /// once the scope question is settled.
    static var surveyTarget: String? {
        UserDefaults.standard.string(forKey: "survey")
    }

    /// `-edit artist` / `-edit channel` / `-edit sport` → open the dashboard with
    /// one entry of that kind already wobbling. `simctl` can send no long press,
    /// so this is the only way to screenshot the editing state.
    static var editTarget: String? {
        UserDefaults.standard.string(forKey: "edit")
    }

    /// `-bio education` / `-bio occupation` / `-bio name` … → open that
    /// biographics editor shortly after the dashboard appears.
    ///
    /// The rows are reachable only by tapping one, and `simctl` cannot tap — the
    /// same argument `-edit` and `-pick` make. Without this the sheets can only
    /// be seen on a device, which means a title or a subtitle can be wrong for
    /// as long as nobody happens to open one.
    static var biographicsTarget: String? {
        UserDefaults.standard.string(forKey: "bio")
    }

    /// `-pick music` / `-pick media` / `-pick lifestyle` → open that modality's
    /// source picker shortly after launch. The sheet is only reachable through
    /// a "Connect …" button, and `simctl` can send no tap.
    static var pickTarget: Modality? {
        switch UserDefaults.standard.string(forKey: "pick") {
        case "music": return .music
        case "media": return .media
        case "lifestyle": return .lifestyle
        default: return nil
        }
    }

    /// `-route name` / `-route communication` / `-route photos` / `-route home`
    /// → open straight on that screen, standing in for a session that was
    /// force-quit there.
    ///
    /// The onboarding pages are otherwise only reachable by signing in with a
    /// real Apple account, which the simulator cannot do — so without this the
    /// "resume where you quit" routing could only ever be checked on a device.
    static var forcedRoute: String? {
        UserDefaults.standard.string(forKey: "route")
    }

    /// `-loading video` / `-loading photo` → hold the photo page in its loading
    /// state. Reaching it for real means choosing something in `PhotosPicker`,
    /// which `simctl` cannot tap, and the state is transient besides.
    static var pickLoading: String? {
        UserDefaults.standard.string(forKey: "loading")
    }

    /// `-chat sample` → fill the Chat tab with fabricated admirers and threads.
    /// `-chat admirers` → the same, then open the admirers list.
    /// `-chat thread` → the same, then open the newest conversation.
    /// `-chat swiped` → the same, with the first row swiped open. The unmatch
    /// and report buttons are behind a drag, and `simctl` sends taps but not
    /// drags — so without this the one thing worth looking at is the one thing
    /// a screenshot cannot reach. `-chat report` opens the report sheet, which
    /// is two taps beyond that drag.
    ///
    /// The real ones need two accounts, an applied migration and somebody on the
    /// other end. The *layout* needs none of that, and two things on this screen
    /// are wrong-by-one in ways only a look catches: the banner draws five faces
    /// and then a "+", and `RelativeTime` switches units three times. Seven
    /// admirers spread across an hour, a day, a month and beyond exercises every
    /// branch of both in one screenshot.
    ///
    /// The two pushed pages are behind the same flag rather than a second one
    /// because neither is reachable without the sample data, and both are behind
    /// a tap `simctl` cannot send — the same argument `-screen dashboard` makes.
    static var chatTarget: String? {
        UserDefaults.standard.string(forKey: "chat")
    }

    static var showsSampleChat: Bool {
        // `-memo` implies it: the voice sheet is inside a thread, and a thread
        // needs a conversation to be inside.
        memoState != nil
            || ["sample", "admirers", "thread", "typing", "swiped", "report", "icebreaker", "profile"]
                .contains(chatTarget ?? "")
    }

    /// Long enough for the list underneath to have drawn, so a screenshot taken
    /// before it catches the page it was pushed from.
    static let chatPushDelay: Double = 1.0

    /// `-chat typing` → open the newest thread with the other side mid-sentence.
    ///
    /// The real thing needs presence, which needs a live channel this app does
    /// not have — see `ConversationView.isPartnerTyping`. The *animation* needs
    /// none of that, and it is the part that is easy to get subtly wrong: three
    /// dots rising together read as a spinner, and only one rising after another
    /// reads as somebody typing.
    static var showsTypingIndicator: Bool {
        chatTarget == "typing"
    }

    /// `-reveal 0.5` → hold the garden partway through its onboarding pull-up.
    ///
    /// The gesture is a drag and `simctl` can send none, so the one frame that
    /// matters here — garden lifted, dashboard showing underneath — is otherwise
    /// only reachable on a device with a finger on it. It is also the frame that
    /// was wrong: the reveal showed bare parchment all the way up, because the
    /// dashboard was gated on the tab having already changed.
    ///
    /// A fraction of the full travel, not a point value, so the same number
    /// means the same thing on an SE and a Pro Max.
    static var revealFraction: Double? {
        UserDefaults.standard.string(forKey: "reveal").flatMap(Double.init)
    }

    /// `-birthday confirm` / `-birthday error` → open the birthday page in one of
    /// the two states that need a tap to reach.
    ///
    /// Same reasoning as `-reveal`: `simctl` can send no taps, so the confirm
    /// card and the red-bordered refusal are otherwise only checkable on a device
    /// with a finger on it — and they are the two states most likely to be
    /// wrong, being the ones drawn over a keyboard.
    ///
    /// `confirm` seeds a date, which is the point: the card reads it back, so a
    /// fixed one makes "You're 27, born December 19, 1998" reproducible rather
    /// than a number that changes with the machine's clock.
    static var birthdayState: String? {
        UserDefaults.standard.string(forKey: "birthday")
    }

    /// `-memo review` / `-memo empty` / `-memo holding` → open a chat thread with
    /// the voice-memo sheet already up, in that state.
    ///
    /// The sheet is reached by *holding* the microphone, and `simctl` can send
    /// neither a hold nor a tap — so without this its proportions can only be
    /// judged on a device, by eye, which is how they came out wrong twice. With
    /// it the pill, the send button and the retry glyph can be measured against
    /// the reference the same way everything else in this project is.
    static var memoState: String? {
        UserDefaults.standard.string(forKey: "memo")
    }

    /// `-solo 1` → build only the tab you are on, and none of the other four.
    ///
    /// For `WrittenUITests`, and it is not a convenience. `AppShell` mounts all
    /// five tabs and hides the four you are not on with `opacity(0)`,
    /// `allowsHitTesting(false)` and `accessibilityHidden(true)`. **XCUITest
    /// honours none of the three**: `app.staticTexts` walks straight through
    /// them, so a dump of the garden also contains Explore's "Nobody to see yet"
    /// and Wish's note, stacked at the same coordinates. Every pair of those is
    /// an overlap that is not real — 543 of them on the first run, burying the
    /// findings that were.
    ///
    /// Auditing one tab at a time is also the honest question: "does anything on
    /// the Chat page overlap" is about the Chat page. Nothing is lost, because
    /// each tab gets its own run.
    static var auditsOneTabAtATime: Bool {
        UserDefaults.standard.string(forKey: "solo") == "1"
    }

    /// `-scroll media` → open the dashboard already scrolled to that card.
    /// Cards below the fold are otherwise unscreenshottable: `simctl` can send
    /// no swipe, and the alternative — reordering the page for one look — is
    /// the source-patching this harness exists to avoid.
    static var scrollTarget: String? {
        UserDefaults.standard.string(forKey: "scroll")
    }
}

/// Every illustrated stage on one screen, two to a row.
///
/// Not a single row: at a fifth of the width each panel is too small to judge a
/// petiole angle on, which is the whole reason for looking.
struct StageSheet: View {
    private let stages = SeedlingStage.allCases

    var body: some View {
        GeometryReader { geometry in
            // Half the width, and the height that width implies — sized
            // explicitly because `SeedlingView` is aspect-fit, and a
            // `maxWidth: .infinity` frame proposes it an infinite width, which
            // collapses the whole sheet to nothing.
            let width = geometry.size.width / 2
            let height = min(width / SeedlingView.aspectRatio,
                             (geometry.size.height - 40) / CGFloat((stages.count + 1) / 2))

            // Rows derived rather than fixed at two: the sheet was hardcoded to
            // a 2x2 for four stages, so adding a fifth would have dropped it
            // silently — the one failure this harness cannot afford, since its
            // whole job is showing what a change did.
            let rows = (stages.count + 1) / 2
            VStack(spacing: 14) {
                ForEach(0..<rows, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(0..<2, id: \.self) { column in
                            let index = row * 2 + column
                            if index < stages.count {
                                panel(stages[index])
                                    .frame(width: width, height: height)
                            } else {
                                Color.clear.frame(width: width, height: height)
                            }
                        }
                    }
                }
            }
            // Centred in whatever is left over.
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(GardenPalette.parchment.ignoresSafeArea())
    }

    private func panel(_ stage: SeedlingStage) -> some View {
        // Bottom-aligned, matching how the plant sits on the real screen — the
        // stem's foot is the fixed point, so a taller stage reads as taller.
        ZStack(alignment: .bottomLeading) {
            SeedlingView(stage: stage)

            Text("stage \(stage.rawValue)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(GardenPalette.ink.opacity(0.45))
        }
        // Every panel plays its entrance on appear, so a screenshot taken
        // before ~5s catches the plant mid-growth.
    }
}

#Preview("All stages") {
    StageSheet()
}
#endif
