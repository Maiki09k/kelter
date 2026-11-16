import Foundation
import Testing
@testable import Kelter

@Suite struct VDFTests {
    @Test func parsesNestedLibraryFolders() {
        let text = """
        "libraryfolders"
        {
            "0"
            {
                "path"        "C:\\\\Program Files (x86)\\\\Steam"
                "apps" { "228980" "123" "570" "456" }
            }
            "1"  { "path" "D:\\\\Games" }  // comment
        }
        """
        let root = VDF.parse(text)
        #expect(root["libraryfolders"]?["0"]?["path"]?.string == #"C:\Program Files (x86)\Steam"#)
        #expect(root["LibraryFolders"]?["1"]?["PATH"]?.string == #"D:\Games"#)
        #expect(root["libraryfolders"]?["0"]?["apps"]?["570"]?.string == "456")
    }

    @Test func readsAppManifest() throws {
        let manifest = """
        "AppState"
        {
            "appid"        "620"
            "name"         "Portal 2"
            "StateFlags"   "4"
            "installdir"   "Portal 2"
            "LastPlayed"   "1731500000"
            "SizeOnDisk"   "12345678"
        }
        """
        let steam = SteamClient(bottle: Bottle(name: "Test"))
        let steamapps = URL(fileURLWithPath: "/tmp/steamapps")
        let game = try #require(SteamLibrary.game(fromManifest: manifest, steamapps: steamapps, steam: steam))
        #expect(game.appID == "620")
        #expect(game.name == "Portal 2")
        #expect(game.isReady)
        #expect(game.sizeOnDisk == 12_345_678)
        #expect(game.installDirectory.path == "/tmp/steamapps/common/Portal 2")
        #expect(game.lastPlayed == Date(timeIntervalSince1970: 1_731_500_000))
    }

    @Test func handlesEscapesAndUnquotedTokens() {
        let root = VDF.parse(#"key { inner "a \"quoted\" word" tab "x\ty" }"#)
        #expect(root["key"]?["inner"]?.string == #"a "quoted" word"#)
        #expect(root["key"]?["tab"]?.string == "x\ty")
    }
}

@Suite struct OptionsTests {
    @Test func splitsArgumentsWithQuotes() {
        var options = GameOptions()
        options.arguments = #"-dx11  -windowed "-name Player" "#
        #expect(options.argumentList == ["-dx11", "-windowed", "-name Player"])
    }

    @Test func oldSettingsFilesStillLoad() throws {
        let json = #"{"defaults":{"graphics":"dxmt"},"games":{"620":{"metalHUD":true}}}"#
        let settings = try JSONDecoder().decode(KelterSettings.self, from: Data(json.utf8))
        #expect(settings.defaults.graphics == .dxmt)
        #expect(settings.defaults.advertiseAVX)
        #expect(settings.options(for: "620").metalHUD)
        #expect(settings.options(for: "620").graphics == .automatic)
        #expect(settings.forceGameMode == false)
        #expect(settings.options(for: "999").graphics == .dxmt)
    }

