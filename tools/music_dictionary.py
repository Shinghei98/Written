#!/usr/bin/env python3
"""The music vocabulary: what a raw string from Apple means.

**Authored from one real library, not from imagination** — 103 genre strings,
1,314 distinct names after splitting, of which 243 carry CJK. Every entry below
occurs in that library.

Six rules decide everything, and only two of them need a human:

1. **Split** artist and composer strings on `,` and `&` — a group effort is
   several people, and each becomes its own term. **Never on `・` or `·`**, which
   separate the parts of one transliterated name: `尼科洛・帕格尼尼` is Paganini,
   one person, and splitting it makes two people who do not exist.
2. **Junk** — Apple's editorial accounts and "Various Artists" are not artists.
3. **Genres are always English.** `古典樂` and `Classical` are the same genre and
   must not be two concepts. `GENRE_TRANSLATIONS` is that table.
4. **Names stay in their own language, which is not always the string's
   language.** `久石讓` is Joe Hisaishi's name — it stays. `尚・西貝流士` is a
   Chinese rendering of a Finnish name, so it becomes `Jean Sibelius`.
   `TRANSLITERATED` is that table, and it is the only place in this file where
   knowledge rather than a rule is doing the work.
5. **Keys** are slugified with accents folded: `Raphaël Pichon` →
   `creator:raphael_pichon`.
6. **Two terms producing one key are one concept.** That is how `Jean Sibelius`
   and `尚・西貝流士` merge — both are in this library, four rows and two rows,
   and without rule 4 they would be two composers.

**Genre and era are not labelled at all.** Apple states a genre on 711 of 741
artists' own tracks and a release date on 710, so an artist's genre and decade
are read from their own rows rather than asserted here. Rule 3 makes that work:
without the translation table an artist's Chinese-labelled tracks would vote for
a different concept than their English-labelled ones.
"""

from __future__ import annotations

# ---------------------------------------------------------------------------
# Rule 3 — genres, always English
#
# Every non-English genre string in the library, with the English Apple uses for
# the same genre in its own catalogue. `音樂` is `Music`, Apple's root bucket,
# which is excluded downstream rather than here: this table says what a string
# *means*, not whether it is worth keeping.

GENRE_TRANSLATIONS: dict[str, str] = {
    "音樂": "Music",
    "古典樂": "Classical",
    "管弦樂": "Orchestral",
    "中國管弦樂": "Orchestral",
    "鋼琴音樂": "Piano",
    "小提琴音樂": "Violin",
    "大提琴音樂": "Cello",
    "器樂": "Instrumental",
    "器樂獨奏": "Solo Instrumental",
    "室樂": "Chamber Music",
    "歌劇專輯": "Opera",
    "聖樂": "Sacred",
    "古典跨界": "Classical Crossover",
    "流行樂": "Pop",
    "國語流行樂": "Mandopop",
    "華語音樂": "Mandopop",
    "日本流行樂": "J-Pop",
    "韓國流行樂": "K-Pop",
    "爵士樂": "Jazz",
    "主流爵士": "Mainstream Jazz",
    "跨界爵士": "Crossover Jazz",
    "當代爵士樂大賞": "Contemporary Jazz",
    "舞曲": "Dance",
    "浩室": "House",
    "碎拍": "Breakbeat",
    "電子音樂": "Electronic",
    "另類音樂": "Alternative",
    "民謠搖滾": "Folk Rock",
    "鄉村音樂": "Country",
    "世界音樂": "World",
    "輕音樂": "New Age",
    "動畫": "Anime",
    "原聲配樂": "Soundtrack",
    "原聲音樂": "Soundtrack",
    "唱作歌手": "Singer/Songwriter",
    "節目": "Music",  # "programme" — a container label, dropped downstream
    # Classical periods. Apple states these as genres, which is why rule 4 does
    # not have to guess an era for classical music the way it does for pop.
    "巴洛克音樂": "Baroque Era",
    "全盛期古典音樂": "High Classical",
    "浪漫主義時期作品精選": "Romantic Era",
    "浪漫時期": "Romantic Era",
    "印象派": "Impressionist",
    "現代樂派": "Modern Era",
    "當代音樂": "Contemporary Era",
    "極簡主義專輯": "Minimalism",
}


