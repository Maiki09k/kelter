# Kelter: Technik

Notizen aus der Entwicklung, mit Messwerten und Datum. Für die Benutzung reicht das [README](../README.md).

## Grafik im Detail

Spiele, die selbst Vulkan nutzen (zum Beispiel Doom Eternal), gehen über den Vulkan-Treiber:
MoltenVK (Standard, Bild geprüft) oder KosmicKrisp (Mesa, volles Vulkan 1.3, im Test am
14.11.2026 kam das Bild aber schwarz an). DXVK 3 braucht `shaderCullDistance`, das MoltenVK
nicht kann; darum nimmt Kelter mit MoltenVK DXVK 1.10.

Gemessen am 14.11.2026 (M5 Pro, 120-Hz-Display, Testprogramme in `shim/`):

| Fall | Automatisch | Ohne Automatik |
|---|---|---|
| DX9, 64 und 32 Bit | DXVK, 120 FPS | WineD3D, 79 FPS |
| DX11, 64 Bit | D3DMetal, 120 FPS | gleich |
| DX11, 32 Bit | DXMT, 120 FPS, Feature-Level 11 | D3DMetal fällt auf WineD3D mit Feature-Level 9.3 |

Mehrere `WINEDLLPATH_*` gleichzeitig gehen: D3DMetal hat Vorrang vor DXVK, DXVK vor DXMT. Darum
bekommt DXVK einen eigenen Ordner nur mit `d3d9.dll` (`renderer/dxvk-d3d9`, legt Kelter selbst an).

**Game Mode** (Steam-Seite, Schalter, Standard aus): erzwingt mit `xcrun gamepolicyctl game-mode set on`
den macOS-Spielmodus, solange gespielt wird, und stellt danach auf `auto` zurück (nur wenn Kelter
ihn gesetzt hat, Merker `.gamemode-forced`). Wine-Prozesse sind keine App-Bundles, darum schaltet
macOS ihn sonst nicht selbst ein. Braucht Xcode.

Steam gibt seine Umgebung an das Spiel weiter. Braucht ein Spiel andere Einstellungen als das
laufende Steam, startet Kelter Steam dafür neu.

## DOOM Eternal und andere id-Tech-Spiele