    @Test func graphicsChoiceSetsOnlyItsOwnVariables() {
        let engine = URL(fileURLWithPath: "/E")
        let prefix = URL(fileURLWithPath: "/P")
        var options = GameOptions()

        var env = LaunchEnvironment.game(engine: engine, prefix: prefix, options: options)
        #expect(options.graphics == .automatic)
        #expect(env["WINEDLLPATH_D3DMETAL"] == "/E/renderer/d3dmetal/wine")
        #expect(env["WINEDLLPATH_DXMT"] == "/E/renderer/dxmt/wine")
        #expect(env["WINEDLLPATH_D9VK"] == "/E/renderer/dxvk-d3d9/wine")
        #expect(env["WINEDLLPATH_DXVK"] == nil)

        options.graphics = .d3dmetal
        env = LaunchEnvironment.game(engine: engine, prefix: prefix, options: options)
        #expect(env["WINEDLLPATH_D3DMETAL"] == "/E/renderer/d3dmetal/wine")
        #expect(env["CX_APPLEGPTK_LIBD3DSHARED_PATH"] == "/E/renderer/d3dmetal/external/libd3dshared.dylib")
        #expect(env["WINEDLLPATH_DXMT"] == nil)
        #expect(env["SikarugirAppWine11"] == "1")
        #expect(env["DYLD_FALLBACK_LIBRARY_PATH"] == "/E/Frameworks:/usr/lib")
        #expect(env["WINEPREFIX"] == "/P")

        options.graphics = .dxmt
        env = LaunchEnvironment.game(engine: engine, prefix: prefix, options: options)
        #expect(env["WINEDLLPATH_DXMT"] == "/E/renderer/dxmt/wine")
        #expect(env["WINEDLLPATH_D3DMETAL"] == nil)

        #expect(env["VK_ICD_FILENAMES"] == "/E/Resources/vulkan/icd.d/MoltenVK_icd.json")
        options.vulkanDriver = .kosmicKrisp
        env = LaunchEnvironment.game(engine: engine, prefix: prefix, options: options)
        #expect(env["VK_DRIVER_FILES"] == "/E/Resources/vulkan/icd.d/kosmickrisp_mesa_icd.json")

        options.graphics = .dxvk
        env = LaunchEnvironment.game(engine: engine, prefix: prefix, options: options)
        #expect(env["WINEDLLPATH_DXVK"] == "/E/renderer/dxvk3/wine")
        options.vulkanDriver = .moltenVK
        env = LaunchEnvironment.game(engine: engine, prefix: prefix, options: options)
        #expect(env["WINEDLLPATH_DXVK"] == "/E/renderer/dxvk/wine")

        options.graphics = .wined3d
        options.fastSync = false
        env = LaunchEnvironment.game(engine: engine, prefix: prefix, options: options)
        #expect(env.keys.allSatisfy { !$0.hasPrefix("WINEDLLPATH_") })
        #expect(env["WINEMSYNC"] == nil)
    }
}

@Suite struct BottleTests {
    @Test func mapsWindowsPathsThroughDosDevices() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("kelter-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let bottle = Bottle(name: "Test", root: home)
        let devices = bottle.prefix.appendingPathComponent("dosdevices")
        try FileManager.default.createDirectory(at: bottle.driveC, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: devices, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: devices.appendingPathComponent("c:").path, withDestinationPath: "../drive_c")

        let url = try #require(bottle.unixPath(forWindowsPath: #"C:\Program Files (x86)\Steam"#))
        let expected = bottle.driveC.resolvingSymlinksInPath().appendingPathComponent("Program Files (x86)/Steam")
        #expect(url.path == expected.path)
        #expect(bottle.unixPath(forWindowsPath: "relative\\path") == nil)
    }
}

@Suite struct ShimTests {
    @Test func installsShimAndKeepsTheRealHelper() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("kelter-shim-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let steam = SteamClient(bottle: Bottle(name: "Test", root: home))
        try FileManager.default.createDirectory(at: steam.cefDirectory, withIntermediateDirectories: true)
        let real = Data(repeating: 7, count: 4096)
        try real.write(to: steam.helper)

        let shim = try #require(Paths.webhelperShim)
        #expect(steam.helperNeedsShim)
        #expect(try steam.installShim())
        #expect(SteamClient.sameFile(steam.helper, shim))
        #expect(try Data(contentsOf: steam.realHelper) == real)
        #expect(!steam.helperNeedsShim)
        #expect(try steam.installShim() == false)

        // A Steam update brings back its own helper: the shim goes in front of the new one.
        let updated = Data(repeating: 9, count: 5000)
        try updated.write(to: steam.helper)
        #expect(steam.helperNeedsShim)
        #expect(try steam.installShim())
        #expect(try Data(contentsOf: steam.realHelper) == updated)
    }
}

@Suite struct EngineTests {
    @Test func preparesDX9OnlyRenderer() throws {
        let engine = FileManager.default.temporaryDirectory.appendingPathComponent("kelter-engine-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: engine) }
        for arch in ["x86_64-windows", "i386-windows"] {
            let folder = engine.appendingPathComponent("renderer/dxvk/wine/\(arch)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(arch.utf8).write(to: folder.appendingPathComponent("d3d9.dll"))
            try Data("d3d11".utf8).write(to: folder.appendingPathComponent("d3d11.dll"))
        }
        try EngineInstaller.prepareRenderers(in: engine)
        try EngineInstaller.prepareRenderers(in: engine)  // second run changes nothing
        for arch in ["x86_64-windows", "i386-windows"] {
            let folder = engine.appendingPathComponent("renderer/dxvk-d3d9/wine/\(arch)")
            #expect(try Data(contentsOf: folder.appendingPathComponent("d3d9.dll")) == Data(arch.utf8))
            #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("d3d11.dll").path))
        }
    }
}

@Suite struct GameFixTests {
    @Test func doomGetsItsFixOnlyWithoutOwnSettings() {
        var settings = KelterSettings()
        let doom = settings.options(for: "782330")
        #expect(doom.vulkanDriver == .moltenVKGames)
        #expect(doom.graphics == .vulkan)
        let env = LaunchEnvironment.game(engine: URL(fileURLWithPath: "/E"), prefix: URL(fileURLWithPath: "/P"), options: doom)
        #expect(env.keys.allSatisfy { !$0.hasPrefix("WINEDLLPATH_") })
        #expect(env["KELTER_MVK_VENDOR_AMD"] == "1")
        #expect(env["VK_ICD_FILENAMES"] == "/E/Resources/vulkan/icd.d/kelter_moltenvk_icd.json")
        #expect(doom.argumentList.isEmpty)
        // Always-on start options: borderless (never Wine's display-mode switch), frame rate up to the
        // engine's limit, and MoltenVK submitting on its own thread.
        let fix = GameFixes.all["782330"]
        let fixed = fix?.arguments() ?? []
        let mode = fixed.firstIndex(of: "+r_fullscreen").map { fixed[$0 + 1] }
        #expect(mode == "2" || mode == "0")  // 1 would switch the Mac's display mode and hang
        #expect(fixed.contains("+com_adaptiveTickMaxHz"))
        #expect(fix?.environment["MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS"] == "0")
        #expect(settings.options(for: "620").vulkanDriver == .moltenVK)

        var own = GameOptions()
        own.arguments = "+com_skipIntroVideo 1"
        settings.games["782330"] = own
        #expect(settings.options(for: "782330") == own)
    }

    @Test func setsJSONValueWithoutTouchingTheRest() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("kelter-json-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try #"{ "_settings": { "remember_login": false, "launch_target": "portal", "language": "en-us" } }"#
            .write(to: file, atomically: true, encoding: .utf8)
        GameFixes.setJSONValue(file: file, key: "launch_target", value: "retail")
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text == #"{ "_settings": { "remember_login": false, "launch_target": "retail", "language": "en-us" } }"#)
    }
}

@Suite struct SignInTests {
    @Test func onlyCountsLogOnsAfterTheLastStart() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("kelter-signin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let steam = SteamClient(bottle: Bottle(name: "Test", root: home))
        try FileManager.default.createDirectory(at: steam.connectionLog.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: steam.bottle.prefix, withIntermediateDirectories: true)
        try "[2026-11-14 10:12:14] [Logged On, 4, 7] old session\n".write(to: steam.connectionLog, atomically: true, encoding: .utf8)
        steam.markSessionStart()
        #expect(!steam.isSignedIn)
        let handle = try FileHandle(forWritingTo: steam.connectionLog)
        handle.seekToEndOfFile()
        handle.write(Data("[2026-11-14 13:06:52] [Logged On, 4, 7] RecvMsgClientLogOnResponse() : processing complete\n".utf8))
        try handle.close()
        #expect(steam.isSignedIn)
    }
}

@Suite struct GameProcessTests {
    @Test func findsTheGameByUnixOrWindowsPath() {
        let game = InstalledGame(appID: "1118200", name: "People Playground",
                                 installDirectory: URL(fileURLWithPath: "/B/drive_c/Program Files (x86)/Steam/steamapps/common/People Playground"),
                                 sizeOnDisk: 0, lastPlayed: nil, stateFlags: 4, cover: nil)
        let listing = """
          101 /Users/m/Library/Application Support/Kelter/Bottles/Steam/drive_c/Program Files (x86)/Steam/steamapps/common/People Playground/People Playground.exe
          202 C:\\Program Files (x86)\\Steam\\steamapps\\common\\PEOPLE PLAYGROUND\\UnityCrashHandler64.exe
          303 C:\\Program Files (x86)\\Steam\\steam.exe -silent
          404 /Applications/Other.app/Contents/MacOS/Other steamapps/common/People Playground Mod
          505 /bin/zsh -c ls "$S/steamapps/common/People Playground/data" steam.exe
          606 /usr/bin/grep -r steamapps/common/People Playground/ x.exe
        """
        #expect(GameProcess.ids(of: game, in: listing) == [101, 202])
    }
}


@Suite struct LaunchRulesTests {
    @Test func startOptionsAndDisplayDoNotForceASteamRestart() {
        var plain = GameOptions()
        var tuned = GameOptions()
        tuned.arguments = "-dx11 -windowed"
        tuned.display = "builtin"
        tuned.resolution = "native"
        #expect(plain.steamProfile == tuned.steamProfile)
        plain.graphics = .dxmt
        #expect(plain.steamProfile != tuned.steamProfile)
    }

    @Test func oldSettingsGetDisplayDefaults() throws {
        let json = #"{"defaults":{"graphics":"dxmt"}}"#
        let settings = try JSONDecoder().decode(KelterSettings.self, from: Data(json.utf8))
        #expect(settings.defaults.display == Displays.automatic)
        #expect(settings.defaults.resolution == Displays.macOSResolution)
    }

    @Test func resolutionTags() {
        #expect(DisplayResolution(tag: "2560x1440") == DisplayResolution(width: 2560, height: 1440))
        #expect(DisplayResolution(tag: "native") == nil)
        #expect(DisplayResolution(tag: "0x5") == nil)
        #expect(DisplayResolution(width: 3840, height: 2160) > DisplayResolution(width: 2560, height: 1440))
    }

    @Test func downloadProgressOnlyWhilePending() {
        func game(flags: Int, total: Int64, done: Int64) -> InstalledGame {
            InstalledGame(appID: "1", name: "X", installDirectory: URL(fileURLWithPath: "/s/steamapps/common/X"),
                          sizeOnDisk: 0, lastPlayed: nil, stateFlags: flags, cover: nil,
                          bytesToDownload: total, bytesDownloaded: done)
        }
        #expect(game(flags: 1026, total: 200, done: 50).downloadProgress == 0.25)
        #expect(game(flags: 4, total: 200, done: 200).downloadProgress == nil)
        #expect(game(flags: 1026, total: 0, done: 0).downloadProgress == nil)
    }
}

@Suite struct UninstallTests {
    let steamapps = URL(fileURLWithPath: "/tmp/kelter-test/steamapps")

    func game(installDir: String, appID: String = "620") -> InstalledGame {
        InstalledGame(appID: appID, name: "Portal 2", installDirectory: steamapps.appendingPathComponent("common/\(installDir)"),
                      sizeOnDisk: 1, lastPlayed: nil, stateFlags: 4, cover: nil,
                      manifest: steamapps.appendingPathComponent("appmanifest_\(appID).acf"))
    }

    @Test func removesGameFolderManifestAndCaches() throws {
        let targets = try Launcher.uninstallTargets(game(installDir: "Portal 2")).map(\.path)
        #expect(targets.contains("/tmp/kelter-test/steamapps/common/Portal 2"))
        #expect(targets.contains("/tmp/kelter-test/steamapps/appmanifest_620.acf"))
        #expect(targets.contains("/tmp/kelter-test/steamapps/shadercache/620"))
        #expect(!targets.contains("/tmp/kelter-test/steamapps/common"))
        #expect(!targets.contains { $0.contains("userdata") })
    }

    @Test func refusesFoldersOutsideCommon() {
        #expect(throws: KelterError.self) { try Launcher.uninstallTargets(game(installDir: "")) }
        #expect(throws: KelterError.self) { try Launcher.uninstallTargets(game(installDir: "..")) }
        #expect(throws: KelterError.self) { try Launcher.uninstallTargets(game(installDir: "../..")) }
        #expect(throws: KelterError.self) { try Launcher.uninstallTargets(game(installDir: "Portal 2", appID: "../x")) }
    }
}

@Suite struct ArtifactDefaultsTests {
    let engine = URL(fileURLWithPath: "/E")
    let prefix = URL(fileURLWithPath: "/P")

    @Test func cleanImageByDefault() {
        let env = LaunchEnvironment.game(engine: engine, prefix: prefix, options: GameOptions())
        #expect(env["MVK_CONFIG_FAST_MATH_ENABLED"] == "0")
        #expect(env["DXVK_ASYNC"] == nil)
        #expect(env["WINEMSYNC"] == "1")
        #expect(env["WINEESYNC"] == "1")
        #expect(env["DXMT_CONFIG"]?.contains("d3d11.sampleNaNToZero=True") == true)
    }

    @Test func speedOptionsStillAvailable() {
        var options = GameOptions()
        options.graphics = .dxvk
        options.fastMath = true
        options.asyncShaders = true
        let env = LaunchEnvironment.game(engine: engine, prefix: prefix, options: options)
        #expect(env["MVK_CONFIG_FAST_MATH_ENABLED"] == "1")
        #expect(env["DXVK_ASYNC"] == "1")
    }

    @Test func oldSteamProfileForcesOneRestart() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("kelter-profile-\(UUID().uuidString)")
        let bottle = Bottle(name: "Steam", root: home)
        try FileManager.default.createDirectory(at: bottle.prefix, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let steam = SteamClient(bottle: bottle)
        // Pre-revision format: plain options. runningProfile also needs a running bottle, which
        // this test has not, so check the decoding rule directly.
        let old = try JSONEncoder().encode(GameOptions())
        #expect((try? JSONDecoder().decode(SteamClient.StoredProfile.self, from: old)) == nil)
        let current = try JSONEncoder().encode(SteamClient.StoredProfile(revision: LaunchEnvironment.revision, options: GameOptions()))
        #expect((try? JSONDecoder().decode(SteamClient.StoredProfile.self, from: current))?.options == GameOptions())
        _ = steam
    }
}

@Suite struct FirstStartTests {
    @Test func installersInTheGameFolderAreSetupNotTheGame() {
        let game = InstalledGame(appID: "105600", name: "Terraria",
                                 installDirectory: URL(fileURLWithPath: "/B/steamapps/common/Terraria"),
                                 sizeOnDisk: 0, lastPlayed: nil, stateFlags: 4, cover: nil)
        let setup = """
          99200 C:\\Program Files (x86)\\Steam\\bin\\SteamService.exe /installscript C:\\Program Files (x86)\\Steam\\steamapps\\common\\Terraria\\runasadmin.vdf 105600
          99204 C:\\Program Files (x86)\\Steam\\steamapps\\common\\Terraria\\dotNetFx40_Full_setup.exe /passive /norestart
        """
        #expect(GameProcess.ids(of: game, in: setup).isEmpty)
        #expect(GameProcess.isSettingUp(game, in: setup))
        let playing = "  1234 C:\\Program Files (x86)\\Steam\\steamapps\\common\\Terraria\\Terraria.exe"
        #expect(GameProcess.ids(of: game, in: playing) == [1234])
        #expect(!GameProcess.isSettingUp(game, in: playing))
    }
}

@Suite struct AccountTests {
    @Test func readsRememberedAccountsNewestFirst() {
        let text = """
        "users"
        {
            "76561198960265770" { "AccountName" "alpha" "PersonaName" "Alpha" "timestamp" "1794843283" }
            "76561198000000001" { "AccountName" "beta" "PersonaName" "" "timestamp" "1794900000" }
            "broken" { "AccountName" "x" }
        }
        """
        let accounts = SteamClient.accounts(fromLoginUsers: text, avatarFolder: URL(fileURLWithPath: "/nowhere"))
        #expect(accounts.map(\.steamID) == ["76561198000000001", "76561198960265770"])
        #expect(accounts[0].title == "beta")
        #expect(accounts[1].title == "Alpha")
    }

    @Test func readsAutoLoginUserOnlyFromSteamKey() {
        let reg = """
        [Software\\\\Other] 1
        "AutoLoginUser"="wrong"

        [Software\\\\Valve\\\\Steam] 1794843399
        #time=1dd75e046021dc4
        "AlreadyRetriedOfflineMode"=dword:00000000
        "AutoLoginUser"="alpha"
        "Language"="german"
        """
        #expect(SteamClient.autoLoginUser(fromUserReg: reg) == "alpha")
        #expect(SteamClient.autoLoginUser(fromUserReg: "[Software\\\\Valve\\\\Steam] 1\n\"AutoLoginUser\"=\"\"\n") == "")
    }

    @Test func signedInAccountFromConnectionLog() {
        let log = """
        [2026-11-16 16:07:35] [Logged Off, 4, 0] [U:1:1000000042] LogOn() called
        [2026-11-16 16:07:36] [Logged On, 4, 7] [U:1:1000000042] RecvMsgClientLogOnResponse() : processing complete
        """
        #expect(SteamClient.signedInSteamID(fromConnectionLog: log) == "76561198960265770")
        // Steam writes Windows line endings; Swift treats "\r\n" as one character.
        let windows = log.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n[2026-11-16 17:07:03] CClientJob cached\r\n"
        #expect(SteamClient.signedInSteamID(fromConnectionLog: windows) == "76561198960265770")
        #expect(SteamClient.signedInSteamID(fromConnectionLog: log + "\n[2026-11-16 17:00:00] [Logged Off, 0, 0] [U:1:1000000042] Log session ended") == nil)
    }

    @Test func turnsOffSteamsAccountChooserOnly() {
        let config = "\"WebStorage\"\n{\n\t\"Auth\"\n\t{\n\t\t\"AlwaysShowUserChooser\"\t\t\"1\"\n\t}\n}\n"
        let off = SteamClient.settingAlwaysAsk(false, inConfig: config)
        #expect(off.contains("\"AlwaysShowUserChooser\"\t\t\"0\""))
        #expect(!off.contains("\"AlwaysShowUserChooser\"\t\t\"1\""))
        #expect(off.hasPrefix("\"WebStorage\""))
        #expect(SteamClient.settingAlwaysAsk(false, inConfig: "\"other\" \"1\"") == "\"other\" \"1\"")
    }
}
