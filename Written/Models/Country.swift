import Foundation

/// A dialling destination for the phone-number step.
///
/// Only the ISO code and the dial code are stored: the display name comes from
/// the OS so it follows the user's language ("Germany" / "Deutschland"), and the
/// flag is derived from the ISO code, so no emoji are hard-coded.
struct Country: Identifiable, Equatable {
    /// ISO 3166-1 alpha-2.
    let isoCode: String
    /// E.164 country calling code, including the leading "+".
    let dialCode: String
    /// Used only when the OS has no localized name for the region.
    let englishName: String

    init(_ isoCode: String, _ dialCode: String, _ englishName: String) {
        self.isoCode = isoCode
        self.dialCode = dialCode
        self.englishName = englishName
    }

    var id: String { isoCode }

    var name: String {
        Locale.current.localizedString(forRegionCode: isoCode) ?? englishName
    }

    /// Regional indicator symbols: "US" becomes the two letters that render as
    /// the flag. No image assets, and unknown codes simply render as letters.
    var flag: String {
        let base: UInt32 = 0x1F1E6
        return isoCode.uppercased().unicodeScalars.reduce(into: "") { result, scalar in
            guard let indicator = UnicodeScalar(base + scalar.value - 65) else { return }
            result.unicodeScalars.append(indicator)
        }
    }

    /// Spaced grouping for read-back ("Sent to 314 912 5096"), where the
    /// parentheses of the entry format would read as clutter.
    func displayNationalNumber(_ digits: String) -> String {
        guard dialCode == "+1", digits.count == 10 else { return digits }
        let characters = Array(digits)
        return "\(String(characters[0..<3])) \(String(characters[3..<6])) \(String(characters[6..<10]))"
    }

    /// A length check, not a real validation: NANP numbers are exactly ten
    /// digits, and elsewhere national numbers run from four (Niue, Tokelau) to
    /// fourteen. Deliberately permissive — rejecting a real subscriber is worse
    /// than passing a bad number to the verification service, which is what will
    /// actually decide.
    func isValidNationalNumber(_ digits: String) -> Bool {
        dialCode == "+1" ? digits.count == 10 : (4...14).contains(digits.count)
    }

    /// Only +1 has a grouping worth imposing; everywhere else the user's own
    /// spacing is left alone rather than guessed at wrongly.
    func format(_ input: String) -> String {
        let digits = String(input.filter(\.isNumber).prefix(dialCode == "+1" ? 10 : 15))
        guard dialCode == "+1" else { return digits }

        switch digits.count {
        case 0...3:
            return digits
        case 4...6:
            let area = digits.prefix(3)
            return "(\(area)) \(digits.dropFirst(3))"
        default:
            let area = digits.prefix(3)
            let middle = digits.dropFirst(3).prefix(3)
            return "(\(area)) \(middle)-\(digits.dropFirst(6))"
        }
    }
}

extension Country {
    static let unitedStates = Country("US", "+1", "United States")

    /// Surfaced above the alphabetical list, as in the reference design.
    static let featured: [Country] = ["US", "AU", "CA", "GB"].compactMap { code in
        all.first { $0.isoCode == code }
    }