Ohne Anpassung bricht DOOM Eternal ab („Could not find support for required subgroup stages“):
Metal kennt keine Subgroup-Funktionen in Vertex-Shadern, MoltenVK meldet sie darum nicht. Kelter
baut MoltenVK 1.4.2 selbst (`scripts/build-moltenvk.sh`, Patch `shim/moltenvk-idtech.patch`, nach
MoltenVK-Issue #2818): Vertex/Geometry/Tess-Eval-Subgroups, `geometryShader`, `depthBounds`,
`wideLines`, `shaderCullDistance` werden gemeldet, mit `KELTER_MVK_VENDOR_AMD=1` die AMD-Kennung.
Die Bibliothek steckt im App-Paket und wird als eigener Vulkan-Treiber „MoltenVK für Spiele“
(`kelter_moltenvk_icd.json`) neben die Engine gelegt; andere Spiele nutzen ihn nicht.

Ein Compute-Shader von DOOM rechnet mit `double`, das Metal nicht kennt; er fiel ganz aus. Kelter baut
darum auch SPIRV-Cross mit einem Patch (`shim/spirv-cross-double-as-float.patch`), der `double` als
`float` ausgibt. Seitdem übersetzt MoltenVK alle Shader des Spiels ohne Fehler. Ein Mitschnitt aller
Shader (`MVK_CONFIG_SHADER_DUMP_DIR`) zeigte am 14.11.2026: Kein Vertex-Shader nutzt Subgroups oder
Cull-Distanzen, Geometry-Shader kommen nicht vor. Die vorgetäuschten Funktionen werden dort also nicht
gebraucht.

Die Fix-Tabelle (`GameFixes.swift`) stellt DOOM Eternal ohne eigene Einstellungen so ein: „Vulkan
direkt“ (keine DirectX-Übersetzer, deren `dxgi`/`nvapi` das Spiel abstürzen lassen), Treiber
„MoltenVK für Spiele“. Diese Startoptionen bekommt es immer, vor den eigenen: `+r_fullscreen 2` mit
`r_windowPosX/Y 0` und `r_windowWidth/Height` in Größe des Hauptbildschirms (randloses Vollbild ohne
Auflösungswechsel), `+com_adaptiveTickMaxHz 1000` (FPS unbegrenzt, das Spiel deckelt sonst bei 250)
und `+com_skipIntroVideo 1` (Titelbild nach rund 18 statt 45 Sekunden). Dazu
`MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=0`: MoltenVK übergibt die Befehle auf einem eigenen Thread.

Gemessen am 14.11.2026, gleicher Spawnpunkt, Game Mode aus, Bildrate aus MoltenVKs Zeitstempeln:

| Variante | FPS |
|---|---|
| Fenster 1504×823 | 106 |
| plus `MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS=1` | 106 (kein Gewinn, nicht übernommen) |
| plus `MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS=0` | 120 |
| plus randloses Vollbild 1512×982 | 129 |

Kelter startet `DOOMEternalx64vk.exe` direkt (mit
`steam_appid.txt`), weil der Electron-Launcher unter Wine hängt oder weiß bleibt, und wartet vorher,
bis Steam im `connection_log.txt` „Logged On“ meldet; früher gestartet beendet sich das Spiel sofort.

Messen ohne Klicks: `MVK_CONFIG_LOG_LEVEL=3 MVK_CONFIG_PERFORMANCE_TRACKING=1
MVK_CONFIG_PERFORMANCE_LOGGING_FRAME_COUNT=300 Kelter --cli play 782330` schreibt alle 300 Bilder eine
Zeile in `Logs/game-782330.log`. Achtung: „avg FPS“ dort ist der Schnitt seit Spielstart. Die echte
Bildrate eines Abschnitts ist 300 geteilt durch den Abstand zweier „elapsed time“-Werte.
`shim/sendkey.c` drückt Tasten im Spielfenster. DOOM muss dabei vorn sein: Im Hintergrund drosselt es
auf die Bildschirmfrequenz und nimmt keine Tasten an.

## Spiele starten, laden, löschen

- **Start ohne Steam-Neustart:** Steam startet nur neu, wenn ein Spiel andere Grafik-Einstellungen
  braucht als das laufende Steam (Startoptionen und Bildschirm zählen nicht), und nie, während ein
  Spiel läuft. Spiele mit eigenem Start (DOOM) brauchen nur ein angemeldetes Steam. „Steam öffnen“
  holt ein laufendes Steam nur nach vorn. Kelter wartet auf die Anmeldung, schickt dann
  `-applaunch` und meldet erst „läuft“, wenn der Spielprozess da ist (People Playground: 4 s statt 50 s).
- **Downloads:** Laufen über Steam selbst („Spiele installieren“ öffnet die Steam-Bibliothek). Die
  Bibliothek zeigt den Fortschritt aus `appmanifest_*.acf`. Geprüft am 16.11.: Terraria 608 MB in 31 s.
  Kaputt waren vorher die Steam-Neustarts durch Kelter, nicht Steams Download.
- **Ersteinrichtung (.NET, XNA):** Jede Bottle bekommt einmalig wine-monos `winemono-support.msi`
  (aus der Engine). Es trägt .NET 1.1 bis 4.8 und XNA 4 ein; ohne das startet Steam Microsofts
  .NET-Web-Installer, der unter Wine hängt (Terraria). Kelter wartet während solcher Installer bis
  15 Minuten und zählt sie nicht als laufendes Spiel.
- **Deinstallieren:** Rechtsklick oder Einstellungen → „Deinstallieren …“. Steam wird kurz
  angehalten, Spielordner, `appmanifest`, Shader-Cache und Workshop-Dateien kommen in den Papierkorb,
  Spielstände bleiben. Nur Ordner direkt in `steamapps/common` werden angefasst.
  `Kelter --cli uninstall <App-ID> --dry-run` zeigt die Ziele.
- **Bildschirm und Auflösung** (pro Spiel): „Automatisch“ nimmt einen externen Bildschirm, wenn einer
  angeschlossen ist. Windows-Spiele öffnen auf dem Hauptbildschirm, darum macht Kelter den gewählten
  solange zum Hauptbildschirm. Auflösung „Wie macOS“ (flüssig) oder eine echte Pixel-Auflösung (1x-Modus,
  Wine sieht dann jeden Pixel ohne Retina-Modus). Änderungen gelten nur, solange Kelter läuft, und werden
  nach dem Spiel zurückgestellt. `Kelter --cli displays` listet die Modi.
- **Bildfehler-Standards:** `MVK_CONFIG_FAST_MATH_ENABLED=0` (MoltenVK PR #1179/#2055), kein `DXVK_ASYNC`,
  `DXMT_CONFIG=d3d11.sampleNaNToZero=True;d3d11.defuseFma=True;`, und `WINEESYNC=1` zu MSync, weil D3DMetal
  ohne ESync-Kennung unter MSync falsch arbeitet (Whisky, BottleSettings.swift). Fast Math und
  asynchrone Shader lassen sich pro Spiel wieder einschalten.
- **Mehrere Steam-Konten:** Konto-Menü in der Leiste und Bereich „Konten“ auf der Steam-Seite. Ein
  Wechsel setzt Steams Registry-Wert `AutoLoginUser` und startet Steam neu, ohne Passwort, solange Steam
  sich das Konto gemerkt hat („Angemeldet bleiben“). „Konto hinzufügen“ öffnet Steams eigene Anmeldung;
  Kelter sieht keine Passwörter. Alle Konten teilen sich die installierten Spiele.
  `Kelter --cli accounts` listet sie, `Kelter --cli account <SteamID|Name|neu>` wechselt.
- **Protokoll:** `Logs/kelter.log` schreibt jeden Steam-Neustart, Spielstart und Bildschirmwechsel mit Grund.

## Wie es funktioniert

- **Engine** (`~/Library/Application Support/Kelter/Engines/`): Wine aus
  `WS12WineSikarugir11.0_1` plus `Frameworks`, `renderer` und `Resources/vulkan` aus
  `Template-1.0.27` (beide GitHub, Sikarugir-App, Prüfsummen in `Catalog.swift`).
- **Pflicht-Variablen**: `SikarugirAppWine11=1` (sonst startet die Engine keine Kindprozesse),
  `DYLD_FALLBACK_LIBRARY_PATH` auf `Frameworks`. Wine immer direkt starten, nie über
  `/usr/bin/env`, `nohup` oder eine Shell: SIP entfernt dort alle `DYLD_`-Variablen.
- **Grafik** ohne Kopieren: `WINEDLLPATH_D3DMETAL` plus `CX_APPLEGPTK_LIBD3DSHARED_PATH`,
  `WINEDLLPATH_DXMT` oder `WINEDLLPATH_DXVK` zeigen auf `renderer/…/wine`.
- **Web-Helfer-Shim** (`shim/webhelper-shim.c`): Steams Chromium zeichnet unter Wine auf dem Mac
  nur Schwarz. Der Shim ersetzt `steamwebhelper.exe` und startet das Original
  (`steamwebhelper.kelter-real.exe`) mit `--disable-gpu --single-process`. Kelter setzt ihn vor
  jedem Start neu ein und startet Steam einmal neu, wenn ein Steam-Update ihn überschrieben hat.

Verworfen (am 14.11.2026 gemessen): Apples GPTK-Wine 7.7 (Steam beendet sich sofort),
Gcenx' Wine Staging 11 (Steam läuft, aber DXMT und D3DMetal zeichnen nicht, WineD3D nur DX9-Niveau,
DXVK schwarz).

## Bauen, Shim und Testprogramme

Der Shim ist ein Windows-Programm und wird mit Zig gebaut (`scripts/build-shim.sh`, macht
`install.sh` bei Bedarf selbst). Zig liegt nicht im Repo; einmalig laden:

```bash
mkdir -p .toolchain && curl -fsSL https://ziglang.org/download/0.17.1/zig-aarch64-macos-0.17.1.tar.xz | tar -xJ -C .toolchain && mv .toolchain/zig-aarch64-macos-0.17.1 .toolchain/zig
```

Grafiktest ohne Spiel: `shim/d3d11-probe.c` öffnet ein Fenster und füllt es per DirectX 11 in
Kelter-Rot. Bauen mit `.toolchain/zig/zig cc -target x86_64-windows-gnu -O2 -o probe.exe shim/d3d11-probe.c -ld3d11 -ldxgi -luuid`,
dann `Kelter --cli run dxmt /pfad/zu/probe.exe`.

## Alles in einer App

`scripts/install.sh` packt Programm, Web-Helfer-Shim und `libMoltenVK-kelter.dylib` in
`~/Applications/Kelter.app`. Am 14.11.2026 geprüft: In einem leeren `KELTER_HOME` richtet die
installierte App die komplette Engine allein ein (Downloads plus eigene Teile), ohne Projektordner,
Zig oder cmake. Die Bauwerkzeuge braucht nur, wer Shim oder MoltenVK neu baut. `scripts/build-moltenvk.sh` legt dafür
eine gepatchte SPIRV-Cross-Kopie unter `.toolchain/SPIRV-Cross-kelter` an, weil `fetchDependencies` die
eigene Kopie bei jedem Lauf zurücksetzt.
