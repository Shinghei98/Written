"""The iOS envelope vocabulary, checked against the app that feeds it.

Phase 1 of the v0.3.1 integration adds `SourceEnvelope`, and the envelope needs
a vocabulary: which sources exist, and what act each `data_type` represents.
`Written/Models/SemanticSource.swift` writes that down — a second copy of names
the database already owns — and a second copy is only safe while something
compares it to the first.

**Two comparisons, two authorities, and this file is only one of them.** Here:
every `data_type` the shipping app can emit is mapped, and every `source:`
literal resolves. In `tools/replay_contracts.sh`: every action the mapping
names is one that source actually weighs, asked of the built schema rather than
reconstructed by parsing five migrations.

The check that earns its keep is the first. A `data_type` added to a distiller
with no entry here would reach the vault as a row nothing downstream can read —
the extraction rule pointed the other way, where keeping a field is free and
keeping it *meaningless* is the expensive part.

Skipped when `WRITTEN_REPOSITORY_PATH` is unset, like the rest of the
repository-integration suite: the package is installable without the app
checkout beside it.
"""

import os
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

_configured = os.environ.get("WRITTEN_REPOSITORY_PATH")
REPO = Path(_configured).resolve() if _configured else None

if REPO is not None:
    sys.path.insert(0, str(REPO / "tools"))

try:
    import ios_envelope_contract
except ImportError:  # pragma: no cover - only when the checkout is absent
    ios_envelope_contract = None


