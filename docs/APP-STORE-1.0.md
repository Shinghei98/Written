# Written 1.0 — App Store Connect draft

Everything here is to be pasted into App Store Connect. Character limits are
Apple's; counts are given where a field is limited. **Bracketed items are
decisions or facts still owed.**

App: **Written** · bundle `com.written.datingapp` · version 1.0 (build 58) ·
iOS 16.0+ · iPhone only

---

## 1. App information

| Field | Value |
|---|---|
| Name (30) | Written |
| Subtitle (30) | Dating, written by your taste |
| Primary category | Lifestyle |
| Secondary category | Social Networking |
| Privacy Policy URL | https://written-stl.com/en-us/privacy/ |
| Support URL | https://written-stl.com/en-us/support/ |
| Marketing URL (optional) | https://written-stl.com/en-us/ |
| Copyright | 2026 Shing Hei Mok |
| Content rights | Does not contain third-party content you lack rights to. Shared YouTube videos play through YouTube's own embedded player. |

Lifestyle rather than Social Networking as primary is the usual choice for
dating apps and is where people browse for them; swap if you prefer.

## 2. Version page

### Promotional text (170)

> Stop writing bios. Connect the music, plans and podcasts you already love,
> and Written grows a profile that sounds like you.

### Description (4000)

> Dating profiles ask you to describe yourself in three prompts and a joke.
> Written does it the other way round: it reads what you already love and
> writes your profile from it.
>
> GROW YOUR PROFILE
> Connect Apple Music, Apple Podcasts, your calendar and Apple Health — one
> tap each, no passwords. Written turns your listening, your plans and the
> way you move into a profile that is unmistakably yours. Every connection
> nourishes it into something more specific.
>
> A BIO THAT CHANGES WITH WHO IS READING
> Your profile is not one fixed paragraph. When someone who shares your love
> of a band, a show or a sport opens it, that is what they see first. The
> common ground comes forward on its own.
>
> YOU DECIDE WHAT STAYS
> Everything Written finds is listed in Memories. Strike out anything you
> would rather not show, and it is never used again. Disconnect a source,
> download your data, or delete your account from inside the app at any
> time.
>
> MEET PEOPLE NEAR YOU
> Explore real people in your city, see what you have in common, and send a
> like — or a like with a note. When it is mutual, the conversation opens
> with something you both care about.
>
> SAFE BY DESIGN
> Report or block anyone in two taps; blocking is invisible to the other
> person. Reports are reviewed within 24 hours. Written is for adults 18 and
> over.
>
> PRIVATE BY DEFAULT
> No ads, no analytics, no tracking, and your data is never sold. Read
> exactly what Written collects and why at written-stl.com/en-us/privacy.

### Keywords (100, comma-separated, no spaces)

```
dating,date,match,singles,relationship,music,playlist,podcast,meet,romance,profile,chat,taste
```

### What's New

First version — nothing to fill in.

### Screenshots

6.9-inch display (1320 × 2868 portrait) is the only required size; Apple
scales it down for the rest. 3 to 10 of them. Chosen, in upload order, all
real device captures of build 57 at exactly that size:

1. `~/Downloads/IMG_0825.PNG` — Explore, mid-scroll across three profiles
2. `~/Downloads/IMG_0826.PNG` — Grow your profile
3. `~/Downloads/IMG_0827.PNG` — Memories
4. `~/Downloads/IMG_0829.PNG` — a chat opened by the Jay Chou tip

Unframed — App Store screenshots must not carry a drawn device frame.

## 3. Age rating

Answer the questionnaire so it lands on **18+**:

| Question | Answer |
|---|---|
| Mature or suggestive themes | Infrequent / mild |
| Sexual content or nudity | None |
| Profanity or crude humor | None (users can write anything; covered by UGC below) |
| User-generated content | **Yes** |
| Messaging and chat | **Yes** |
| Unrestricted web access | No |
| Gambling, contests, alcohol/drugs, violence, horror | None |
| Age assurance / restricted to adults | Yes — the app refuses anyone under 18 at the birthday step |

If the questionnaire computes something lower, raise it to 18+ manually: a
dating app below 18+ is a rejection under 1.1/5.1.

## 4. App Privacy ("nutrition label")

Every type: **linked to the user · not used for tracking · purpose App
Functionality only.** This must agree with `Written/PrivacyInfo.xcprivacy`
and the privacy page; each row below names the manifest key it matches.

