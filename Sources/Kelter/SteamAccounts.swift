import Foundation

/// A Steam account the client remembers (Steam's own "remember me" at sign-in).
struct SteamAccount: Identifiable, Hashable, Sendable {
    let steamID: String
    let accountName: String
    let personaName: String
    let avatar: URL?
    let lastUsed: Date?

    var id: String { steamID }
    var title: String { personaName.isEmpty ? accountName : personaName }
}

/// Several Steam accounts in one bottle, the way account switchers do it: Steam keeps a sign-in
/// token per remembered account and signs in the one named in the registry value AutoLoginUser.
/// Kelter only changes that value and restarts Steam; passwords are only ever typed into Steam.
extension SteamClient {
    static let steamID64Base: UInt64 = 76_561_197_960_265_728

    var loginUsersFile: URL { directory.appendingPathComponent("config/loginusers.vdf") }

    /// Remembered accounts, most recently used first.
    var accounts: [SteamAccount] {
        guard let text = try? String(contentsOf: loginUsersFile, encoding: .utf8) else { return [] }
        return Self.accounts(fromLoginUsers: text, avatarFolder: directory.appendingPathComponent("config/avatarcache"))
    }

    static func accounts(fromLoginUsers text: String, avatarFolder: URL) -> [SteamAccount] {
        let users = VDF.parse(text)["users"]?.children ?? [:]
        return users.compactMap { steamID, entry -> SteamAccount? in
            guard steamID.allSatisfy(\.isNumber), let name = entry["accountname"]?.string, !name.isEmpty else { return nil }
            let avatar = avatarFolder.appendingPathComponent("\(steamID).png")
            let stamp = entry["timestamp"]?.string.flatMap(TimeInterval.init).map { Date(timeIntervalSince1970: $0) }
            return SteamAccount(steamID: steamID, accountName: name, personaName: entry["personaname"]?.string ?? "",
                                avatar: FileManager.default.fileExists(atPath: avatar.path) ? avatar : nil, lastUsed: stamp)
        }
        .sorted { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
    }

    /// The account Steam signs in automatically on its next start (empty: Steam asks).
    var autoLoginUser: String? {
        guard let text = try? String(contentsOf: bottle.prefix.appendingPathComponent("user.reg"), encoding: .utf8) else { return nil }
        return Self.autoLoginUser(fromUserReg: text)
    }

    static func autoLoginUser(fromUserReg text: String) -> String? {
        var inSteamKey = false
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if line.hasPrefix("[") {
                inSteamKey = line.hasPrefix(#"[Software\\Valve\\Steam]"#)
                continue
            }
            guard inSteamKey, line.hasPrefix(#""AutoLoginUser"=""#) else { continue }
            let value = line.dropFirst(#""AutoLoginUser"=""#.count)
            return String(value.prefix { $0 != "\"" })
        }
        return nil
    }

    /// SteamID64 of the account signed in since Kelter last started Steam, read from the
    /// connection log ("[Logged On, …] [U:1:<account id>]").
    var signedInSteamID: String? {
        guard let data = try? Data(contentsOf: connectionLog) else { return nil }
        let text = String(decoding: data.suffix(400_000), as: UTF8.self)
        return Self.signedInSteamID(fromConnectionLog: text)
    }

    static func signedInSteamID(fromConnectionLog text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline).reversed() {
            if line.contains("[Logged Off") && line.contains("Log session ended") { return nil }
            guard line.contains("[Logged On"), let range = line.range(of: #"[U:1:"#) else { continue }
            let digits = line[range.upperBound...].prefix { $0.isNumber }
            guard let accountID = UInt64(digits), accountID > 0 else { continue }
            return String(steamID64Base + accountID)
        }
        return nil
    }

    var configFile: URL { directory.appendingPathComponent("config/config.vdf") }

    /// Steam's own "ask which account on every start" (WebStorage/Auth/AlwaysShowUserChooser in
    /// config.vdf). Steam switches it on after a sign-out; while on, every start waits in the
    /// account chooser, so Kelter turns it off when it switches accounts. Only while Steam is off.
    func setAlwaysAskForAccount(_ on: Bool) throws {
        guard !bottle.isRunning, let text = try? String(contentsOf: configFile, encoding: .utf8) else { return }
        let changed = Self.settingAlwaysAsk(on, inConfig: text)
        if changed != text { try changed.write(to: configFile, atomically: true, encoding: .utf8) }
    }

    static func settingAlwaysAsk(_ on: Bool, inConfig text: String) -> String {
        guard let range = text.range(of: #""AlwaysShowUserChooser"\s*"[01]""#, options: .regularExpression) else { return text }
        return text.replacingCharacters(in: range, with: "\"AlwaysShowUserChooser\"\t\t\"\(on ? 1 : 0)\"")
    }

    /// Sets AutoLoginUser while Steam is stopped (an empty name makes Steam show its own sign-in).
    func setAutoLoginUser(_ name: String) async throws {
        guard !bottle.isRunning else { throw KelterError.message("Steam muss für den Kontowechsel aus sein.") }
        guard name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." || $0 == "@" }) else {
            throw KelterError.message("Ungewöhnlicher Kontoname, Kelter ändert ihn nicht.")
        }
        let env = bottle.baseEnvironment
        let log = Paths.logs.appendingPathComponent("accounts.log")
        try await Shell.check(bottle.wine, ["reg", "add", #"HKCU\Software\Valve\Steam"#, "/v", "AutoLoginUser",
                                            "/t", "REG_SZ", "/d", name, "/f"], environment: env, log: log)
        try await Shell.run(bottle.wineserver, ["-w"], environment: env, log: log, appendLog: true)
    }
}
