import Foundation
import EventKit
import MediaPlayer

/// Serialising what a device framework returned, since there is no body to keep.
///
/// **Five sources have no response at all.** `EKEventStore`, `HKHealthStore`,
/// `MPMediaQuery` and `CLLocationManager` hand back object graphs, so the
/// nearest thing to "the raw answer" is every property the framework exposes on
/// each object — not the subset the distiller happens to read. That difference
/// is the whole point of the archive: **the field no distiller reads today is
/// exactly the field a re-projection will want.**
///
/// The serialisers live here rather than in each distiller so that the call
/// sites stay one line and the *decisions* about what a dump contains sit in
/// one readable place. What each distiller keeps is its own business; what may
/// be archived is a property of the source.
///
/// ## Two refusals, and they are not symmetrical with the HTTP sources
///
/// For an HTTP source the archive stores the answer to the request that was
/// already made, so Outlook's `$select` — twelve fields, never `body`,
/// `attendees`, `attachments` or `webLink` — holds without anyone restating it.
/// A framework query has no such shape: **reading more properties is itself the
/// widening**, so the refusals have to be written down.
///
/// - **Attendees and organiser identities are not archived.** They are other
///   people's names and email addresses, and those people never agreed to
///   anything. This project already refuses to upload an address book for that
///   reason — `importContacts` takes names only, on a documented refusal — and
///   a calendar dump is the same data by another route. The *count* is kept,
///   because "a meeting with eleven people" is a fact about the owner while
///   "a meeting with Becky" is a fact about Becky.
/// - **`health/biological_sex` never reaches a file.**
///   `RawArchive.captureObjects` applies `SyncService.isLocalOnlyType` before
///   serialising, so the refusal holds at the disk rather than at the wire —
///   filtering on upload would still leave it in the Settings export.
enum RawArchiveSerialiser {

    // MARK: - The envelope, built and encoded before it crosses to the actor

    /// Wrap a framework dump and encode it, on the caller's side.
    ///
    /// **Encoded here because `[String: Any]` is not `Sendable`** and handing
    /// one to an actor is a data race the compiler is right to refuse. It also
    /// keeps the framework objects where they already are: an `EKEvent` must
    /// not escape the thread that read it.
    ///
    /// Returns nil when the source/type is refused outright, so a caller cannot
    /// accidentally archive something `SyncService` withholds — the refusal is
    /// applied **before** anything reaches a file, since filtering at upload
    /// would still leave it in the Settings export.
    static func envelope(
        source: String, kind: String, objects: [[String: Any]]
    ) -> Data? {
        guard !SyncService.isLocalOnlyType(source: source, dataType: kind) else {
            return nil
        }
        let envelope: [String: Any] = [
            "schema": "written-raw-capture-v1",
            "kind": "framework_objects",
            "source": source,
            "endpoint": kind,
            "captured_at": ISO8601DateFormatter().string(from: Date()),
            "objects": objects,
            "object_count": objects.count
        ]
        guard JSONSerialization.isValidJSONObject(envelope) else { return nil }
        return try? JSONSerialization.data(
            withJSONObject: envelope, options: [.sortedKeys]
        )
    }

    // MARK: - EventKit

    /// One calendar event, less the people in it.
    ///
    /// `notes` **is** kept: it is the owner's own text about their own entry,
    /// the same class of thing as the title, which already syncs and which
    /// `PrivacyInfo.xcprivacy` already declares. A booking confirmation pasted
    /// into a note is often the only place a venue is named.
    static func event(_ event: EKEvent) -> [String: Any] {
        var dictionary: [String: Any] = [
            "event_identifier": event.eventIdentifier ?? "",
            "title": event.title ?? "",
            "is_all_day": event.isAllDay,
            "status": event.status.rawValue,
            "availability": event.availability.rawValue,
            "calendar_title": event.calendar?.title ?? "",
            "calendar_type": event.calendar?.type.rawValue ?? -1,
            "calendar_is_subscribed": event.calendar?.isSubscribed ?? false,
            "calendar_source_title": event.calendar?.source?.title ?? "",
            "calendar_source_type": event.calendar?.source?.sourceType.rawValue ?? -1,
            "has_recurrence_rules": event.hasRecurrenceRules,
            "has_alarms": event.hasAlarms,
            "has_attendees": event.hasAttendees,
            // The count without the identities: a fact about the owner's day
            // rather than about anybody else's.
            "attendee_count": event.attendees?.count ?? 0,
            "is_detached": event.isDetached,
            "creation_date": iso(event.creationDate),
            "last_modified": iso(event.lastModifiedDate),
            "start": iso(event.startDate),
            "end": iso(event.endDate),
            "time_zone": event.timeZone?.identifier ?? "",
            "location": event.location ?? "",
            "notes": event.notes ?? "",
            "url": event.url?.absoluteString ?? "",
            "birthday_contact_identifier_present":
                event.birthdayContactIdentifier != nil
        ]
        if let rules = event.recurrenceRules, !rules.isEmpty {
            dictionary["recurrence_rules"] = rules.map { rule in
                [
                    "frequency": rule.frequency.rawValue,
                    "interval": rule.interval,
                    "end_date": iso(rule.recurrenceEnd?.endDate),
                    "occurrence_count": rule.recurrenceEnd?.occurrenceCount ?? 0
                ] as [String: Any]
            }
        }
        // **The organiser is a person and is refused; whether one exists is
        // not.** `booked=1` is derived from the organiser being present, so
        // dropping the fact entirely would make the ticketing marker
        // unreproducible from the archive.
        dictionary["has_organizer"] = event.organizer != nil
        return dictionary
    }

    // MARK: - MediaPlayer

    /// One library item — song, podcast episode or music video.
    ///
    /// Every property `MPMediaItem` publishes that is not artwork. Artwork is
    /// excluded because it is megabytes of image per row and says nothing a
    /// re-projection could use; its *presence* is recorded instead.
    static func mediaItem(_ item: MPMediaItem) -> [String: Any] {
        [
            "persistent_id": String(item.persistentID),
            "media_type": item.mediaType.rawValue,
            "title": item.title ?? "",
            "album_title": item.albumTitle ?? "",
            "album_artist": item.albumArtist ?? "",
            "artist": item.artist ?? "",
            "composer": item.composer ?? "",
            "genre": item.genre ?? "",
            "podcast_title": item.podcastTitle ?? "",
            "release_date": iso(item.releaseDate),
            "playback_duration": item.playbackDuration,
            "play_count": item.playCount,
            "skip_count": item.skipCount,
            "rating": item.rating,
            "last_played_date": iso(item.lastPlayedDate),
            "date_added": iso(item.dateAdded),
            "bookmark_time": item.bookmarkTime,
            "is_explicit": item.isExplicitItem,
            "is_cloud_item": item.isCloudItem,
            "has_protected_asset": item.hasProtectedAsset,
            "disc_number": item.discNumber,
            "disc_count": item.discCount,
            "album_track_number": item.albumTrackNumber,
            "album_track_count": item.albumTrackCount,
            "beats_per_minute": item.beatsPerMinute,
            "comments": item.comments ?? "",
            "is_compilation": item.isCompilation,
            "user_grouping": item.userGrouping ?? "",
            "has_artwork": item.artwork != nil
        ]
    }

    private static func iso(_ date: Date?) -> String {
        guard let date else { return "" }
        return ISO8601DateFormatter().string(from: date)
    }
}