    /// Everything except the featured four, in the user's collation order.
    static let alphabetical: [Country] = {
        let featuredCodes = Set(featured.map(\.isoCode))
        return all
            .filter { !featuredCodes.contains($0.isoCode) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }()

    /// Every country with a calling code, from the ISO 3166 / E.164 tables.
    /// Antarctica and Heard & McDonald Islands are absent: they have no code.
    ///
    /// Territories sharing a neighbour's calling code carry that code, not the
    /// code plus their area prefix — the user types the area code themselves,
    /// so the Aland Islands are +358, not +358 18.
    static let all: [Country] = [
        Country("AF", "+93", "Afghanistan"),
        Country("AL", "+355", "Albania"),
        Country("DZ", "+213", "Algeria"),
        Country("AS", "+1", "American Samoa"),
        Country("AD", "+376", "Andorra"),
        Country("AO", "+244", "Angola"),
        Country("AI", "+1", "Anguilla"),
        Country("AG", "+1", "Antigua and Barbuda"),
        Country("AR", "+54", "Argentina"),
        Country("AM", "+374", "Armenia"),
        Country("AW", "+297", "Aruba"),
        Country("AU", "+61", "Australia"),
        Country("AT", "+43", "Austria"),
        Country("AZ", "+994", "Azerbaijan"),
        Country("BS", "+1", "Bahamas"),
        Country("BH", "+973", "Bahrain"),
        Country("BD", "+880", "Bangladesh"),
        Country("BB", "+1", "Barbados"),
        Country("BY", "+375", "Belarus"),
        Country("BE", "+32", "Belgium"),
        Country("BZ", "+501", "Belize"),
        Country("BJ", "+229", "Benin"),
        Country("BM", "+1", "Bermuda"),
        Country("BT", "+975", "Bhutan"),
        Country("BO", "+591", "Bolivia"),
        Country("BA", "+387", "Bosnia and Herzegovina"),
        Country("BW", "+267", "Botswana"),
        Country("BV", "+47", "Bouvet Island"),
        Country("BR", "+55", "Brazil"),
        Country("IO", "+246", "British Indian Ocean Territory"),
        Country("VG", "+1", "British Virgin Islands"),
        Country("BN", "+673", "Brunei"),
        Country("BG", "+359", "Bulgaria"),
        Country("BF", "+226", "Burkina Faso"),
        Country("BI", "+257", "Burundi"),
        Country("KH", "+855", "Cambodia"),
        Country("CM", "+237", "Cameroon"),
        Country("CA", "+1", "Canada"),
        Country("CV", "+238", "Cape Verde"),
        Country("BQ", "+599", "Caribbean Netherlands"),
        Country("KY", "+1", "Cayman Islands"),
        Country("CF", "+236", "Central African Republic"),
        Country("TD", "+235", "Chad"),
        Country("CL", "+56", "Chile"),
        Country("CN", "+86", "China"),
        Country("CX", "+61", "Christmas Island"),
        Country("CC", "+61", "Cocos (Keeling) Islands"),
        Country("CO", "+57", "Colombia"),
        Country("KM", "+269", "Comoros"),
        Country("CG", "+242", "Congo"),
        Country("CK", "+682", "Cook Islands"),
        Country("CR", "+506", "Costa Rica"),
        Country("HR", "+385", "Croatia"),
        Country("CU", "+53", "Cuba"),
        Country("CW", "+599", "Curaçao"),
        Country("CY", "+357", "Cyprus"),
        Country("CZ", "+420", "Czechia"),
        Country("CD", "+243", "DR Congo"),
        Country("DK", "+45", "Denmark"),
        Country("DJ", "+253", "Djibouti"),
        Country("DM", "+1", "Dominica"),
        Country("DO", "+1", "Dominican Republic"),
        Country("EC", "+593", "Ecuador"),
        Country("EG", "+20", "Egypt"),
        Country("SV", "+503", "El Salvador"),
        Country("GQ", "+240", "Equatorial Guinea"),
        Country("ER", "+291", "Eritrea"),
        Country("EE", "+372", "Estonia"),
        Country("SZ", "+268", "Eswatini"),
        Country("ET", "+251", "Ethiopia"),
        Country("FK", "+500", "Falkland Islands"),
        Country("FO", "+298", "Faroe Islands"),
        Country("FJ", "+679", "Fiji"),
        Country("FI", "+358", "Finland"),
        Country("FR", "+33", "France"),
        Country("GF", "+594", "French Guiana"),
        Country("PF", "+689", "French Polynesia"),
        Country("TF", "+262", "French Southern and Antarctic Lands"),
        Country("GA", "+241", "Gabon"),
        Country("GM", "+220", "Gambia"),
        Country("GE", "+995", "Georgia"),
        Country("DE", "+49", "Germany"),
        Country("GH", "+233", "Ghana"),
        Country("GI", "+350", "Gibraltar"),
        Country("GR", "+30", "Greece"),
        Country("GL", "+299", "Greenland"),
        Country("GD", "+1", "Grenada"),
        Country("GP", "+590", "Guadeloupe"),
        Country("GU", "+1", "Guam"),
        Country("GT", "+502", "Guatemala"),
        Country("GG", "+44", "Guernsey"),
        Country("GN", "+224", "Guinea"),
        Country("GW", "+245", "Guinea-Bissau"),
        Country("GY", "+592", "Guyana"),
        Country("HT", "+509", "Haiti"),
        Country("HN", "+504", "Honduras"),
        Country("HK", "+852", "Hong Kong"),
        Country("HU", "+36", "Hungary"),
        Country("IS", "+354", "Iceland"),
        Country("IN", "+91", "India"),
        Country("ID", "+62", "Indonesia"),
        Country("IR", "+98", "Iran"),
        Country("IQ", "+964", "Iraq"),
        Country("IE", "+353", "Ireland"),
        Country("IM", "+44", "Isle of Man"),
        Country("IL", "+972", "Israel"),
        Country("IT", "+39", "Italy"),
        Country("CI", "+225", "Ivory Coast"),
        Country("JM", "+1", "Jamaica"),
        Country("JP", "+81", "Japan"),
        Country("JE", "+44", "Jersey"),
        Country("JO", "+962", "Jordan"),
        Country("KZ", "+7", "Kazakhstan"),
        Country("KE", "+254", "Kenya"),
        Country("KI", "+686", "Kiribati"),
        Country("XK", "+383", "Kosovo"),
        Country("KW", "+965", "Kuwait"),
        Country("KG", "+996", "Kyrgyzstan"),
        Country("LA", "+856", "Laos"),
        Country("LV", "+371", "Latvia"),
        Country("LB", "+961", "Lebanon"),
        Country("LS", "+266", "Lesotho"),
        Country("LR", "+231", "Liberia"),
        Country("LY", "+218", "Libya"),
        Country("LI", "+423", "Liechtenstein"),
        Country("LT", "+370", "Lithuania"),
        Country("LU", "+352", "Luxembourg"),
        Country("MO", "+853", "Macau"),
        Country("MG", "+261", "Madagascar"),
        Country("MW", "+265", "Malawi"),
        Country("MY", "+60", "Malaysia"),
        Country("MV", "+960", "Maldives"),
        Country("ML", "+223", "Mali"),
        Country("MT", "+356", "Malta"),
        Country("MH", "+692", "Marshall Islands"),
        Country("MQ", "+596", "Martinique"),
        Country("MR", "+222", "Mauritania"),
        Country("MU", "+230", "Mauritius"),
        Country("YT", "+262", "Mayotte"),
        Country("MX", "+52", "Mexico"),
        Country("FM", "+691", "Micronesia"),
        Country("MD", "+373", "Moldova"),
        Country("MC", "+377", "Monaco"),
        Country("MN", "+976", "Mongolia"),
        Country("ME", "+382", "Montenegro"),
        Country("MS", "+1", "Montserrat"),
        Country("MA", "+212", "Morocco"),
        Country("MZ", "+258", "Mozambique"),
        Country("MM", "+95", "Myanmar"),
        Country("NA", "+264", "Namibia"),
        Country("NR", "+674", "Nauru"),
        Country("NP", "+977", "Nepal"),
        Country("NL", "+31", "Netherlands"),
        Country("NC", "+687", "New Caledonia"),
        Country("NZ", "+64", "New Zealand"),
        Country("NI", "+505", "Nicaragua"),
        Country("NE", "+227", "Niger"),
        Country("NG", "+234", "Nigeria"),
        Country("NU", "+683", "Niue"),
        Country("NF", "+672", "Norfolk Island"),
        Country("KP", "+850", "North Korea"),
        Country("MK", "+389", "North Macedonia"),
        Country("MP", "+1", "Northern Mariana Islands"),
        Country("NO", "+47", "Norway"),
        Country("OM", "+968", "Oman"),
        Country("PK", "+92", "Pakistan"),
        Country("PW", "+680", "Palau"),
        Country("PS", "+970", "Palestine"),
        Country("PA", "+507", "Panama"),
        Country("PG", "+675", "Papua New Guinea"),
        Country("PY", "+595", "Paraguay"),
        Country("PE", "+51", "Peru"),
        Country("PH", "+63", "Philippines"),
        Country("PN", "+64", "Pitcairn Islands"),
        Country("PL", "+48", "Poland"),
        Country("PT", "+351", "Portugal"),
        Country("PR", "+1", "Puerto Rico"),
        Country("QA", "+974", "Qatar"),
        Country("RO", "+40", "Romania"),
        Country("RU", "+7", "Russia"),
        Country("RW", "+250", "Rwanda"),
        Country("RE", "+262", "Réunion"),
        Country("BL", "+590", "Saint Barthélemy"),
        Country("SH", "+290", "Saint Helena, Ascension and Tristan da Cunha"),
        Country("KN", "+1", "Saint Kitts and Nevis"),
        Country("LC", "+1", "Saint Lucia"),
        Country("MF", "+590", "Saint Martin"),
        Country("PM", "+508", "Saint Pierre and Miquelon"),
        Country("VC", "+1", "Saint Vincent and the Grenadines"),
        Country("WS", "+685", "Samoa"),
        Country("SM", "+378", "San Marino"),
        Country("SA", "+966", "Saudi Arabia"),
        Country("SN", "+221", "Senegal"),
        Country("RS", "+381", "Serbia"),
        Country("SC", "+248", "Seychelles"),
        Country("SL", "+232", "Sierra Leone"),
        Country("SG", "+65", "Singapore"),
        Country("SX", "+1", "Sint Maarten"),
        Country("SK", "+421", "Slovakia"),
        Country("SI", "+386", "Slovenia"),
        Country("SB", "+677", "Solomon Islands"),
        Country("SO", "+252", "Somalia"),
        Country("ZA", "+27", "South Africa"),
        Country("GS", "+500", "South Georgia"),
        Country("KR", "+82", "South Korea"),
        Country("SS", "+211", "South Sudan"),
        Country("ES", "+34", "Spain"),
        Country("LK", "+94", "Sri Lanka"),
        Country("SD", "+249", "Sudan"),
        Country("SR", "+597", "Suriname"),
        Country("SJ", "+47", "Svalbard and Jan Mayen"), // shares Norway's code
        Country("SE", "+46", "Sweden"),
        Country("CH", "+41", "Switzerland"),
        Country("SY", "+963", "Syria"),
        Country("ST", "+239", "São Tomé and Príncipe"),
        Country("TW", "+886", "Taiwan"),
        Country("TJ", "+992", "Tajikistan"),
        Country("TZ", "+255", "Tanzania"),
        Country("TH", "+66", "Thailand"),
        Country("TL", "+670", "Timor-Leste"),
        Country("TG", "+228", "Togo"),
        Country("TK", "+690", "Tokelau"),
        Country("TO", "+676", "Tonga"),
        Country("TT", "+1", "Trinidad and Tobago"),
        Country("TN", "+216", "Tunisia"),
        Country("TM", "+993", "Turkmenistan"),
        Country("TC", "+1", "Turks and Caicos Islands"),
        Country("TV", "+688", "Tuvalu"),
        Country("TR", "+90", "Türkiye"),
        Country("UG", "+256", "Uganda"),
        Country("UA", "+380", "Ukraine"),
        Country("AE", "+971", "United Arab Emirates"),
        Country("GB", "+44", "United Kingdom"),
        Country("US", "+1", "United States"),
        Country("UM", "+268", "United States Minor Outlying Islands"),
        Country("VI", "+1", "United States Virgin Islands"),
        Country("UY", "+598", "Uruguay"),
        Country("UZ", "+998", "Uzbekistan"),
        Country("VU", "+678", "Vanuatu"),
        Country("VA", "+39", "Vatican City"), // shares Italy's code
        Country("VE", "+58", "Venezuela"),
        Country("VN", "+84", "Vietnam"),
        Country("WF", "+681", "Wallis and Futuna"),
        Country("EH", "+212", "Western Sahara"), // shares Morocco's code
        Country("YE", "+967", "Yemen"),
        Country("ZM", "+260", "Zambia"),
        Country("ZW", "+263", "Zimbabwe"),
        Country("AX", "+358", "Åland Islands") // shares Finland's code
    ]
}
