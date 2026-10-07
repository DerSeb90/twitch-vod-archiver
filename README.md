# rewind – Twitch-Livestream-Archiv

rewind nimmt Twitch-Livestreams selbstständig auf – Video in Source-Qualität plus Chat – und spielt sie danach wie auf livearchive.net ab: mit Chat-Replay, Vorschaubildern auf der Zeitleiste und geräteübergreifendem „Weiterschauen“. Ein schlanker, bewusst reduzierter Nachbau von [Ganymede](https://github.com/zibbp/ganymede): ein Go-Binary mit SQLite, `streamlink` und `ffmpeg` in einem Container, dazu eine Flutter-App für Web, Android und Windows.

## Funktionen

- **Nur Livestreams, automatisch**: Kanal hinzufügen, danach wird jeder Stream in **bester Qualität** (ohne Re-Encoding) **inklusive Chat** mitgeschnitten. Kurze Abbrüche, Neustarts beim Streamer und Container-Updates landen als weitere Teile in derselben Aufnahme.
- **Abspielbar, sobald fertig**: Laufende Aufnahmen werden angezeigt (Live-Badge, „Gerade live“, Kanalseite), abspielbar sind sie, sobald sie abgeschlossen und verarbeitet sind. Ein bereits geöffneter Player lädt dann von selbst.
- **Player**: Chat-Replay mit Twitch-, 7TV-, BTTV- und FFZ-Emotes und Badges, Vorschaubilder beim Spulen, Chat-Heatmap auf der Zeitleiste, Kapitel bei Kategoriewechseln, Hintergrundwiedergabe unter Android, „Stats for nerds“.
- **Fortschritt auf dem Server**: auf allen Geräten gleich und sofort synchron; zu Ende geschaute Aufnahmen werden als gesehen markiert und ausgeblendet.
- **Verwaltung** unter `/admin`: Kanäle hinzufügen, pausieren, entfernen; laufende Aufnahmen pausieren, fortsetzen oder abschließen; Aufnahmen löschen oder die Verarbeitung erneut starten; Speicherplatz und Werbefrei-Status.
- **Kein Login zum Anschauen**: gedacht für den Betrieb hinter einem VPN. Die Verwaltung lässt sich per `ADMIN_TOKEN` absichern, und ändernde Anfragen aus dem Browser nimmt der Server nur von der eigenen Web-App an (oder von `CORS_ORIGINS`).
- **Apps aktualisieren sich selbst** (Android, Windows) aus den GitHub-Releases.

## Architektur

```
Twitch ──HLS──▶ streamlink ─pipe─▶ ffmpeg (copy) ──▶ /recordings/<vod>/part-000/index.m3u8 + 4-s-Segmente
                                                     (lokale NVMe, absturzsicher)
       ──IRC──▶ Chat-Recorder ─▶ /recordings/<vod>/chat.ndjson
                     │ Stream vorbei
                     ▼
               Finalizer: Thumbnail, Storyboard, Chat-Chunks (lokal)
                          ffmpeg-Remux ohne Re-Encoding ──▶ Storage Box (SMB)
                     ▼
/archive/<kanal>/<datum>_<id>/video.mp4 · thumb.jpg · storyboard/ · chat/ · info.json
```

- **Live-Erkennung**: Helix `GET /streams` alle `POLL_INTERVAL` für alle Kanäle in einem Request (App-Token).
- **Video**: `streamlink --stdout` wird ohne Neukodierung an ffmpeg durchgereicht, das 4-s-MPEG-TS-Segmente plus Playlist auf die lokale Platte schreibt. Bricht der Stream ab und kommt innerhalb von `OFFLINE_GRACE` zurück (auch mit neuer Stream-ID), entsteht ein weiterer Teil derselben Aufnahme; ebenso nach Pausieren/Fortsetzen und nach Container-Updates.
- **Chat**: anonyme IRC-Verbindung, kein Account nötig. Beim Start werden die letzten Minuten über den recent-messages-Dienst nachgeladen (`CHAT_HISTORY`). Die Zeitleiste wird um den Rückstand korrigiert, mit dem die Aufnahme hinter dem Live-Punkt beginnt (~8 s). Gelöschte Nachrichten und Nachrichten gebannter Nutzer fallen beim Finalisieren heraus.
- **Finalisieren**: Thumbnail, Storyboard-Sprites (nur Keyframes decodiert), Chat in gzip-Chunks (`CHAT_CHUNK`) plus Aktivitäts-Histogramm, Emote- und Badge-Snapshots – alles lokal. Danach Remux `ts → mp4` direkt auf die Storage Box und atomares Verschieben in den Zielordner, dazu eine `info.json` mit allen Metadaten. Die SQLite-DB liegt immer lokal, nie auf SMB.
- **Ausliefern**: MP4 mit HTTP-Range-Requests; Chat-Chunks und das Web-Bundle vorkomprimiert. Emotes und Badges laufen über `/img` (nur Twitch-, BTTV-, 7TV- und FFZ-CDNs): Das umgeht fehlende CORS-Header, und einmal geladene Emotes bleiben erhalten.

### Server (`server/`)

| Paket | Aufgabe |
|---|---|
| `cmd/archiver` | Einstiegspunkt: Konfiguration laden, Dienste starten, sauber herunterfahren |
| `internal/config` | alle Einstellungen aus Umgebungsvariablen |
| `internal/recorder` | Kanäle abfragen, Aufnahmen starten/fortsetzen/beenden (`manager.go`), streamlink + ffmpeg (`streamlink.go`), laufende Aufnahmen und Steuerung (`recordings.go`), Werbefrei-Token (`adfree.go`) |
| `internal/chat` | Chat-Recorder (IRC) und Umrechnung des Rohlogs in Replay-Nachrichten |
| `internal/hls` | Playlists der Aufnahme lesen, Wanduhrzeit → Videoposition |
| `internal/finalize` | Warteschlange und Nachbearbeitung bis zur fertigen VOD (`ffmpeg.go`, `chat.go`, `files.go`) |
| `internal/store` | SQLite: Kanäle, VODs mit Teilen und Kapiteln, Fortschritt, Änderungs-Long-Poll |
| `internal/api` | HTTP: JSON-API (`channels.go`, `vods.go`), Medien und Web-App (`static.go`), Bild-Proxy |
| `internal/twitch` | Helix-API, Token-Prüfung, Drittanbieter-Emotes |
| `internal/util` | Speicherplatz, Ordnergrößen |

### App (`app/`)

| Ordner | Inhalt |
|---|---|
| `lib/src/*.dart` | API-Client, Modelle, Einstellungen, Fortschritt, Server-Sync (Long-Poll), Routing, Theme |
| `lib/src/pages/` | Start, Kanäle, Player, Einstellungen, Verwaltung |
| `lib/src/player/` | Steuerung, Zeitleiste, Chat-Replay, Infos unter dem Video, Hintergrundwiedergabe |
| `lib/src/widgets/` | App-Rahmen, Karten, gemeinsame Bausteine |
| `lib/src/update/` | In-App-Updates aus den GitHub-Releases |
| `android/`, `windows/`, `web/` | die drei gebauten Plattformen (Windows-Installer: `windows/installer/rewind.iss`) |
| `tool/make_icons.py` | erzeugt die App-Icons (`python tool/make_icons.py && dart run flutter_launcher_icons`) |

## Installation

### Server wählen

**Empfehlung: Hetzner Cloud CX43** – 8 vCPU, 16 GB RAM, **160 GB NVMe**, 20 TB Traffic, 15,99 €/Monat netto (Stand nach der [Preisanpassung vom 15.06.2026](https://docs.hetzner.com/general/infrastructure-and-availability/price-adjustment/)), Standort Falkenstein oder Nürnberg, Debian 13 oder Ubuntu 24.04. Die Storage Box ebenfalls in Deutschland buchen, damit der SMB-Traffic im Hetzner-Netz bleibt.

Das Nadelöhr ist die **lokale Platte**, nicht die CPU: Twitch-Source hat bis ~8 Mbit/s ≈ **3,6 GB/h**, drei parallele 12-h-Marathons brauchen also ~130 GB Puffer. Transkodiert wird nicht; streamlink braucht ~5 % eines Kerns pro Stream, die Nachbearbeitung 1–3 min pro 8-h-Stream.

- **CX33** (80 GB, 8,49 €) reicht, wenn höchstens 3 × ~7 h gleichzeitig laufen (oder mit zusätzlichem Volume).
- **CAX31** (ARM) funktioniert auch – das Image gibt es für `amd64` und `arm64` –, kostet aber mehr. CPX/CCX bringen nichts.
- **Storage Box**: 1 TB ≈ 280 h Material. BX21 (5 TB, ~1.400 h) kostete 02/2026 10,90 €. Traffic zur Box ist unbegrenzt; Zuschauen über das VPN zählt zum Server-Traffic.

### 1. Twitch-App anlegen
[dev.twitch.tv/console/apps](https://dev.twitch.tv/console/apps) → *Register Your Application*: OAuth Redirect `http://localhost`, Kategorie *Other*, Client-Typ *Confidential*. **Client-ID** und **Client-Secret** notieren.

### 2. Server und Storage Box
1. Server und Storage Box am selben Standort anlegen, in der Storage Box **SMB-Support** aktivieren (am besten mit einem Sub-Account nur für rewind).
2. Auf dem Server:
   ```bash
   curl -fsSL https://raw.githubusercontent.com/DerSeb90/twitch-vod-archiver/main/deploy/setup-host.sh -o setup-host.sh
   sudo SB_USER=u123456-sub1 SB_PASS='storagebox-passwort' bash setup-host.sh
   ```
   Das Skript installiert Docker und `cifs-utils`, bindet die Storage Box per `/etc/fstab` unter `/mnt/storagebox` ein (Passwort nur in `/etc/storagebox.cred`, chmod 600) und legt `/opt/rewind` mit `docker-compose.yml` und `.env` an.

### 3. VPN
rewind hat keinen Login und spricht HTTP – es darf **nur per VPN** erreichbar sein (WireGuard, z. B. [wg-easy](https://github.com/wg-easy/wg-easy), oder Tailscale):
- `BIND_ADDR` in der `.env` auf die VPN-IP des Servers setzen (z. B. `10.8.0.1` oder die `100.x`-Tailscale-IP).
- **Hetzner Cloud Firewall**: eingehend nur SSH und den VPN-Port. Docker umgeht `ufw`; schützen nur die Cloud Firewall und das `BIND_ADDR`-Binding.

### 4. Starten
```bash
cd /opt/rewind
nano .env                  # TWITCH_CLIENT_ID, TWITCH_CLIENT_SECRET, ADMIN_TOKEN, BIND_ADDR
docker compose up -d
docker compose logs -f
```
Danach `http://<VPN-IP>:8080/admin` öffnen und Kanäle hinzufügen.

**Update** (nach jedem grünen Docker-Build auf `main`):
```bash
cd /opt/rewind && docker compose pull && docker compose up -d
```
Laufende Aufnahmen überleben das: Der alte Container schließt die Segmente sauber (40 s Grace-Period), der neue setzt die Aufnahme als weiteren Teil fort.

**Mit [Arcane](https://getarcane.app)** statt Shell: `setup-host.sh` trotzdem einmal ausführen (Mount, Ordner, Rechte), dann in Arcane ein Projekt `rewind` mit [`deploy/docker-compose.yml`](deploy/docker-compose.yml) und dem ausgefüllten Inhalt von [`deploy/.env.example`](deploy/.env.example) als `.env` anlegen. Updates per *Pull & Redeploy* oder Arcanes Auto-Update. Die Host-Pfade sind absolut, der Projektordner ist also egal.

## Konfiguration

Alles steht in der `.env` (Vorlage mit Kommentaren: [`deploy/.env.example`](deploy/.env.example)). Dauern im Go-Format (`30s`, `10m`).

**Server** (`server/internal/config`):

| Variable | Standard | Bedeutung |
|---|---|---|
| `TWITCH_CLIENT_ID`, `TWITCH_CLIENT_SECRET` | – | **Pflicht**, Twitch-App (siehe oben) |
| `TWITCH_USER_OAUTH` | – | `auth-token` eines Accounts mit Turbo/Abo → Aufnahmen ohne Werbepausen (siehe [Werbung](#werbung)) |
| `CHANNELS` | – | Kanäle, die beim ersten Start angelegt werden (kommagetrennt) |
| `ADMIN_TOKEN` | – | schützt die Verwaltung; leer = ohne Token. Erzeugen: `openssl rand -hex 24` |
| `CORS_ORIGINS` | – | weitere Origins, die schreiben dürfen (z. B. `http://localhost:5173` für den Flutter-Dev-Server) |
| `MAX_CONCURRENT` | `3` | parallele Aufnahmen |
| `QUALITY` | `best` | streamlink-Qualität |
| `STREAMLINK_ARGS` | – | zusätzliche streamlink-Flags, z. B. `--twitch-supported-codecs h264,h265,av1` |
| `POLL_INTERVAL` | `30s` | wie oft Twitch gefragt wird, wer live ist (mindestens 10 s) |
| `OFFLINE_GRACE` | `10m` | Wiederkehr innerhalb dieser Zeit setzt dieselbe Aufnahme fort |
| `MIN_FREE_GB` | `15` | darunter startet keine neue Aufnahme |
| `FINALIZE_WORKERS` | `1` | parallele Nachbearbeitungen |
| `STORYBOARD_INTERVAL` | `20s` | Abstand der Vorschaubilder |
| `CHAT_CHUNK` | `5m` | Länge einer Chat-Replay-Datei (mindestens 1 min) |
| `THIRD_PARTY_EMOTES` | `true` | 7TV-, BTTV- und FFZ-Emotes |
| `CHAT_HISTORY` | `true` | letzte Minuten Chat beim Aufnahmestart nachladen |
| `APP_NAME` | `Rewind` | Servername in den App-Einstellungen |
| `LOG_LEVEL` | `info` | `debug`, `info`, `warn`, `error` |
| `LOG_FORMAT` | `text` | `text` oder `json` |
| `HTTP_ADDR` | `:8080` | Listen-Adresse im Container |
| `DATA_DIR` | `/data` | SQLite und Kanalbilder (lokale Platte) |
| `RECORDINGS_DIR` | `/recordings` | laufende Aufnahmen (lokale Platte) |
| `ARCHIVE_DIR` | `/archive` | fertige Aufnahmen (Storage Box) |
| `WEB_DIR` | `/app/web` | gebaute Web-App |
| `STREAMLINK_PATH`, `FFMPEG_PATH`, `FFPROBE_PATH` | aus `PATH` | Programmpfade |

`HTTP_ADDR`, die `*_DIR`- und `*_PATH`-Variablen setzt das Image passend; sie sind nur für die lokale Entwicklung interessant. `DATA_DIR`, `RECORDINGS_DIR` und `ARCHIVE_DIR` müssen getrennte Ordner sein.

**Docker Compose** (`deploy/docker-compose.yml`):

| Variable | Beispiel | Bedeutung |
|---|---|---|
| `BIND_ADDR` | `10.8.0.1` | Host-IP, auf der der Port lauscht (VPN-IP; nie `0.0.0.0`) |
| `HTTP_PORT` | `8080` | Port auf dem Host |
| `DATA_PATH` | `/opt/rewind/data` | → `/data` |
| `RECORDINGS_PATH` | `/srv/rewind/recordings` | → `/recordings` |
| `ARCHIVE_PATH` | `/mnt/storagebox/rewind` | → `/archive` |
| `IMAGE_TAG` | `latest` | Image-Version |
| `TZ` | `Europe/Berlin` | Zeitzone (Ordnernamen, Logs) |

### Werbung
Ohne Token schneidet streamlink Twitch-Werbung heraus; im Video entsteht dort eine kurze Lücke. Ganz ohne Unterbrechung geht es mit einem Account mit **Turbo** oder einem **Abo** des Kanals:

1. In einem eigenen Browser-Profil oder Inkognito-Fenster mit diesem Account bei twitch.tv einloggen.
2. DevTools (F12) → *Application/Storage* → *Cookies* → `https://www.twitch.tv` → Wert von **`auth-token`** kopieren.
3. Das Fenster **schließen, ohne dich auszuloggen** – ein Logout macht das Token sofort ungültig.
4. Als `TWITCH_USER_OAUTH=` in die `.env` eintragen, `docker compose up -d`.

Das Token gilt, bis die Sitzung endet (Logout, Passwort- oder 2FA-Änderung, „Von allen Geräten abmelden“), meist Monate. rewind prüft es beim Start, alle 6 Stunden und sofort, wenn Aufnahmen mit Token wiederholt ohne Daten abbrechen. Ist es abgelaufen, wird **trotzdem weiter aufgenommen** (dann mit herausgeschnittener Werbung); `/admin` zeigt eine Warnung, im Log steht `TWITCH_USER_OAUTH is invalid`. Das Token ist ein vollwertiger Login – es gehört nur in die `.env`.

## Apps

- **Web**: `http://<VPN-IP>:8080`, in jedem Browser.
- **Android / Windows**: einmal von den [Releases](https://github.com/DerSeb90/twitch-vod-archiver/releases) installieren:
  - Android: `app-arm64-v8a-release.apk` (fast alle aktuellen Handys; ältere 32-Bit-Geräte: `app-armeabi-v7a-release.apk`)
  - Windows: `Rewind-Setup-X.Y.Z.exe` (ohne Admin-Rechte) oder `Rewind-Windows-Portable-X.Y.Z.zip`

  Beim ersten Start die Server-Adresse eintragen, z. B. `http://10.8.0.1:8080`. **Updates** danach in der App: Einstellungen → *Nach Updates suchen*. Die App lädt die neue Version von GitHub, prüft die SHA-256-Prüfsumme und installiert sie (Android fragt beim ersten Mal, ob rewind Apps installieren darf; unter Windows läuft das Setup still und die App startet neu).

### Bedienung

| Seite | Was |
|---|---|
| `/` | **Gerade live**, **Weiterschauen** und alle ungesehenen Aufnahmen nach Tagen. *Gesehene anzeigen* blendet den Rest ein; Badge, ✓ beim Überfahren oder langes Drücken markiert als gesehen/ungesehen |
| `/channels`, `/c/<kanal>` | alle Kanäle, Kanalseite mit allen Aufnahmen |
| `/v/<id>` | Player: Chat daneben (mobil als Tab), Tastatur (Leertaste, ←/→, J/L, F, M, C), Doppelklick = Vollbild; am Handy doppelt tippen ±10 s, quer halten = Vollbild |
| `/admin` | Verwaltung (siehe oben) |

Laufende Aufnahmen steuern:
- **Pausieren** stoppt den Mitschnitt. **Fortsetzen** (nur solange der Kanal live ist) hängt einen neuen Teil an dieselbe Aufnahme; Chat aus der Pause wird nicht ins Video gestapelt. Geht der Kanal während der Pause offline, wird die Aufnahme abgeschlossen.
- **Abschließen** beendet die Aufnahme sofort; der Rest dieses Streams wird nicht mehr aufgenommen, der nächste wieder normal.

Chat läuft minimal versetzt? Im Player über das Uhr-Symbol oder in den Einstellungen verschieben.

## Entwicklung

### Lokal unter Windows (VS Code)
Einmalig – alles landet in `dev\` (gitignored), ohne Admin-Rechte:
```powershell
powershell -ExecutionPolicy Bypass -File scripts\dev-setup.ps1 -Demo
```
Das legt einen Python-venv mit streamlink an, lädt ffmpeg nach `dev\tools`, erzeugt `dev\data`, `dev\recordings`, `dev\archive` und eine `.env` aus der Vorlage. `-Demo` erzeugt eine Demo-Aufnahme (Testbild + Chat). Danach `TWITCH_CLIENT_ID` und `TWITCH_CLIENT_SECRET` in die `.env` eintragen und unter **Run and Debug** starten:

| Konfiguration | Was |
|---|---|
| **Server + App (Chrome)** | Go-Server mit Debugger auf `localhost:8080`, Flutter-Web mit Hot Reload auf `localhost:5173` |
| **Server + App (Windows)** | dasselbe mit der Windows-App |
| Server (Go) | nur der Server; die zuletzt gebaute Web-App liegt unter `http://localhost:8080` |

`.vscode/launch.json` setzt die Pfade nach `dev\`, `CORS_ORIGINS=http://localhost:5173` und kein `ADMIN_TOKEN`. Das komplette Image lässt sich auch lokal bauen: `docker compose -f docker-compose.dev.yml up --build`.

Flutter-Version: die in `.github/workflows/app.yml` gepinnte (passt zu `app/pubspec.lock`).

### Tests
```bash
cd server
go vet ./... && go test ./...      # Unit-Tests
go test -tags integration ./...    # inkl. ffmpeg-Pipeline (ffmpeg im PATH)
# echter Twitch-Kanal (ohne Zugangsdaten), prüft Aufnahme + Chat:
LIVE_CHANNEL=<kanal-der-gerade-live-ist> go test -tags live -v ./internal/recorder/ ./internal/chat/
cd ../app && flutter analyze && flutter test
```

### CI/CD
- **`docker.yml`**: Tests, danach Multi-Arch-Image (`amd64`, `arm64`) nach `ghcr.io/derseb90/twitch-vod-archiver` (`latest`, `sha-…`, Semver-Tags) – bei jedem Push auf `main`, bei Tags und **wöchentlich**, damit neue streamlink-Versionen automatisch ins Image kommen. Das Paket in GitHub auf **Public** stellen, dann braucht der Server kein `docker login`.
- **`app.yml`**: `flutter analyze` + `flutter test`, danach signierte Android-APKs und Windows-Build mit Inno-Setup-Installer. Ein **Release** entsteht mit einem Tag, die App-Version kommt aus dem Tag:
  ```bash
  git tag v1.1.0 && git push origin v1.1.0
  ```
- **APK-Signatur**: GitHub-Secrets `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`. **Den Schlüssel gut sichern** (Original lokal unter `%USERPROFILE%\.rewind-signing\`): Ohne ihn lassen sich Updates nicht mehr über die installierte App einspielen.

Secrets stehen ausschließlich in `.env` (gitignored) und in den GitHub-Secrets; das Repo enthält nur die Vorlage ohne Werte.
