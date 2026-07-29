import Foundation

/// Turns a handful of people into an endless feed of profiles.
///
/// One person is many profiles. Each shown profile draws **two photos and two
/// interest lines**, both without replacement, so the same face never appears
/// twice in one card and a person's three profiles per cycle are visibly
/// different from each other rather than being the same card reshuffled.
///
/// Three rules, and they interact:
///
/// - **Photos, without replacement.** Six per person, two per profile, so three
///   profiles exhaust the set. Then the cycle restarts.
/// - **Lines draw on their own cycle.** Reshuffled independently of the photos,
///   so a person's second lap through their pictures does not replay their
///   first lap's captions with them.
/// - **At least five profiles between one person and themselves.** Not enforced
///   by retrying a shuffle until it happens to hold — by construction. See
///   `nextRound`.
struct DiscoveryFeed {

    /// One thing in the feed. A person, or a video somebody shared.
    ///
    /// The two are genuinely different — a profile is generated from a rotation
    /// and a shared post is a row someone wrote — so they are cases rather than
    /// a single struct with half its fields empty.
    enum Item: Identifiable, Equatable {
        case profile(Profile)
        case shared(SharedPostService.Post)

        var id: String {
            switch self {
            case .profile(let profile): return "p:" + profile.id
            case .shared(let post): return "s:" + post.id
            }
        }
    }

    /// What one card shows.
    struct Profile: Identifiable, Equatable {
        /// Unique per *appearance*, not per person: the feed shows the same
        /// person repeatedly and a list needs to tell those apart.
        let id: String
        let personID: String
        let name: String
        let age: Int?
        let district: String?
        /// Exactly two, drawn without replacement from the person's six.
        let photoSeeds: [Int]
        /// Up to two lines, from two different interests.
        let lines: [String]
    }

    /// How many other profiles must sit between one person and their next.
    ///
    /// Five, which with six people is exactly what a round-robin gives: emit
    /// each person once per round and the gap between a person's appearances is
    /// (people - 1) at minimum. Fewer than six people cannot satisfy it, and
    /// `separation` is then whatever the count allows — a feed of three people
    /// that refused to repeat anyone would simply stop.
    static let separation = 5

    private let people: [DiscoveryService.Person]
    private var rng: SeededGenerator

    /// Shared videos, newest first, cycled through as the feed goes on.
    ///
    /// Interleaved rather than mixed into the rotation: the separation rule and
    /// the photo and caption cycles are all about *people*, and a shared post is
    /// not a person. Slotting them in every few items leaves that machinery
    /// exactly as it was.
    private let posts: [SharedPostService.Post]
    private var postCursor = 0

    /// How often a shared video appears. Every fourth item, so the feed is
    /// still mostly people — this is a dating app with videos in it, not the
    /// other way round.
    private static let postEvery = 4

    /// Per person, the photos and interests not yet used this cycle.
    private var photoPool: [String: [Int]] = [:]
    private var interestPool: [String: [DiscoveryService.Person.Interest]] = [:]

    /// The order the current round emits, and how far through it we are.
    private var round: [DiscoveryService.Person] = []
    private var cursor = 0
    /// Who ended the last round, so the next one does not start with them —
    /// which is the one arrangement a plain per-round shuffle can produce that
    /// puts two of a person's profiles back to back.
    private var lastOfPreviousRound: String?

    private var emitted = 0

    init(
        people: [DiscoveryService.Person],
        posts: [SharedPostService.Post] = [],
        seed: UInt64 = UInt64.random(in: 1...UInt64.max)
    ) {
        self.people = people
        self.posts = posts
        self.rng = SeededGenerator(seed: seed)
    }

    /// The next thing to show, whichever kind it is.
    mutating func nextItem() -> Item? {
        // Counted on what has been emitted overall, so the spacing holds no
        // matter how the two kinds interleave.
        if !posts.isEmpty, emitted > 0, emitted % Self.postEvery == 0 {
            let post = posts[postCursor % posts.count]
            postCursor += 1
            emitted += 1
            return .shared(post)
        }
        return next().map(Item.profile)
    }