| App Store category → type | Manifest key | What it is |
|---|---|---|
| Contact Info → Name | `Name` | first name; name from Apple/Google sign-in |
| Contact Info → Email Address | `EmailAddress` | Apple/Google sign-in |
| Contact Info → Phone Number | `PhoneNumber` | phone sign-in |
| Contacts | `Contacts` | names imported for "people you know can't see you" |
| User Content → Photos or Videos | `PhotosorVideos` | profile photos, chat attachments |
| User Content → Audio Data | `AudioData` | voice messages |
| User Content → Emails or Text Messages | `EmailsOrTextMessages` | in-app chat |
| Identifiers → User ID | `UserID` | account id |
| Location → Coarse Location | `CoarseLocation` | district |
| Health & Fitness → Fitness | `Fitness` | workouts, steps, activity totals from Apple Health |
| Usage Data → Other Usage Data | `OtherUsageData` | likes, strikes, saved profiles |
| Other Data → Other Data Types | `OtherDataTypes` | date of birth, gender, music library, podcasts, calendar events |
| Sensitive Info | `SensitiveInfo` | who you would like to meet — with gender, indicates sexual orientation |

Sensitive Info declared (owner, 2026-11-05); the manifest and the privacy
page name it too.

Not collected, answer "No": Financial Info, Purchases, Search History,
Browsing History, Diagnostics (there is no crash or analytics SDK), Precise
Location, Health (clinical data — Apple Health biological sex never leaves
the phone).

## 5. App Review information

**Sign-in required: yes.** Demo account:

- **User name:** [ten national digits of the test number, e.g. 5555550123 —
  *not* +1 and not 11 digits; a leading 1 is silently truncated and the code
  goes to a real stranger's number]
- **Password:** [the fixed code from `SMS_TEST_OTP`]

**Contact:** Shing Hei Mok · +1 314-912-5096 · davidmok98@hotmail.com

### Notes (4000)

> Written is a dating app for adults 18+.
>
> HOW TO SIGN IN
> Accounts are created with a phone number only. Please tap "Create
> account", choose the phone option and enter the number in the user name
> field above. No SMS is sent — it is a test number, and the code is the
> password field above. "Sign in with Apple" and "Sign in with Google" only
> sign in to accounts that already have a phone number attached, so they
> will show "no account" for a reviewer; this is expected.
>
> During sign-up you will be asked your birthday (any date 18+ years ago),
> name, gender, who you want to meet, two communication preferences and
> photos (optional).
>
> CONNECTING DATA
> On the "Grow your profile" screen each source is one tap and uses the
> standard iOS permission sheet: Apple Music (needs an Apple Music
> subscription on the device), Apple Podcasts, Apple Calendar, Apple Health.
> Outlook Calendar uses Microsoft sign-in and is optional. All access is
> read-only. Nothing runs in the background.
>
> Apple Health: we read workouts, steps, exercise minutes, active energy and
> walking/running distance to describe how active someone is. Health data is
> never used for advertising and never shown to other users; biological sex
> is read on the device and refused before upload.
>
> SAFETY (Guideline 1.2)
> Report and block are available from every profile (the "…" menu in
> Explore) and every conversation (swipe in the Chat list). Reporting also
> blocks. Reports reach us by email and are acted on within 24 hours;
> upheld reports remove the content and the account. Contact:
> hello@written-stl.com.
>
> ACCOUNT DELETION (Guideline 5.1.1(v))
> Memories tab → Settings → Delete account. It deletes the account and all
> its data.
>
> PRIVACY
> No advertising, analytics or tracking SDKs. Policy:
> https://written-stl.com/en-us/privacy/

## 6. Before pressing Submit

- [ ] **Test phone number in Supabase** — Auth → Phone → test numbers;
      set `SMS_TEST_OTP` and `SMS_TEST_OTP_VALID_UNTIL` past the review
      window. Sign up with it yourself once to prove it works. Remove it
      after approval.
- [ ] **Explore must not be empty for the reviewer.** `discover_profiles`
      filters on mutual eligibility, and NEXT-STEPS records production users
      correctly seeing nobody. A reviewer who finds an empty feed reads a
      broken app (2.1). Make sure enough real or clearly-test profiles exist
      that fit whatever gender/interest the reviewer picks — or say in the
      notes which answers show profiles.
- [ ] Archive (Release), check in the archive: PlugIns contains
      `ShareToWritten` and `NotificationService`, `MinimumOSVersion` 16.0,
      `DTSDKName` iOS 26 or later.
- [ ] Organizer → Distribute App → **App Store Connect** (not "TestFlight
      Internal Only").
- [ ] Attach build 58 to the version (not 57 — it carries an unreleased logo), fill §1–5, submit.
