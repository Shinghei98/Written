/**
 * Works named outright in a video title, recognised and the title discarded.
 *
 * **Why this is read-derive-discard and not storage.** The owner's
 * determination of 2026-08-13 settled the pattern: a title may be *read* at
 * ingestion, a term derived from it, and the sentence dropped — what III.E.4
 * requires deleted or refreshed within thirty days is the title, and no title
 * reaches `normalized_payload`. What lands is a concept key that already exists
 * in our vocabulary, which is the same object `channel_identity` emits and no
 * more YouTube's than `creator:le_sserafim` is Apple Music's.
 *
 * **Why it lives in the bundle rather than in a table.** `semantic_ingestor`
 * can call exactly one `security definer` function and holds zero table
 * privileges — leaked, it writes vault rows and reads none of them back. A
 * catalogue lookup would mean granting it a read, which is the one property of
 * that identity worth keeping. So the catalogue ships with the Lambda and is
 * regenerated deliberately, and a work absent from it is simply unrecognised.
 *
 * **Why recognition is not inference.** III.E.4.h forbids estimating the
 * category or type of a video. This estimates nothing: it matches a work's own
 * name, whole, against a closed list we authored — the line already drawn for
 * `snippet.tags`, where recognising `physics` is translation and matching
 * `phys` inside a string is a guess wearing the same clothes.
 */

/**
 * The one rule that governs what may be added here: **an alias must not be a
 * word.**
 *
 * `Bleach` is a laundry product, `Fate` is a noun, `Persona` is a psychology
 * term, and `SAO` is three letters that occur inside ordinary text. Each of
 * them would attach a work to somebody who never watched it, and a term in the
 * wrong place is a false claim about a person — the same reason four channels
 * are left unparented rather than filed somewhere plausible. So bare `bleach`,
 * `fate`, `persona` and `sao` are refused below by omission, deliberately, and
 * only forms carrying a colon, a slash or a script that does not appear in
 * English prose are listed.
 *
 * Every `key` must already exist in `ontology.concepts`. A key that does not is
 * not an error here — the resolver drops it silently, which is exactly the
 * failure mode that is hard to see later.
 */
export const WORK_TITLE_CATALOGUE = [
  {
    key: "work:sword_art_online_alicization",
    aliases: ["sword art online: alicization", "ソードアート・オンライン アリシゼーション"],
  },
  {
    key: "work:sword_art_online_ii",
    aliases: ["sword art online ii", "ソードアート・オンライン ii"],
  },
  {
    key: "work:sword_art_online",
    aliases: [
      "sword art online",
      "ソードアート・オンライン",
      "ソードアートオンライン",
    ],
  },
  {
    key: "work:bleach_thousand_year_blood_war",
    aliases: [
      "bleach: thousand-year blood war",
      "bleach thousand-year blood war",
      "千年血戦篇",
    ],
  },
  {
    key: "work:fate_zero",
    aliases: ["fate/zero", "フェイト/ゼロ"],
  },
  {
    key: "work:persona_5_dancing_in_starlight",
    aliases: ["persona 5: dancing in starlight", "persona 5 dancing in starlight"],
  },
];

/** At most this many works from one title. A title naming seven is spam. */
const MAX_WORKS = 4;

/**
 * `NFKC`, never `NFKD`.
 *
 * Decomposition splits a Hangul syllable into jamo and a katakana glyph from
 * its mark, so a decomposed haystack stops containing the composed needle. That
 * is the same normalisation mistake that once stripped every Korean artist name
 * to empty; composition is the safe direction and folds full-width Latin into
 * ASCII on the way, which is what a Japanese title carrying `SAO II` needs.
 */
function fold(text) {
  return text.normalize("NFKC").toLowerCase();
}

/** True where the alias is ASCII enough that adjacent letters would change it. */
function needsWordBoundary(alias) {
  return /^[\x20-\x7e]+$/.test(alias);
}

/**
 * Whether `haystack` names `alias` rather than merely containing its letters.
 *
 * Latin aliases are checked at their edges, so `sword art online` does not
 * match inside `swords`; CJK aliases are checked by containment, because
 * Japanese is written without spaces and a boundary test would refuse every
 * real title.
 */
function names(haystack, alias) {
  const at = haystack.indexOf(alias);
  if (at < 0) return false;
  if (!needsWordBoundary(alias)) return true;
  const before = at === 0 ? "" : haystack[at - 1];
  const after = haystack[at + alias.length] ?? "";
  return !/[a-z0-9]/.test(before) && !/[a-z0-9]/.test(after);
}

/**
 * The works a title names, most specific first, the title itself discarded.
 *
 * **Most specific wins, and that is not tidiness.** Every title naming
 * *Sword Art Online II* also names *Sword Art Online*, so emitting both would
 * count one video twice and inflate a work whose whole problem is that it sits
 * just under the bar on thin evidence. A longer alias therefore suppresses any
 * shorter one it contains.
 */
export function worksNamedIn(title) {
  const haystack = fold(String(title ?? ""));
  if (!haystack) return [];

  const hits = [];
  for (const entry of WORK_TITLE_CATALOGUE) {
    for (const alias of entry.aliases) {
      const folded = fold(alias);
      if (names(haystack, folded)) {
        hits.push({ key: entry.key, alias: folded });
        break;
      }
    }
  }

  hits.sort((a, b) => b.alias.length - a.alias.length);
  const kept = [];
  for (const hit of hits) {
    if (kept.some((k) => k.alias.includes(hit.alias))) continue;
    kept.push(hit);
  }
  return kept.slice(0, MAX_WORKS).map((hit) => hit.key);
}