@unittest.skipIf(
    REPO is None or ios_envelope_contract is None,
    "WRITTEN_REPOSITORY_PATH is not configured",
)
class IOSEnvelopeContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.data = ios_envelope_contract.load(REPO)
        cls.mapping = cls.data["mapping"]
        cls.mapped_data_types = {
            data_type
            for entries in cls.mapping.values()
            for data_type in entries
        }

    def test_every_emitted_data_type_is_mapped(self) -> None:
        """The whole point of the file.

        A distiller gaining a `data_type` fails here until somebody says what
        it means — an action, a signal the server does not weigh yet, or
        structurally not an act at all. Those are three different answers and
        the enum keeps them apart; what it must never allow is a fourth,
        silent one.
        """
        unmapped = []
        for name, data_types in sorted(self.data["distiller_data_types"].items()):
            for data_type in data_types:
                if data_type not in self.mapped_data_types:
                    unmapped.append(f"{name}: {data_type}")
        self.assertEqual(
            unmapped,
            [],
            "these data types reach the vault with no meaning attached; add "
            "them to SemanticSource.actionsByDataType",
        )

    def test_every_emitted_source_resolves(self) -> None:
        """`health` against `healthkit` is why this is not an identity check.

        Every distiller writes `source: "health"`; the semantic schema calls it
        `healthkit`. Neither is wrong and renaming either rewrites history in an
        append-only table, so the translation lives in `appSourceCode` — and
        this asserts it covers everything the app actually writes.
        """
        translations = self.data["app_source_codes"]
        unresolved = [
            code
            for code in self.data["distiller_source_codes"]
            if code not in translations
        ]
        self.assertEqual(unresolved, [], "no SemanticSource maps these")

    def test_health_is_translated_rather_than_assumed(self) -> None:
        """The one non-identity translation, pinned so it cannot be tidied away
        by someone who notices the switch has a single case."""
        self.assertEqual(self.data["app_source_codes"]["health"], "healthkit")

    def test_a_calendar_row_is_renamed_for_the_schema(self):
        """`event` against `calendar_event`, the second translation seam.

        **It cannot be corrected downstream, which is why it is pinned here.**
        `guard_ingestion_run_item_v031` requires the raw record, the scope
        manifest and the observation to carry the *same* `data_type`, and
        `private_observation_projection_is_valid_v03` demands `calendar_event`
        of the observation — so the whole row has to say it from the device
        onward. An attempt to let the projection rename it was refused by the
        database after the payloads were already encrypted.
        """
        mapped = self.data["semantic_data_types"]
        self.assertEqual(mapped["appleCalendar/event"], "calendar_event")
        self.assertEqual(mapped["googleCalendar/event"], "calendar_event")
        self.assertEqual(mapped["outlookCalendar/event"], "calendar_event")
        # Nothing else is translated: every entry here is another place for the
        # two vocabularies to drift, so the count is pinned as well as the
        # entries. A new calendar connector belongs in this list; anything that
        # is not a calendar arriving here means a rename was reached for where
        # the schema's own vocabulary should have been used from the device on.
        self.assertEqual(len(mapped), 3)
        self.assertNotIn("health", self.data["sources"])

    def test_mapped_sources_are_all_declared(self) -> None:
        declared = set(self.data["sources"])
        self.assertTrue(set(self.mapping) <= declared)

    def test_the_ingestion_endpoint_accepts_every_source_the_app_declares(self):
        """The third copy of the source list, and the one nothing checked.

        `SemanticSource` in Swift, `SOURCE_CODES` in `aws/ingestion/lib.mjs` and
        `semantic_private.sources` in Postgres are three writings of one list.
        The first two were never compared, and they drifted: `outlook_calendar`
        was added to the enum and to `AppConfig.semanticIngestionSources` and
        not to the Lambda.

        **The failure mode is silence, which is why an equality is asserted
        rather than a subset.** A code the endpoint does not hold makes
        `normalizeSource` answer null, `index.mjs` answer `400`, and
        `SemanticIngestionService` treat the refusal as permanent and drop the
        batch — a distillation that lands in `distilled_records` and never
        reaches the vault, with nothing failing anywhere. The reverse drift is
        cheaper but still wrong: a code the Lambda accepts and the app cannot
        produce is a door held open for a source nobody decided to add.
        """
        self.assertEqual(
            set(self.data["ingestion_source_codes"]),
            set(self.data["sources"]),
            "SemanticSource and aws/ingestion/lib.mjs SOURCE_CODES disagree; a "
            "source the endpoint does not hold has its batches refused 400 and "
            "dropped",
        )

    def test_actions_enum_carries_nothing_unused(self) -> None:
        """A vocabulary entry nobody uses is a claim the app cannot support.

        `SemanticAction` is deliberately a *subset* of what the server weighs —
        only the members this app can produce. One that no mapping names is
        either a mapping somebody forgot to write or a case that should go.
        """
        used = {
            action
            for entries in self.mapping.values()
            for value in entries.values()
            if value[0] == "actions"
            for action in value[1]
        }
        self.assertEqual(
            sorted(set(self.data["actions"]) - used),
            [],
            "declared in SemanticAction and never mapped",
        )

    def test_calendar_events_can_be_either_act(self) -> None:
        """A calendar event is `booked` or `scheduled` depending on the row, and
        that distinction is the reason the source exists — a booking a ticketing
        site wrote in cost money and a Saturday.

        **`scheduled`, not `entered_by_user`, and the schema chose it rather
        than us.** `sources.action_weights` knows both, but
        `private_observation_projection_is_valid_v03` allows a calendar
        observation only `scheduled` or `booked`, and
        `guard_ingestion_run_item_v031` requires the observation's action to
        equal its scope's. So `entered_by_user` could be captured and could
        never become evidence — the rows would land and describe nothing, which
        is the failure mode hardest to notice. The distinction it carried is
        intact under the new name.

        Pinned on both calendars, since Google Calendar returning through a
        different distiller is exactly the kind of place one of a pair gets
        updated and the other does not.
        """
        for source in ("apple_calendar", "google_calendar"):
            kind, actions = self.mapping[source]["event"]
            self.assertEqual(kind, "actions")
            self.assertEqual(sorted(actions), ["booked", "scheduled"])

    def test_biological_sex_is_never_an_action(self) -> None:
        """It is a protected characteristic, it never leaves the device, and
        `SyncService.localOnlyTypes` refuses it at the wire. Weighing it as
        behaviour would be a category error before it was anything else."""
        self.assertEqual(
            self.mapping["healthkit"]["biological_sex"],
            ("not_an_action", "demographic"),
        )

    def test_unweighted_signals_are_a_known_list(self) -> None:
        """The list Phase 1 exists to produce.

        `unweighted` means a real behavioural signal the server has no weight
        for — as distinct from `notAnAction`, which means there is nothing to
        weigh. Keeping them apart is what stops the second quietly absorbing
        the first, and this pins the list so an addition is a decision rather
        than a drift.

        `top_track` is the sharpest of them: it carries an explicit `rank=N`
        and is the strongest listening signal either music source returns.
        """
        unweighted = sorted(
            f"{source}/{data_type}"
            for source, entries in self.mapping.items()
            for data_type, value in entries.items()
            if value[0] == "unweighted"
        )
        self.assertEqual(
            unweighted,
            [
                "apple_music/heavy_rotation",
                "apple_music/library_music_video",
                "location/place",
                "spotify/top_artist",
                "spotify/top_track",
            ],
        )

    def test_debug_fixtures_are_not_counted(self) -> None:
        """`DistillViewModel`'s preview records emit a `preview` data type and
        several real-looking ones inside `#if DEBUG`. None ships, none syncs,
        and demanding a mapping for them would be demanding one for a row that
        cannot exist in production."""
        self.assertNotIn("preview", self.mapped_data_types)
        emitted = {
            data_type
            for data_types in self.data["distiller_data_types"].values()
            for data_type in data_types
        }
        self.assertNotIn("preview", emitted)


if __name__ == "__main__":
    unittest.main()