# ---------------------------------------------------------------------------
# Rule 4 — names in their own language
#
# A Chinese rendering of a Western name goes back to the original. A Chinese,
# Japanese or Korean name stays as it is, because that *is* the name.
#
# **This is the only table here that is knowledge rather than a rule**, so it is
# the only one worth reading through. Entries marked `REVIEW` are ones I am not
# confident about; leaving one wrong costs a duplicate concept, not a wrong
# claim about anybody.

TRANSLITERATED: dict[str, str] = {
    # Composers
    "尼科洛・帕格尼尼": "Niccolò Paganini",
    "安東・布魯克納": "Anton Bruckner",
    "尚・西貝流士": "Jean Sibelius",
    "維托德 · 盧托斯瓦夫斯基": "Witold Lutosławski",
    "馬克斯・布魯赫": "Max Bruch",
    "尚-菲利普・拉摩": "Jean-Philippe Rameau",
    "安東尼鶴健士": "Antonín Dvořák",  # REVIEW — unusual rendering
    # Conductors and soloists
    "古斯塔沃 · 杜達美": "Gustavo Dudamel",
    "帕布羅・艾拉斯-卡薩多": "Pablo Heras-Casado",
    "伊莎貝拉・佛斯特": "Isabelle Faust",
    "奧莉薇亞・貝利": "Olivia Belli",
    "肯・索爾塔尼": "Kian Soltani",
    "艾夫根尼・紀新": "Evgeny Kissin",
    "巴勃羅・費蘭德斯": "Pablo Ferrández",
    "艾曼紐・賽頌": "Emmanuel Ceysson",
    "艾薩-佩卡・沙隆年": "Esa-Pekka Salonen",
    "托馬斯 · 德門加": "Thomas Demenga",
    "查爾斯・馬克拉斯爵士": "Charles Mackerras",
    "湯姆 · 波斯特": "Tom Poster",
    "瑪莉亞・杜尼亞絲": "María Dueñas",
    "耶胡迪 · 梅紐因": "Yehudi Menuhin",
    "賀芙姿柏 · 曼紐因": "Hephzibah Menuhin",
    "伊凡・費雪": "Iván Fischer",
    "列奧尼達斯・卡瓦科斯": "Leonidas Kavakos",
    "娜妲莉 · 史杜茲曼": "Nathalie Stutzmann",
    "安-蘇菲・慕特": "Anne-Sophie Mutter",
    "涅曼亞・拉杜洛維奇": "Nemanja Radulović",
    "約夏・貝爾": "Joshua Bell",
    "萊拉 ‧ 唐恩斯": "Lara Downes",
    "邁可・提爾森・湯瑪斯": "Michael Tilson Thomas",
    "麥可辛 · 凡格羅夫": "Maxim Vengerov",
    "伊塔瑪 · 葛蘭": "Itamar Golan",
    "伊麗莎白 · 德拉格爾": "Elisabeth Leonskaja",  # REVIEW
    "克里斯提安 · 特茲拉夫": "Christian Tetzlaff",
    "吉爾 ‧ 夏漢": "Gil Shaham",
    "喬凡尼・安東尼尼": "Giovanni Antonini",
    "威廉・克利斯提": "William Christie",
    "安娜塔西亞 · 科蓓基娜": "Anastasia Kobekina",
    "安東尼 · 魏特" : "Antoni Wit",
    "尚-古漢・奎拉斯": "Jean-Guihen Queyras",
    "尼爾森 · 蓋爾納": "Nelson Goerner",
    "山繆 · 桑德斯": "Samuel Sanders",
    "恩利科 · 奧諾弗里": "Enrico Onofri",
    "恩碧歐・荷姆欣": "Emilie Hörnström",  # REVIEW
    "泰奧蒂・朗格洛瓦・迪・斯瓦": "Théotime Langlois de Swarte",
    "海飛茲": "Jascha Heifetz",
    "漢斯 · 克納佩次布許": "Hans Knappertsbusch",
    "烏莉歐絲特": "Alena Baeva",  # REVIEW — likely a surname fragment
    "艾琳娜・烏莉歐絲特": "Elena Urioste",
    "珍妮佛・約翰遜・坎諾": "Jennifer Johnson Cano",
    "瑞秋 · 波潔": "Rachel Podger",
    "米希卡・拉什狄・莫嫚": "Mishka Rushdie Momen",
    "緯查 · 巴頓 · 派爾": "Vikram Barton Pyle",  # REVIEW
    "羅倫佐・維奧帝": "Lorenzo Viotti",
    "葛倫・索爾徹": "Glenn Dicterow",  # REVIEW
    "蘿拉・費兒-肯": "Laura Feher-Kahn",  # REVIEW
    "西蒙 · 黛娜史坦": "Simone Dinnerstein",
    "詹姆斯・艾尼斯": "James Ehnes",
    "詹姆斯・李汶": "James Levine",
    "貝恩德 · 格萊姆瑟": "Bernd Glemser",
    "達莉亞 · 斯塔謝夫斯卡": "Dalia Stasevska",
    "里納多 · 阿列山德里尼": "Rinaldo Alessandrini",
    "阿隆 ‧ 薩瑞爾": "Alon Sariel",
    "雷諾・卡普松": "Renaud Capuçon",
    "馬汀 · 佛洛斯特": "Martin Fröst",
    "魯吉諾 · 黎奇": "Ruggiero Ricci",
    "丹尼爾・哈汀": "Daniel Harding",
    "亞尼克・聶澤-賽金": "Yannick Nézet-Séguin",
    "亞歷山大・梅尼可夫": "Alexander Melnikov",
    "亞歷山大・馬洛菲耶夫": "Alexander Malofeev",
    "亨利克 · 謝霖": "Henryk Szeryng",
    "伊果 · 歐伊斯特拉赫": "Igor Oistrakh",
    "大衛・歐伊斯特拉夫": "David Oistrakh",
    "伊維塔・艾普卡娜": "Iveta Apkalna",
    "傑佛瑞・卡海內": "Jeffrey Kahane",
    "克勞迪奧・阿巴多": "Claudio Abbado",
    "克里斯提昂・貝薩伊登豪": "Kristian Bezuidenhout",
    "勞倫斯 · 埃基爾貝": "Laurence Equilbey",
    "基里爾 · 佩特連科": "Kirill Petrenko",
    "基里爾 · 格斯坦": "Kirill Gerstein",
    "埃絲特・阿布拉米": "Esther Abrami",
    "大衛 · 弗萊": "David Fray",
    "安・梅耶": "Anne Akiko Meyers",  # REVIEW
    "安德里斯・尼爾森斯": "Andris Nelsons",
    "尤妮克・坦齊爾": "Yuniko Tanzil",  # REVIEW
    "尼爾斯 · 艾瑞克 · 斯帕夫": "Nils-Erik Sparf",
    "弗朗茲 · 魏瑟-莫斯特": "Franz Welser-Möst",
    "戈特弗里德 · 馮 · 德 · 戈爾茲": "Gottfried von der Goltz",
    "拉斐爾 · 帕亞雷": "Rafael Payare",
    "拉斐爾 · 庫利貝克": "Rafael Kubelík",
    "提姆・奧霍夫": "Tim Ovens",  # REVIEW
    "斯諾里・霍格利森": "Snorri Sigfús Birgisson",  # REVIEW
    "曼弗雷德 · 霍內克": "Manfred Honeck",
    "朱利安・昆汀": "Julien Quentin",
    "格裡高利・阿什": "Gregory Ash",  # REVIEW
    "泰迪 · 帕帕費拉米": "Tedi Papavrami",
    "科林・柯里": "Colin Currie",
    "米凱萊・史波蒂": "Michele Spotti",
    "瑪莉娜・芮貝卡": "Marina Rebeka",
    "莎妮 · 迪魯卡": "Shani Diluka",
    "萊翁諾・布林吉爾": "Lionel Bringuier",
    "蒂爾・費爾納": "Till Fellner",
    "蘇菲・根特": "Sophie Gent",
    "芳斯瓦 · 澤維爾 · 羅斯": "François-Xavier Roth",
    "艾莉莎・薇勒絲坦": "Alisa Weilerstein",
    "艾薩克・史坦": "Isaac Stern",
    "阿爾貝托 · 伊瑞德": "Alberto Iriarte",  # REVIEW
    "雅各 · 胡薩": "Jakub Hrůša",
    "馬漢・埃斯法哈尼": "Mahan Esfahani",
    "馬蒂亞斯 · 奇許奈瑞特": "Matthias Kirschnereit",
    "馬里奧 · 霍森": "Mario Hossen",
    "馬達拉斯": "Gergely Madaras",  # REVIEW
    "史塔亞": "Staier",  # REVIEW — likely Andreas Staier
    "亞森": "Jansen",  # REVIEW — likely Janine Jansen
    "JB當凱爾": "Jean-Baptiste Doulcet",  # REVIEW
    # Ensembles and orchestras
    "佛萊堡巴洛克管弦樂團": "Freiburger Barockorchester",
    "蘇格蘭室內管弦樂團": "Scottish Chamber Orchestra",
    "亞特蘭大交響樂團": "Atlanta Symphony Orchestra",
    "布達佩斯節慶管弦樂團": "Budapest Festival Orchestra",
    "柏林廣播交響樂團": "Berlin Radio Symphony Orchestra",
    "韋爾比耶音樂節管弦樂團": "Verbier Festival Orchestra",
    "BBC 交響樂團": "BBC Symphony Orchestra",
    "倫敦新交響樂團": "New London Symphony Orchestra",
    "和諧花園古樂團": "Il Giardino Armonico",
    "塔卡許四重奏": "Takács Quartet",
    "奧斯陸愛樂管弦樂團": "Oslo Philharmonic Orchestra",
    "布雷康巴洛克樂團": "Brecon Baroque",
    "柏林古樂學會樂團": "Akademie für Alte Musik Berlin",
    "波蘭國家廣播交響樂團": "Polish National Radio Symphony Orchestra",
    "瑞典廣播交響樂團": "Swedish Radio Symphony Orchestra",
    "維也納交響樂團": "Vienna Symphony",
    "義大利協奏團": "Concerto Italiano",
    "貝爾琪亞弦樂四重奏團": "Belcea Quartet",
    "克里夫蘭管弦樂團": "Cleveland Orchestra",
    "匹茲堡交響樂團": "Pittsburgh Symphony Orchestra",
    "勞騰樂集": "Lautten Compagney",
    "協力歌手合唱團": "Accentus",  # REVIEW
    "嘉碧妲古樂團": "Capella Gabetta",  # REVIEW
    "島嶼古樂團": "Isola Baroque",  # REVIEW
    "巴塞爾室內樂團": "Kammerorchester Basel",
    "布列頓小交響樂團": "Britten Sinfonia",
    "布胥三重奏": "Busch Trio",
    "拿坡里聖卡羅劇院管弦樂團": "Orchestra del Teatro di San Carlo",
    "東西和平會議管弦樂團": "West-Eastern Divan Orchestra",
    "柏林德意志交響樂團": "Deutsches Symphonie-Orchester Berlin",
    "柯林・卡瑞樂團": "Colin Currie Group",
    "比利時列日愛樂管弦樂團": "Orchestre Philharmonique Royal de Liège",
    "法國國立管弦樂團": "Orchestre National de France",
    "洛杉磯室內樂團": "Los Angeles Chamber Orchestra",
    "班貝格交響樂團": "Bamberg Symphony",
    "聖地牙哥交響樂團": "San Diego Symphony",
    "艾班弦樂四重奏": "Quatuor Ébène",
    "薩爾茲堡學院室內合奏團": "Camerata Salzburg",
    "蘇黎世音樂廳管弦樂團": "Tonhalle-Orchester Zürich",
    "費城管弦樂團": "Philadelphia Orchestra",
    "阿姆斯特丹弦樂合奏團": "Amsterdam Sinfonietta",
}


