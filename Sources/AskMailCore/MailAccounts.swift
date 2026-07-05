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

/// Why account discovery produced the list it did — so the UI can tell "no
/// accounts" apart from "we were blocked from looking", which are the same empty
/// list but need very different guidance.
public enum MailAccessStatus: Sendable, Equatable {
    /// The Mail root was read. `accounts` reflects what's there (possibly empty
    /// if Mail genuinely has no accounts).
    case ok
    /// The Mail folder exists but couldn't be read — AskMail needs Full Disk
    /// Access. This is the common first-run state.
    case permissionDenied
    /// No Mail data on disk at the expected location — Mail isn't set up (or
    /// hasn't downloaded any messages yet).
    case notFound
}

/// Result of a discovery pass: the accounts found plus why (see `status`).
public struct MailDiscovery: Sendable {
    public let accounts: [MailAccount]
    public let status: MailAccessStatus

    public init(accounts: [MailAccount], status: MailAccessStatus) {
        self.accounts = accounts
        self.status = status
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
    /// Convenience wrapper over `discover` for callers that don't need to know
    /// *why* the list is empty.
    public static func list(mailRoot: URL = Defaults.mailRoot,
                            accountsPlist: URL = Defaults.accountsPlistURL) -> [MailAccount] {
        discover(mailRoot: mailRoot, accountsPlist: accountsPlist).accounts
    }

    /// Lists accounts under `mailRoot` and reports whether the read itself
    /// succeeded, so the UI can distinguish an empty mailbox from a Full Disk
    /// Access block or a missing Mail folder. Both parameters are injectable so
    /// tests can point at a synthetic tree.
    public static func discover(mailRoot: URL = Defaults.mailRoot,
                                accountsPlist: URL = Defaults.accountsPlistURL) -> MailDiscovery {
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: mailRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
        } catch {
            return MailDiscovery(accounts: [], status: classify(error))
        }

        let meta = metadata(plistURL: accountsPlist)
        let accounts = entries
            .filter { url in
                guard url.lastPathComponent != "MailData" else { return false }
                return (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            }
            .map { directory -> MailAccount in
                let id = directory.lastPathComponent
                let info = meta[id]
                return MailAccount(id: id,
                                   email: info?.email ?? "",
                                   displayName: info?.name ?? "",
                                   directory: directory)
            }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        return MailDiscovery(accounts: accounts, status: .ok)
    }

    /// Maps a `contentsOfDirectory` failure to an access status. TCC surfaces as
    /// a Cocoa "no permission" error (or an underlying POSIX EPERM/EACCES); a
    /// genuinely absent folder surfaces as "no such file".
    private static func classify(_ error: Error) -> MailAccessStatus {
        let nsError = error as NSError
        if nsError.code == NSFileReadNoPermissionError { return .permissionDenied }
        if nsError.code == NSFileReadNoSuchFileError { return .notFound }
        let posix = (nsError.userInfo[NSUnderlyingErrorKey] as? NSError)?.code
        if posix == Int(EPERM) || posix == Int(EACCES) { return .permissionDenied }
        if posix == Int(ENOENT) { return .notFound }
        // Unknown read failure: treat as "not found" so the guidance is the
        // milder "make sure Mail is set up" rather than a false FDA claim.
        return .notFound
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
