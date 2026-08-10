from __future__ import annotations

import hashlib
import json
import re
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from typing import Any

from ..models import ExternalCandidate, Observation, Term
from ..safety import InferenceSafetyPolicy


CANDIDATE_PROPERTY_MAP = {
    "P31": "instance_of",
    "P279": "subclass_of",
    "P136": "genre",
    "P364": "original_language",
    "P495": "country_of_origin",
    "P17": "country",
    "P840": "narrative_location",
}

_QID = re.compile(r"^Q\d+$")
_INSTANCE_KIND = {
    "Q5": "creator",
    "Q43229": "organization",
    "Q215380": "creator",
    "Q11424": "work",
    "Q7725634": "work",
    "Q482994": "work",
    "Q6256": "place",
    "Q515": "place",
}


class WikidataProvider:
    provider_name = "wikidata"
    api_endpoint = "https://www.wikidata.org/w/api.php"
    entity_endpoint = "https://www.wikidata.org/wiki/Special:EntityData/{qid}.json"

    def __init__(
        self,
        user_agent: str,
        *,
        language: str = "en",
        limit: int = 3,
        timeout_seconds: float = 10.0,
        maximum_response_bytes: int = 2_000_000,
        cache_ttl_seconds: int = 86_400,
        minimum_request_interval_seconds: float = 0.10,
        safety: InferenceSafetyPolicy | None = None,
    ) -> None:
        if not user_agent or "contact@example.com" in user_agent:
            raise ValueError("configure an informative Wikidata User-Agent with real contact details")
        self.user_agent = user_agent
        self.language = language
        self.limit = max(1, min(limit, 5))
        self.timeout_seconds = timeout_seconds
        self.maximum_response_bytes = maximum_response_bytes
        self.cache_ttl_seconds = cache_ttl_seconds
        self.minimum_request_interval_seconds = max(0.0, minimum_request_interval_seconds)
        self.safety = safety or InferenceSafetyPolicy()
        self._entity_cache: dict[str, tuple[float, dict[str, Any]]] = {}
        self._request_lock = threading.Lock()
        self._last_request_at = 0.0

    def resolve(self, observation: Observation, term: Term) -> tuple[ExternalCandidate, ...]:
        if not self.safety.term_may_leave_device_boundary(observation, term):
            return ()
        if not term.text.strip() or len(term.text) > 120:
            return ()
        query = urllib.parse.urlencode(
            {
                "action": "wbsearchentities",
                "format": "json",
                "search": term.text,
                "language": self.language,
                "uselang": self.language,
                "type": "item",
                "limit": self.limit,
                "maxlag": 5,
            }
        )
        try:
            payload = self._get_json(f"{self.api_endpoint}?{query}")
        except (OSError, ValueError, json.JSONDecodeError):
            return ()
        results: list[ExternalCandidate] = []
        for rank, item in enumerate(payload.get("search", [])[: self.limit], start=1):
            qid = item.get("id")
            if not isinstance(qid, str) or not _QID.fullmatch(qid):
                continue
            try:
                entity = self._get_entity(qid)
            except (OSError, ValueError, json.JSONDecodeError):
                continue
            aliases = tuple(
                alias.get("value", "")
                for alias in entity.get("aliases", {}).get(self.language, [])
                if alias.get("value")
            )
            proposed_edges = self._safe_claims(entity)
            entity_kind = self._entity_kind(entity)
            retrieved_at = datetime.now(timezone.utc).isoformat()
            minimized = self._minimized_projection(entity, aliases, proposed_edges)
            canonical_payload = json.dumps(minimized, ensure_ascii=False, sort_keys=True).encode(
                "utf-8"
            )
            results.append(
                ExternalCandidate(
                    provider=self.provider_name,
                    external_id=qid,
                    label=item.get("label") or qid,
                    description=item.get("description"),
                    entity_kind=entity_kind,
                    aliases=aliases,
                    proposed_edges=proposed_edges,
                    retrieval_score=round(1.0 / rank, 8),
                    provenance={
                        "provider": self.provider_name,
                        "external_id": qid,
                        "canonical_url": f"https://www.wikidata.org/entity/{qid}",
                        "retrieved_at": retrieved_at,
                        "payload_sha256": hashlib.sha256(canonical_payload).hexdigest(),
                        "license": "CC0-1.0",
                        "status": "candidate_only",
                        "retrieval_rank": rank,
                        "cache_ttl_seconds": self.cache_ttl_seconds,
                    },
                )
            )
        return tuple(results)

    def _get_json(self, url: str) -> dict[str, Any]:
        last_error: OSError | None = None
        for attempt in range(2):
            try:
                return self._get_json_once(url)
            except urllib.error.HTTPError as error:
                last_error = error
                if error.code not in {429, 500, 502, 503, 504} or attempt == 1:
                    raise
            except (urllib.error.URLError, TimeoutError) as error:
                last_error = error
                if attempt == 1:
                    raise
            time.sleep(0.25 * (2**attempt))
        raise OSError("Wikidata request failed") from last_error

    def _get_json_once(self, url: str) -> dict[str, Any]:
        request = urllib.request.Request(
            url,
            headers={"User-Agent": self.user_agent, "Accept": "application/json"},
        )
        with self._request_lock:
            wait_seconds = self.minimum_request_interval_seconds - (
                time.monotonic() - self._last_request_at
            )
            if wait_seconds > 0:
                time.sleep(wait_seconds)
            try:
                with urllib.request.urlopen(request, timeout=self.timeout_seconds) as response:
                    declared_size = response.headers.get("Content-Length")
                    if declared_size and int(declared_size) > self.maximum_response_bytes:
                        raise ValueError(
                            "Wikidata response exceeded the configured size limit"
                        )
                    payload = response.read(self.maximum_response_bytes + 1)
            finally:
                self._last_request_at = time.monotonic()
        if len(payload) > self.maximum_response_bytes:
            raise ValueError("Wikidata response exceeded the configured size limit")
        decoded = json.loads(payload)
        if not isinstance(decoded, dict):
            raise ValueError("Wikidata response was not an object")
        return decoded

    def _get_entity(self, qid: str) -> dict[str, Any]:
        cached = self._entity_cache.get(qid)
        now = time.monotonic()
        if cached is not None and cached[0] > now:
            return cached[1]
        payload = self._get_json(self.entity_endpoint.format(qid=qid))
        entity = payload.get("entities", {}).get(qid, {})
        if not isinstance(entity, dict):
            raise ValueError("Wikidata entity was not an object")
        projection = self._cache_projection(entity)
        self._entity_cache[qid] = (now + self.cache_ttl_seconds, projection)
        return projection

    def _cache_projection(self, entity: dict[str, Any]) -> dict[str, Any]:
        aliases = entity.get("aliases", {}).get(self.language, [])
        claims: dict[str, list[dict[str, Any]]] = {}
        for property_id in CANDIDATE_PROPERTY_MAP:
            projected_claims = []
            for claim in entity.get("claims", {}).get(property_id, []):
                projected_claims.append(
                    {
                        "rank": claim.get("rank", "normal"),
                        "mainsnak": {
                            "snaktype": claim.get("mainsnak", {}).get("snaktype"),
                            "datavalue": claim.get("mainsnak", {}).get("datavalue"),
                        },
                    }
                )
            if projected_claims:
                claims[property_id] = projected_claims
        return {
            "id": entity.get("id"),
            "lastrevid": entity.get("lastrevid"),
            "aliases": {self.language: aliases[:20]},
            "claims": claims,
        }

    @staticmethod
    def _entity_kind(entity: dict[str, Any]) -> str | None:
        for claim in entity.get("claims", {}).get("P31", []):
            if claim.get("rank") == "deprecated":
                continue
            mainsnak = claim.get("mainsnak", {})
            if mainsnak.get("snaktype") != "value":
                continue
            value = mainsnak.get("datavalue", {}).get("value", {})
            if isinstance(value, dict) and value.get("id") in _INSTANCE_KIND:
                return _INSTANCE_KIND[value["id"]]
        return None

    @staticmethod
    def _minimized_projection(
        entity: dict[str, Any],
        aliases: tuple[str, ...],
        proposed_edges: tuple[dict[str, Any], ...],
    ) -> dict[str, Any]:
        return {
            "id": entity.get("id"),
            "lastrevid": entity.get("lastrevid"),
            "aliases": aliases[:20],
            "candidate_edges": proposed_edges,
        }

    @staticmethod
    def _safe_claims(entity: dict[str, Any]) -> tuple[dict[str, Any], ...]:
        proposals: list[dict[str, Any]] = []
        for property_id, predicate in CANDIDATE_PROPERTY_MAP.items():
            for claim in entity.get("claims", {}).get(property_id, []):
                if claim.get("rank") == "deprecated":
                    continue
                mainsnak = claim.get("mainsnak", {})
                if mainsnak.get("snaktype") != "value":
                    continue
                datavalue = mainsnak.get("datavalue", {}).get("value")
                if isinstance(datavalue, dict):
                    target = datavalue.get("id")
                else:
                    target = datavalue
                if not isinstance(target, str) or not _QID.fullmatch(target):
                    continue
                proposals.append(
                    {
                        "property_id": property_id,
                        "predicate": predicate,
                        "target_external_id": target,
                        "rank": claim.get("rank", "normal"),
                        "status": "candidate_only",
                    }
                )
        return tuple(proposals)
