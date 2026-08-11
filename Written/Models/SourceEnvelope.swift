import Foundation

/// One observation on its way to the private vault.
///
/// **Phase 1 of the v0.3.1 integration, and it ships no behaviour.** Nothing
/// constructs or sends these yet. `DistilledRecord` remains the app's model and
/// the legacy sync path is untouched — §8's Phase 1 is *dual*-write, and this
/// is the half that does not exist yet.
///
/// The shape is §4's, with the names the database uses so a Lambda can map it
/// straight onto `semantic_private.raw_source_records` without a second
/// vocabulary in between.

struct SourceEnvelope: Codable, Equatable, Sendable {
    /// Bumped when this struct changes shape. The server stores it, so a row
    /// written by an old build stays readable by whatever reads it later —
    /// which is the same lesson `ChatStore`'s `written-chat-v2-` prefix records:
    /// an optional that decodes to nil is a value, not a gap.
    static let currentSchemaVersion = "written-source-envelope-v1"

    var schemaVersion: String = SourceEnvelope.currentSchemaVersion

    /// One per distillation run, shared by every envelope in it, and the thing
    /// that makes a run atomic on the server: `finalize_ingestion_run_v031`
    /// decides membership, coverage and tombstones from the set of rows sharing
    /// this id. The client mints it so a retry after a dropped connection
    /// resumes the same run rather than opening a second one.
    var ingestionID: UUID

    /// **Which connector ran, and whose data this row is — two facts, and the
    /// difference is the whole reason `0048` exists.**
    ///
    /// Before it, `raw_source_records` was constrained
    /// `(ingestion_run_id, user_id, source_code) → ingestion_runs`, so a row's
    /// source had to equal its run's. A `user` record collected during an Apple
    /// Music distillation was therefore stored as Apple Music evidence: the
    /// schema *encoded* the confusion rather than merely permitting it.
    ///
    /// `connectorSource` is what ran. `recordSource` is what the row is about.
    /// They are equal most of the time and the pair must be allowed by
    /// `connector_record_source_matrix`, which today holds only identity rows —
    /// so anything else is refused until somebody adds one with a rationale.
    var connectorSource: SemanticSource
    var recordSource: SemanticSource

    /// What the person did. `nil` when the row carries no act, which is a
    /// state the schema allows and the coverage report counts —
    /// see `ActionMapping.notAnAction`.
    var action: SemanticAction?

    /// Set when the row is a real behavioural signal the server has no weight
    /// for yet, carrying the name it would have. `action` is nil in that case.
    ///
    /// **Both nil is also meaningful**: the row is structurally not an act.
    var unweightedAction: String?

    /// Stable id of the item on the source platform — `DistilledRecord.itemID`.
    /// The server never stores it in the clear: it is HMAC'd into
    /// `source_item_hmac` against a key held only in KMS, so the vault can tell
    /// two rows apart without holding anything that identifies either.
    var providerItemID: String

    /// An ETag or version from the source, where it gives one. Nothing does
    /// today; it is here because a source that supports conditional fetches
    /// turns a full re-distill into a delta, and adding the field later means
    /// another envelope version.
    var providerRevisionOrETag: String?

    /// When Written read it — `DistilledRecord.collectedAt`.
    var observedAt: Date

    /// When the thing itself happened: a play, an event's start, a workout.
    /// **Distinct from `observedAt` on purpose.** Collapsing them is how a
    /// five-year-old calendar entry read a moment ago becomes recent.
    var sourceEventAt: Date?

    var lifecycleState: SemanticLifecycleState
    var dataUsePurpose: DataUsePurpose

    /// The typed body. Never a semicolon string; see `SourcePayload`.
    var typedPayload: SourcePayload