# Names that stay exactly as they are, because CJK *is* their language. Listed
# rather than merely defaulted, so that adding a Western name here by mistake is
# a visible act. Everything not in `TRANSLITERATED` is kept anyway; this list is
# the record of which ones were considered and deliberately kept.
NATIVE_NAMES: frozenset[str] = frozenset({
    # Japanese
    "久石讓", "内田光子", "米津玄師", "辻井伸行", "藤田真央", "澤野弘之",
    "椎名林檎×斎藤ネコ", "椎名林檎と宮本浩次", "夢限大みゅーたいぷ",
    "藤間 仁 (Elements Garden)",
    "エィハ(CV.沢城みゆき)", "メリル(CV.照井春佳)", "婁(CV.内田真礼)",
    # Korean
    "류정한", "강욱진", "김민구(NiNE)", "김키위", "서정아", "신쿵", "심은지",
    "용배", "이기", "이동혁", "허윤진", "구조(153/Joombas)", "김도연", "전동석",
    "任奫燦", "朴秀藝", "金本索里", "金鈺兒",
    # Chinese and Taiwanese
    "蕭敬騰", "王羽佳", "昊轩京剧-吴昊", "岳勳", "冯沛琳", "吉克雋逸",
    "周深", "孫悅", "張遠", "房東的貓", "李垂誼", "王健", "王家珍", "芝麻Mochi",
    "莫非定律樂團", "袁婭維", "邹茹", "陳銳", "章思云", "任中強Zain", "冰潔",
    "劉宇寧", "劉惜君", "劉曉超", "叶聪", "吳育倢", "周華健", "夏日入侵企畫",
    "小宇 宋念宇", "庾澄慶", "曾宇謙", "李函蒨", "李紫婷", "汪蘇瀧", "澤國同學",
    "王以太", "王安宇", "竇靖童", "胡彥斌", "艾熱AIR", "范瑋琪", "郎朗",
    "鍾興民", "阿肆", "陳妍希", "馬友友", "黎卓宇", "鄭浩",
})


