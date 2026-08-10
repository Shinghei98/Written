"""Single executable source/action policy for adapters, mapping, and scoring.

The same connector action must not be accepted by ingestion and rejected only
later by the mapper.  This immutable catalog is therefore the Python source of
truth for source layout, baseline reliability, and positive action weights.
Calendar weights apply only after the fail-closed structural classifier; a
validated flight may carry its stronger per-artifact ``0.92`` override.
"""

from __future__ import annotations

from types import MappingProxyType


DEFAULT_SOURCE_QUALITY = MappingProxyType(
    {
        "apple_music": 0.90,
        "spotify": 0.90,
        "music_library": 0.75,
        "youtube": 0.80,
        "apple_calendar": 0.90,
        "google_calendar": 0.90,
        "apple_podcasts": 0.80,
        "podcast": 0.80,
        # Only sanitized, thresholded fitness_habit observations use this
        # quality. Raw HealthKit samples never enter SOURCE_ACTION_PAIRS.
        "healthkit": 0.90,
    }
)

SOURCE_LAYOUT = MappingProxyType(
    {
        "apple_music": ("music", "music"),
        "spotify": ("music", "music"),
        "music_library": ("music", "music"),
        "youtube": ("video", "video"),
        "apple_calendar": ("calendar", "calendar"),
        "google_calendar": ("calendar", "calendar"),
        "apple_podcasts": ("podcast", "podcast"),
        "podcast": ("podcast", "podcast"),
        "healthkit": ("fitness", "fitness"),
    }
)


def _weights(values: dict[str, float]) -> MappingProxyType[str, float]:
    return MappingProxyType(dict(values))


SOURCE_ACTION_WEIGHTS = MappingProxyType(
    {
        "apple_music": _weights(
            {
                "library_song": 0.48,
                "library_album": 0.55,
                "library_artist": 0.45,
                "library_playlist": 0.60,
                "playlist_item": 0.70,
                "rating": 0.88,
                "recently_added": 0.55,
                "recently_played": 0.78,
                "saved_track": 0.60,
                "saved_album": 0.55,
                "followed_artist": 0.55,
            }
        ),
        "music_library": _weights({"library_song": 0.48}),
        "spotify": _weights(
            {
                "followed_artist": 0.55,
                "recently_played": 0.78,
                "saved_album": 0.55,
                "saved_track": 0.60,
            }
        ),
        "youtube": _weights(
            {
                "subscription": 0.55,
                "video": 0.65,
                "watched": 0.72,
                "liked": 0.90,
                "liked_video": 0.90,
                "shared": 0.92,
            }
        ),
        # This baseline is reachable only after local ticket classification.
        "apple_calendar": _weights({"scheduled": 0.90}),
        "google_calendar": _weights({"scheduled": 0.90}),
        "apple_podcasts": _weights(
            {"followed": 0.70, "played": 0.75, "saved": 0.82}
        ),
        "podcast": _weights(
            {"followed": 0.70, "played": 0.75, "saved": 0.82}
        ),
        "healthkit": _weights({"routine": 0.85}),
    }
)

SOURCE_ACTION_PAIRS = MappingProxyType(
    {
        source: frozenset(
            {("event", "scheduled")}
            if source in {"apple_calendar", "google_calendar"}
            else {("fitness_habit", "routine")}
            if source == "healthkit"
            else {(action, action) for action in weights}
        )
        for source, weights in SOURCE_ACTION_WEIGHTS.items()
    }
)


__all__ = [
    "DEFAULT_SOURCE_QUALITY",
    "SOURCE_ACTION_PAIRS",
    "SOURCE_ACTION_WEIGHTS",
    "SOURCE_LAYOUT",
]