    /// The legacy row this envelope was derived from, so the two paths can be
    /// compared during shadow. §8's Phase 1 asks to "record old/new correlation
    /// IDs and compare record/source/action coverage", and this is the old id.
    ///
    /// **It is the whole of how a disagreement gets found.** Without it, two
    /// pipelines producing different counts is a number nobody can chase.
    var legacyCorrelationID: String?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case ingestionID = "ingestion_id"
        case connectorSource = "connector_source_code"
        case recordSource = "record_source_code"
        case action = "action_type"
        case unweightedAction = "unweighted_action_type"
        case providerItemID = "provider_item_id"
        case providerRevisionOrETag = "provider_revision"
        case observedAt = "observed_at"
        case sourceEventAt = "source_event_at"
        case lifecycleState = "lifecycle_state"
        case dataUsePurpose = "consent_purpose"
        case typedPayload = "typed_payload"
        case legacyCorrelationID = "legacy_correlation_id"
    }
}

// MARK: - Deriving one from the legacy row

extension SourceEnvelope {
    /// Why an envelope could not be built. Each case is a decision somebody has
    /// to make rather than an error to log and move past — which is why this is
    /// a typed reason and not `nil`.
    enum DerivationRefusal: Error, Equatable, Sendable {
        /// A `source` string the semantic schema has never heard of.
        case unknownSource(String)
        /// A `data_type` this source has never been recorded emitting, so
        /// `SemanticSource.actionsByDataType` has no entry and nobody has
        /// decided what it means.
        case unmappedDataType(source: SemanticSource, dataType: String)

        /// Short and stable, for counting refusals by kind during shadow.
        /// **Names the source and type rather than the row**, because the
        /// interesting question is which *kind* of thing this build cannot
        /// describe — one refusal and nine hundred are the same defect.
        var label: String {
            switch self {
            case .unknownSource(let code): return "unknown source: \(code)"
            case .unmappedDataType(let source, let dataType):
                return "unmapped: \(source.rawValue)/\(dataType)"
            }
        }
    }

    /// Build one from a `DistilledRecord`.
    ///
    /// **This is a shadow-path adapter and should not outlive Phase 2.** §4
    /// names `DistilledRecord` as "legacy UI model during shadow", and deriving
    /// a typed payload by re-parsing a `key=value;key=value` string inherits
    /// every bit of that string's lossiness: a value containing `;` or `=` was
    /// already unrecoverable before this function saw it. The right end state
    /// is distillers emitting `SourcePayload` directly, at which point this
    /// becomes the thing that proves the two agree and is then deleted.
    ///
    /// It exists now because dual-write is Phase 1 and rewriting nine
    /// distillers is not — and because a coverage comparison needs both paths
    /// running before anyone can say whether they disagree.
    static func derive(
        from record: DistilledRecord,
        ingestionID: UUID,
        connectorSource: SemanticSource
    ) -> Result<SourceEnvelope, DerivationRefusal> {
        guard let recordSource = SemanticSource.forAppSource(record.source) else {
            return .failure(.unknownSource(record.source))
        }
        guard let mapping = recordSource.mapping(for: record.dataType) else {
            return .failure(.unmappedDataType(source: recordSource, dataType: record.dataType))
        }

        var action: SemanticAction?
        var unweighted: String?
        switch mapping {
        case .actions:
            action = recordSource.action(for: record)
        case .unweighted(let name):
            unweighted = name
        case .notAnAction:
            break
        }

        return .success(
            SourceEnvelope(
                ingestionID: ingestionID,
                connectorSource: connectorSource,
                recordSource: recordSource,
                action: action,
                unweightedAction: unweighted,
                providerItemID: record.itemID,
                providerRevisionOrETag: nil,
                observedAt: record.collectedAt,
                sourceEventAt: record.sourceEventAt,
                // Every envelope this app builds describes something that is
                // currently there. `expired` and `deleted` are the server's to
                // set: it is the side that knows the retention policy and the
                // side obliged to honour a deletion request.
                lifecycleState: .active,
                dataUsePurpose: recordSource.dataUsePurpose,
                typedPayload: SourcePayload(record: record, source: recordSource),
                legacyCorrelationID: "\(record.source)/\(record.dataType)/\(record.itemID)"
            )
        )
    }
}