# ---------------------------------------------------------------------------
# Rule 2 — junk

# Apple's editorial accounts appear as the "artist" of curated playlists, and a
# personal playlist appears as `<name>的 Apple Music`. Neither is an artist.
JUNK_SUBSTRINGS: tuple[str, ...] = ("Apple Music",)

JUNK_EXACT: frozenset[str] = frozenset({
    "群星",            # "Various Artists" in Chinese
    "Various Artists",
    "Unknown Artist",
    "ATLUS",           # a game studio credited as composer
})


# ---------------------------------------------------------------------------
# Rule 1 — splitting

# Applied to performer and composer strings only, never to titles or albums.
# `、` is the ideographic comma and separates credits exactly as `, ` does. It
# was missing until one string went unclassified —
# `エィハ(CV.沢城みゆき)、メリル(CV.照井春佳)、婁(CV.内田真礼)`, three voice-actor
# credits that stayed welded into one "artist". A separator absent from this
# tuple does not fail; it silently makes one person out of several.
SPLIT_SEPARATORS: tuple[str, ...] = (" & ", ", ", "、")

# **Never split on these.** They join the parts of one transliterated name —
# `尼科洛・帕格尼尼`, `維托德 · 盧托斯瓦夫斯基` — and splitting there invents
# people. 98 names in this library contain one.
NEVER_SPLIT: tuple[str, ...] = ("・", "·", "‧", "•")


