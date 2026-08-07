import Foundation

/// Calendar titles that are withheld from the profile because of what they
/// reveal, rather than because they are dull.
///
/// **Not the same judgement as `ListeningHighlights.isRoutine`, and the two are
/// deliberately kept apart.** That one drops birthdays, meetings and public
/// holidays because nobody recognises their year in a fortnightly Zoom — a
/// reading. This one withholds a health status and a political affiliation,
/// which are protected characteristics. `Ontology.refusedTopics` refuses the
/// same two arriving as YouTube content tags; a calendar carrying "Oncology
/// follow-up" into Postgres and on to the ontology is that exposure through a
/// different door.
///
/// **Marked, never dropped.** `DistillViewModel.applyingBans` annotates the row
/// and keeps it, so the extraction rule still holds: a field dropped at the
/// parse cannot be recovered without re-distilling everybody, and this decision
/// is one somebody may want to revisit.
///
/// Its own file for the reason `PublicHolidays` has one — it is a vocabulary
/// rather than a rule, and no structural test could stand in for it. A medical
/// appointment and a lunch are identical in shape: both are short, both are in
/// an ordinary calendar, and only the words differ.
enum SensitiveEvents {

    enum Kind: String {
        case medical  = "sensitive_medical"
        case political = "sensitive_political"
    }

    /// Which kind a title trips, or `nil`.
    static func kind(of title: String) -> Kind? {
        let name = title.lowercased()
        if medical.contains(where: name.contains) { return .medical }
        if political.contains(where: name.contains) { return .political }
        return nil
    }

    // MARK: - What is deliberately absent

    /// **The rejected tokens matter more than the accepted ones**, because the
    /// failure that costs something here is a real plan going quiet — not a
    /// medical appointment slipping through. `PublicHolidays` states the same
    /// trade: losing somebody's trip costs more than showing them Karneval.
    ///
    /// Left out, each for a reason worth keeping:
    ///
    /// - `party` — "birthday party", "dinner party", "leaving party"
    /// - `vote` — a substring of *devote* and *devotee*
    /// - `congress` — academic congresses are ordinary diary entries
    /// - `demonstration` — product demonstrations
    /// - `rally`, `march` alone — car rallies, and March the month
    /// - `wahl` — a substring of German *Auswahl*, meaning selection
    /// - `检查` / `檢查` — inspection in general, not only medical
    /// - `test` alone — `blood test` and `smear test` are in; `test` is not
    /// - `doctor` alone — *Doctor Who*, and "Doctor" as a title
    ///
    /// **Incomplete by construction**, and that is the design rather than an
    /// apology. Twelve languages is not every language, and a list broad enough
    /// to catch them all would be broad enough to swallow real plans.
    private static let rejected = "documented above; do not add these"

    // MARK: - Medical

    private static let medical: [String] = [
        // — English
        "dentist", "dental", "orthodont", "hygienist",
        "doctor's appointment", "doctors appointment", "gp appointment",
        "clinic", "hospital", "outpatient", "inpatient", "a&e",
        "emergency room", "urgent care", "surgery", "operation theatre",
        "oncolog", "chemo", "radiotherapy", "dialysis", "biopsy",
        "physiotherapy", "physio", "rehab",
        "vaccination", "vaccine", "immunisation", "immunization", "booster shot",
        "blood test", "blood work", "x-ray", "mri", "ct scan", "ultrasound",
        "colonoscopy", "endoscopy", "mammogram", "smear test", "pap smear",
        "prescription", "pharmacy", "optometrist", "optician", "eye exam",
        "hearing test", "audiolog",
        "therapist", "therapy session", "psychiatr", "psycholog",
        "counselling", "counseling",
        "midwife", "antenatal", "prenatal", "fertility", "ivf",
        "gynaecolog", "gynecolog", "obgyn", "dermatolog", "cardiolog",
        "neurolog", "orthopaed", "orthoped", "paediatric", "pediatric",
        "podiatr", "urolog", "check-up", "checkup",

        // — Chinese, both scripts
        "醫生", "医生", "睇醫生", "看医生", "牙醫", "牙医", "洗牙",
        "診所", "诊所", "醫院", "医院", "門診", "门诊", "複診", "复诊", "覆診",
        "體檢", "体检", "疫苗", "打針", "打针", "手術", "手术",
        "化療", "化疗", "藥房", "药房", "配藥", "配药",
        "物理治療", "物理治疗", "心理", "精神科", "產檢", "产检", "婦科", "妇科",

        // — Spanish
        "médico", "medico", "dentista", "clínica", "clinica", "cita médica",
        "vacuna", "quirófano", "fisioterapia", "psicólogo", "psiquiatra",
        "análisis de sangre",

        // — French
        "médecin", "medecin", "dentiste", "hôpital", "hopital", "clinique",
        "rendez-vous médical", "vaccin", "kinésithérapie", "kiné",
        "psychologue", "psychiatre", "ophtalmo", "analyse de sang",

        // — German
        "arzt", "ärztin", "zahnarzt", "krankenhaus", "klinik", "impfung",
        "physiotherapie", "psychiater", "psychologe", "blutabnahme", "vorsorge",

        // — Italian
        "medico", "dentista", "ospedale", "visita medica", "vaccino",
        "fisioterapia", "psicologo", "analisi del sangue",

        // — Portuguese
        "dentista", "hospital", "vacina", "fisioterapia", "psicólogo",
        "exame de sangue", "consulta médica",

        // — Japanese
        "病院", "医院", "歯医者", "歯科", "診察", "検診", "健診",
        "予防接種", "通院", "内科", "外科", "皮膚科", "眼科", "耳鼻科",
        "心療内科", "薬局",

        // — Korean
        "병원", "치과", "진료", "검진", "예방접종", "약국", "한의원",
        "정신과", "피부과", "안과",

        // — Russian
        "врач", "больница", "поликлиника", "стоматолог", "прививка",
        "анализ крови", "терапевт",

        // — Arabic
        "طبيب", "مستشفى", "عيادة", "أسنان", "تطعيم",

        // — Hindi
        "डॉक्टर", "अस्पताल", "दंत", "टीका",
    ]

    // MARK: - Political

    private static let political: [String] = [
        // — English. Narrower than the medical list on purpose: political
        //   vocabulary overlaps ordinary life far more ("party", "march",
        //   "campaign"), so only the unambiguous survive.
        "election", "referendum", "caucus", "hustings",
        "polling station", "polling place", "ballot", "canvassing",
        "political", "politics", "parliament", "senate", "constituency",
        "party conference", "campaign rally", "town hall meeting",
        "picket line", "protest march",

        // — Chinese, both scripts
        "選舉", "选举", "投票", "公投", "政治", "議會", "议会",
        "立法會", "立法会", "遊行", "游行", "示威",

        // — Spanish
        "elección", "elecciones", "referéndum", "política", "mitin",
        "manifestación",

        // — French
        "élection", "elections", "scrutin", "référendum", "politique",
        "manifestation",

        // — German. `wahl` alone is out — see `rejected`.
        "wahlkampf", "wahllokal", "bundestagswahl", "abstimmung", "politik",

        // — Italian
        "elezioni", "referendum", "politica", "comizio",

        // — Portuguese
        "eleição", "eleições", "votação", "política", "manifestação",

        // — Japanese
        "選挙", "投票", "政治", "国会",

        // — Korean
        "선거", "투표", "정치", "국회", "시위",

        // — Russian
        "выборы", "голосование", "политика", "митинг",

        // — Arabic
        "انتخابات", "تصويت", "سياسة",

        // — Hindi
        "चुनाव", "मतदान", "राजनीति",
    ]
}
