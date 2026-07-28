import Foundation

/// Whose data the on-device stores are reading and writing.
///
/// Everything this device remembers — the distillation snapshot, the OAuth
/// refresh tokens, the ban list, the tree seed — used to be keyed by *device*.
/// One `written-distillation.json`, one `google_refresh_token`, one ban list. So
/// signing out had to erase all of it, or the next person to sign in on the
/// phone inherited a stranger's connections and a stranger's distillation.
///
/// That made signing out mean *disconnect everything*, which is wrong about what
/// a connection is: a connection is a snapshot that was taken once, and the fact
/// that it happened doesn't stop being true because someone signed out. Keying
/// the stores by account is what lets sign-out leave them alone — the data is
/// still there when they come back, and it was never reachable by anyone else.
///
/// Read fresh at every access rather than captured once: these stores outlive
/// any particular sign-in, and a cached scope would write the second account's
/// records into the first account's file.
enum AccountScope {

    /// `nil` only before anyone has signed in — the phone-number flow, which
    /// still proves nothing and creates no account. Those land in `local` and
    /// are inherited by the next such session, which is the same behaviour they
    /// had before and no worse: nothing there is tied to a real identity.
    static var current: String {
        SupabaseAuth.storedUserID ?? "local"
    }

    /// Suffix for a `UserDefaults` key or Keychain item.
    static func key(_ base: String) -> String {
        "\(base).\(current)"
    }
}
