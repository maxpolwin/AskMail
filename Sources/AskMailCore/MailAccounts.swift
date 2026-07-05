import Foundation

/// A single Apple Mail account discovered on disk, enriched with the friendly
/// name and email address from Accounts.plist when those are available.
///
/// This replaces asking the user to browse to an opaque account folder: the UI
/// can present a list of real accounts (`label`) while persisting the stable
/// `id` and writing the human-readable `storageKey` into the store.
public struct MailAccount: Sendable, Identifiable, Equatable {
    /// On-disk identifier: the directory name under the Mail root
    /// (`~/Library/Mail/V10/<id>`). Stable across relaunches; persisted as the
    /// selection key.
    public let id: String
    /// Primary email address, or "" when it can't be resolved from the plist.
    public let email: String
    /// User-facing account name (e.g. "Personal"), or "" when unknown.
    public let displayName: String
    /// The account's mail directory, scanned for .emlx during ingestion.
    public let directory: URL

    public init(id: String, email: String, displayName: String, directory: URL) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.directory = directory
    }

    /// Human-friendly label for the settings picker. Degrades progressively so
    /// an account is always selectable even when the plist can't be read.
    public var label: String {
        switch (displayName.isEmpty, email.isEmpty) {
        case (false, false): return "\(displayName) (\(email))"
        case (false, true):  return displayName
        case (true, false):  return email
        case (true, true):   return id
        }
    }

    /// Value written to each message's `account` column: the email when known
    /// (meaningful and portable), else the on-disk id.
    public var storageKey: String {
        email.isEmpty ? id : email
    }
}

/// Enumerates Apple Mail accounts by listing the account directories under the
/// Mail root and enriching each with its name/email from Accounts.plist.
///
/// The directory listing is the source of truth for *which* accounts exist
/// (only a directory holds ingestable .emlx); the plist only supplies friendly
/// labels. When the plist is missing or a key can't be matched, the account
/// still lists, labelled by its directory id.
///
/// NOTE (spike B11 #1): the Accounts.plist keys below match the commonly
/// documented Mail layout — a top-level array (or a `MailAccounts` array) of
/// per-account dicts carrying an account name, email addresses, and a UUID that
/// equals the account's directory name. They MUST be validated against a real
/// `~/Library/Mail/V10/MailData/Accounts.plist` on the target macOS version
/// before first live run; the tests use a synthetic plist with this schema.
public enum MailAccountsReader {

    /// Keys that may hold the account's directory UUID, in priority order.
    private static let idKeys = ["UniqueId", "Identifier", "AccountID", "AccountUniqueID"]
    /// Keys that may hold a user-facing account name, in priority order.
    private static let nameKeys = ["AccountName", "FullUserName", "Description"]

    private struct AccountInfo {
        let email: String
        let name: String
    }

    /// Lists accounts found under `mailRoot`, sorted by their display label.
    /// Both parameters are injectable so tests can point at a synthetic tree.
    public static func list(mailRoot: URL = Defaults.mailRoot,
                            accountsPlist: URL = Defaults.accountsPlistURL) -> [MailAccount] {
        let meta = metadata(plistURL: accountsPlist)
        let accounts = accountDirectories(mailRoot: mailRoot).map { directory -> MailAccount in
            let id = directory.lastPathComponent
            let info = meta[id]
            return MailAccount(id: id,
                               email: info?.email ?? "",
                               displayName: info?.name ?? "",
                               directory: directory)
        }
        return accounts.sorted {
            $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
    }

    /// Immediate subdirectories of the Mail root, excluding `MailData` (which
    /// holds the index/plist, not a mailbox) and hidden entries.
    private static func accountDirectories(mailRoot: URL) -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: mailRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.filter { url in
            guard url.lastPathComponent != "MailData" else { return false }
            return (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        }
    }

    /// Parses Accounts.plist into a map keyed by account UUID. Returns an empty
    /// map (never throws) when the file is absent or unparseable, so discovery
    /// degrades to directory-id labels rather than failing.
    private static func metadata(plistURL: URL) -> [String: AccountInfo] {
        guard let data = try? Data(contentsOf: plistURL),
              let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        else { return [:] }

        var map: [String: AccountInfo] = [:]
        for dict in accountEntries(from: root) {
            guard let id = firstString(dict, keys: idKeys) else { continue }
            map[id] = AccountInfo(email: primaryEmail(dict),
                                  name: firstString(dict, keys: nameKeys) ?? "")
        }
        return map
    }

    /// Normalises the two documented plist shapes to a flat array of account
    /// dicts: a bare top-level array, or a dict wrapping a `MailAccounts` array.
    private static func accountEntries(from root: Any) -> [[String: Any]] {
        if let array = root as? [[String: Any]] {
            return array
        }
        if let dict = root as? [String: Any],
           let accounts = dict["MailAccounts"] as? [[String: Any]] {
            return accounts
        }
        return []
    }

    private static func primaryEmail(_ dict: [String: Any]) -> String {
        if let addresses = dict["EmailAddresses"] as? [String],
           let first = addresses.first(where: { $0.contains("@") }) {
            return first
        }
        if let single = dict["EmailAddress"] as? String, single.contains("@") {
            return single
        }
        if let username = dict["Username"] as? String, username.contains("@") {
            return username
        }
        return ""
    }

    private static func firstString(_ dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dict[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }
}