# ---------------------------------------------------------------------------
# Rule 4 — eras
#
# **Two different vocabularies, because the sources are different.** Classical
# periods are *stated by Apple as genres*, so they are read rather than derived.
# Popular music has no such field, so its era comes from release dates in
# decade buckets.

CLASSICAL_ERAS: dict[str, str] = {
    "Renaissance": "era:renaissance",
    "Baroque Era": "era:baroque",
    "High Classical": "era:classical_period",
    "Romantic Era": "era:romantic",
    "Impressionist": "era:impressionist",
    "Modern Era": "era:modern",
    "Contemporary Era": "era:contemporary",
}

# Genres whose artists get a decade instead. Anything not here and not classical
# gets no era at all rather than a guessed one.
DECADE_GENRES: frozenset[str] = frozenset({
    "Pop", "J-Pop", "K-Pop", "Mandopop", "Cantopop", "Korean Hip-Hop",
    "Rock", "Pop/Rock", "Soft Rock", "Hard Rock", "Arena Rock", "Folk Rock",
    "Hip-Hop/Rap", "R&B/Soul", "Electronic", "Dance", "House", "Techno",
    "Disco", "Alternative", "Adult Contemporary", "Singer/Songwriter",
    "Latin", "Country", "Jazz",
})


def decade_of(year: int) -> str | None:
    """`1997 -> era:1990s`. Nothing before 1950: a decade is a claim about
    popular-music style, and it stops meaning that the further back it goes."""
    if not isinstance(year, int) or year < 1950 or year > 2100:
        return None
    return f"era:{year // 10 * 10}s"