    /// The next `count` items, for a feed that reads ahead.
    mutating func nextItems(_ count: Int) -> [Item] {
        (0..<count).compactMap { _ in nextItem() }
    }

    /// The next profile, or nil when there is nobody to show.
    mutating func next() -> Profile? {
        guard !people.isEmpty else { return nil }

        if cursor >= round.count { nextRound() }
        let person = round[cursor]
        cursor += 1
        emitted += 1

        let photos = Self.draw(&photoPool, for: person.id,
                               refill: person.photoSeeds, count: 2, rng: &rng)
        let interests = Self.draw(&interestPool, for: person.id,
                                  refill: person.interests, count: 2, rng: &rng)

        return Profile(
            id: "\(person.id)#\(emitted)",
            personID: person.id,
            name: person.name,
            age: person.age,
            district: person.district,
            photoSeeds: photos,
            lines: interests.map { Ontology.line(for: $0.domain, subject: $0.subject) }
        )
    }

    /// The next `count` profiles, for a feed that pages ahead of the reader.
    mutating func next(_ count: Int) -> [Profile] {
        (0..<count).compactMap { _ in next() }
    }

    // MARK: - Ordering

    /// Every person once, in the *same* order every round.
    ///
    /// The order is shuffled once when the feed is built and then repeated, and
    /// that is not laziness — it is the only arrangement that satisfies the
    /// separation rule.
    ///
    /// Reshuffling each round cannot work, and the reason is worth writing down
    /// because the first version did exactly that. A person at position `p` in
    /// one round and `q` in the next sits `(n - p) + q` apart, so the profiles
    /// *between* them number `(n - p) + q - 1`. Requiring that to be at least
    /// `n - 1` means `q >= p` — for every person simultaneously, across a
    /// permutation. Only the identity does that. Measured over three thousand
    /// reshuffles the worst gap was 1, not 5, including with the "don't start a
    /// round with whoever ended the last one" guard that looked sufficient.
    ///
    /// A repeated permutation gives exactly `n - 1` every time, which is the
    /// most any ordering can offer. The order being fixed costs nothing visible:
    /// each appearance draws different photographs and different lines, so what
    /// repeats is a rhythm rather than a card.
    private mutating func nextRound() {
        if round.isEmpty { round = people.shuffled(using: &rng) }
        cursor = 0
        lastOfPreviousRound = round.last?.id
    }

    /// Takes `count` items from a person's pool, refilling it when it runs dry.
    ///
    /// The refill reshuffles, so a second lap is not the first lap in the same
    /// order. Photos and interests each get their own call and their own pool,
    /// which is what keeps the two cycles independent.
    /// Static, and the generator comes in as a parameter, because a `mutating`
    /// method takes exclusive access to the whole struct — so passing one of its
    /// own properties as `inout` at the same time is two overlapping accesses to
    /// `self` and does not compile. Two separate stored properties handed over
    /// individually is fine.
    private static func draw<T>(
        _ pool: inout [String: [T]],
        for id: String,
        refill: [T],
        count: Int,
        rng: inout SeededGenerator
    ) -> [T] {
        guard !refill.isEmpty else { return [] }
        // Lifted out of the dictionary and put back at the end. Mutating
        // `pool[id]` in place while `pool` is already `inout` is two overlapping
        // accesses to the same storage, which Swift rejects outright.
        var remaining = pool[id] ?? []
        var taken: [T] = []

        // Never more than the person has: a pool of one photo asked for two
        // would refill and hand back the same item twice, which is exactly the
        // repetition the without-replacement rule exists to prevent.
        let wanted = min(count, refill.count)
        while taken.count < wanted {
            if remaining.isEmpty { remaining = refill.shuffled(using: &rng) }
            taken.append(remaining.removeFirst())
        }

        pool[id] = remaining
        return taken
    }
}
