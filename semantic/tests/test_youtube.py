from __future__ import annotations

import unittest

from written_ontology.youtube import (
    ResolutionState,
    StaticYouTubeChannelResolver,
    YouTubeChannelResolution,
    YouTubeChannelRole,
    YouTubeTermPolicy,
    build_youtube_terms,
)


CREATOR_ID = "UCaaaaaaaaaaaaaaaaaaaaaa"
PUBLISHER_ID = "UCbbbbbbbbbbbbbbbbbbbbbb"
FAN_ID = "UCcccccccccccccccccccccc"


def resolution(
    channel_id: str,
    role: YouTubeChannelRole,
    *,
    represented_label: str | None = None,
    represented_kind: str | None = None,
) -> YouTubeChannelResolution:
    return YouTubeChannelResolution(
        channel_id=channel_id,
        channel_label="Cached channel label",
        role=role,
        state=ResolutionState.ACTIVE,
        exact_id_match=True,
        confidence=0.95,
        provenance="curated_exact_channel_id",
        represented_label=represented_label,
        represented_kind=represented_kind,
    )


class YouTubeTermTests(unittest.TestCase):
    def test_official_creator_is_distinct_from_channel_and_content(self) -> None:
        resolver = StaticYouTubeChannelResolver(
            (
                resolution(
                    CREATOR_ID,
                    YouTubeChannelRole.OFFICIAL_CREATOR,
                    represented_label="Example Artist",
                    represented_kind="creator",
                ),
            )
        )
        result = build_youtube_terms(
            action="liked_video",
            channel_id=CREATOR_ID,
            channel_label="Example Artist Official",
            title="A performance",
            provider_topics=("Music",),
            policy=YouTubeTermPolicy(
                channel_identity_terms=True,
                channel_role_resolution=True,
            ),
            resolver=resolver,
        )
        by_role = {term.role: term for term in result.terms}
        self.assertEqual(result.channel_role, YouTubeChannelRole.OFFICIAL_CREATOR)
        self.assertEqual(by_role["youtube_provider_topic"].evidence_weight, 1.0)
        self.assertEqual(by_role["youtube_channel"].type_hint, "channel")
        self.assertEqual(by_role["channel_represents_creator"].type_hint, "creator")
        self.assertEqual(by_role["channel_represents_creator"].evidence_weight, 0.20)

    def test_subscription_is_stronger_creator_evidence_than_one_like(self) -> None:
        resolver = StaticYouTubeChannelResolver(
            (
                resolution(
                    CREATOR_ID,
                    YouTubeChannelRole.OFFICIAL_CREATOR,
                    represented_label="Example Artist",
                    represented_kind="creator",
                ),
            )
        )
        result = build_youtube_terms(
            action="subscription",
            channel_id=CREATOR_ID,
            channel_label="Renamed channel",
            title="",
            provider_topics=("Music",),
            policy=YouTubeTermPolicy(
                channel_identity_terms=True,
                channel_role_resolution=True,
            ),
            resolver=resolver,
        )
        creator = next(
            term for term in result.terms if term.role == "channel_represents_creator"
        )
        self.assertEqual(creator.evidence_weight, 0.85)

    def test_stable_channel_id_survives_title_change(self) -> None:
        resolver = StaticYouTubeChannelResolver(
            (
                resolution(
                    CREATOR_ID,
                    YouTubeChannelRole.OFFICIAL_CREATOR,
                    represented_label="Canonical Creator",
                    represented_kind="creator",
                ),
            )
        )
        labels = []
        for current_title in ("Old title", "Completely new title"):
            result = build_youtube_terms(
                action="subscription",
                channel_id=CREATOR_ID,
                channel_label=current_title,
                title="",
                provider_topics=(),
                policy=YouTubeTermPolicy(
                    channel_identity_terms=True,
                    channel_role_resolution=True,
                ),
                resolver=resolver,
            )
            labels.append(
                next(
                    term.text
                    for term in result.terms
                    if term.role == "channel_represents_creator"
                )
            )
        self.assertEqual(labels, ["Canonical Creator", "Canonical Creator"])

    def test_publisher_and_fan_channels_never_become_the_featured_creator(self) -> None:
        resolver = StaticYouTubeChannelResolver(
            (
                resolution(
                    PUBLISHER_ID,
                    YouTubeChannelRole.PUBLISHER,
                    represented_label="Example Network",
                    represented_kind="organization",
                ),
                resolution(FAN_ID, YouTubeChannelRole.FAN_REPOST),
            )
        )
        publisher = build_youtube_terms(
            action="liked_video",
            channel_id=PUBLISHER_ID,
            channel_label="Example Network",
            title="Celebrity interview",
            provider_topics=("Entertainment",),
            policy=YouTubeTermPolicy(
                channel_identity_terms=True,
                channel_role_resolution=True,
            ),
            resolver=resolver,
        )
        fan = build_youtube_terms(
            action="liked_video",
            channel_id=FAN_ID,
            channel_label="Celebrity Fan Clips",
            title="Celebrity fancam",
            provider_topics=("Music",),
            policy=YouTubeTermPolicy(
                channel_identity_terms=True,
                channel_role_resolution=True,
            ),
            resolver=resolver,
        )
        self.assertIn("youtube_publisher", {term.role for term in publisher.terms})
        self.assertNotIn(
            "channel_represents_creator", {term.role for term in publisher.terms}
        )
        self.assertNotIn("channel_represents_creator", {term.role for term in fan.terms})

    def test_mismatched_or_candidate_resolution_fails_closed(self) -> None:
        mismatched = YouTubeChannelResolution(
            channel_id=PUBLISHER_ID,
            channel_label="Wrong",
            role=YouTubeChannelRole.OFFICIAL_CREATOR,
            state=ResolutionState.ACTIVE,
            exact_id_match=True,
            confidence=1.0,
            provenance="bad_cache_key",
            represented_label="Wrong creator",
            represented_kind="creator",
        )
        resolver = StaticYouTubeChannelResolver((mismatched,))
        result = build_youtube_terms(
            action="subscription",
            channel_id=CREATOR_ID,
            channel_label="Actual channel",
            title="",
            provider_topics=("Music",),
            policy=YouTubeTermPolicy(channel_role_resolution=True),
            resolver=resolver,
        )
        self.assertFalse(result.resolution_used)
        self.assertNotIn(
            "channel_represents_creator", {term.role for term in result.terms}
        )

    def test_surface_and_cross_source_permissions_default_off(self) -> None:
        result = build_youtube_terms(
            action="liked_video",
            channel_id=CREATOR_ID,
            channel_label="Channel",
            title="Title",
            provider_topics=("Science",),
        )
        self.assertFalse(result.policy.cross_source_fusion)
        self.assertFalse(result.policy.bio_surface)
        self.assertFalse(result.policy.icebreaker_surface)
        self.assertEqual({term.text for term in result.terms}, {"Science"})

    def test_title_and_uploader_tags_are_separate_explicit_capabilities(self) -> None:
        result = build_youtube_terms(
            action="liked_video",
            channel_id=CREATOR_ID,
            channel_label="Channel",
            title="Specific video title",
            provider_topics=("Music",),
            uploader_tags=("Dance practice",),
            policy=YouTubeTermPolicy(uploader_tags=True, written_title_tags=True),
        )
        roles = {term.role for term in result.terms}
        self.assertEqual(
            roles,
            {
                "youtube_provider_topic",
                "youtube_uploader_tag",
                "written_derived_title_candidate",
            },
        )


if __name__ == "__main__":
    unittest.main()
