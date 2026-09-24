# rewind – Twitch Livestream-Archiv

Schlanker Nachbau von [Ganymede](https://github.com/zibbp/ganymede), aber bewusst reduziert:

- **Nur Livestreams**: kein VOD-Download. Ein Kanal wird hinzugefügt, danach wird jeder Stream automatisch in **bester Qualität** (Source, ohne Re-Encoding) mitgeschnitten, **inklusive Chat**.
- **Live schauen mit Zurückspulen**: Laufende Aufnahmen lassen sich schon während des Streams ansehen, inklusive Chat. Bis zum Aufnahmestart zurückspulen geht auch. Der Rückstand zu Twitch beträgt ca. 15–25 s.
- **Anschauen wie auf livearchive.net**: Flutter-App (Web, Android, Windows, macOS, Linux, iOS) mit Chat-Replay (Twitch-, 7TV-, BTTV- und FFZ-Emotes, Badges), Vorschaubildern beim Spulen, Chat-Heatmap auf der Zeitleiste, Kapiteln bei Kategoriewechseln und „Weiterschauen“.
- **Verwaltung getrennt** unter `/admin`: Kanäle hinzufügen, pausieren oder entfernen, Aufnahmen löschen. Laufende Aufnahmen lassen sich **pausieren**, **fortsetzen** oder **abschließen**.
- **Kein Login zum Anschauen.** Gedacht für den Betrieb hinter einem VPN. Nur die Verwaltung lässt sich per `ADMIN_TOKEN` absichern.
- **Go-Backend** (ein Binary, SQLite, keine weiteren Dienste), `streamlink` + `ffmpeg` im selben Container.

```
Twitch ──HLS──▶ streamlink ─pipe─▶ ffmpeg (copy) ──▶ /recordings/<vod>/part-000/index.m3u8 + 4-s-Segmente
                                                     (lokale NVMe, absturzsicher, live abspielbar)
       ──IRC──▶ Chat-Recorder ─▶ /recordings/<vod>/chat.ndjson
                     │ Stream vorbei
                     ▼
               Finalizer: Thumbnail, Storyboard, Chat-Chunks (lokal)
                          ffmpeg-Remux ohne Re-Encoding ──▶ Storage Box (SMB)
                     ▼
/archive/<kanal>/<datum>_<id>/video.mp4 · thumb.jpg · storyboard/ · chat/ · info.json
```

---

## Welcher Hetzner-Server?

**Empfehlung: Hetzner Cloud CX43** – 8 vCPU (shared), 16 GB RAM, **160 GB NVMe**, 20 TB Traffic, **15,99 €/Monat netto**
(Preis nach der [Preisanpassung vom 15.06.2026](https://docs.hetzner.com/general/infrastructure-and-availability/price-adjustment/)).
Standort **Falkenstein (fsn1) oder Nürnberg (nbg1)**, die Storage Box ebenfalls in **Deutschland** buchen, damit der SMB-Traffic im Hetzner-Netz bleibt.
Betriebssystem: **Debian 13** oder **Ubuntu 24.04**, beides wird vom Setup-Skript unterstützt.

Warum genau dieser:

| | Bedarf bei 3 parallelen Streams | CX43 |
|---|---|---|
| Download | Twitch-Source max. ~8 Mbit/s pro Stream → **~24 Mbit/s** | ≫ 1 Gbit/s |
| CPU | kein Transcoding. streamlink ~5 % eines Kerns pro Stream; Nachbearbeitung (Remux, Keyframe-Vorschaubilder) 1–3 min pro 8-h-Stream | 8 vCPU: Nachbearbeitung läuft neben 3 Aufnahmen ohne Ruckler |
| RAM | ~3 × 100 MB (streamlink) + Go + ffmpeg | 16 GB, großzügig Page-Cache für die Nachbearbeitung |
| **Lokale Platte** | 8 Mbit/s ≈ **3,6 GB/h**. 3 × 12 h Marathon ≈ **130 GB** Puffer | **160 GB** reicht für 3 lange Streams gleichzeitig |

Das Nadelöhr ist die **lokale Platte**, nicht die CPU. Deshalb:

- **CX33** (4 vCPU, 8 GB, 80 GB, 8,49 €) reicht nur, wenn höchstens 3 × ~7 h gleichzeitig laufen. Alternativ CX33 mit Volume (z. B. 150 GB), dann ist der Puffer aber Netzwerkspeicher statt NVMe.
- **CPX32** (35,49 €) oder **CCX**: kein Vorteil, weil nicht transkodiert wird.
- **CAX31** (ARM, 8 vCPU, 16 GB, 160 GB, 20,99 €) funktioniert auch, das Image wird für `amd64` **und** `arm64` gebaut. Kostet aber mehr als der CX43.

**Storage Box** (Archiv, SMB): 1 h Source ≈ 3,6 GB.

| Box | Größe | ca. Stunden Material | Preis (Stand 02/2026) |
|---|---|---|---|
| BX11 | 1 TB | ~280 h | – |
| **BX21** | 5 TB | **~1.400 h** | 10,90 € |
| BX31 | 10 TB | ~2.800 h | 20,80 € |
| BX41 | 20 TB | ~5.600 h | – |

Traffic zur Storage Box ist unbegrenzt. Zuschauen über das VPN zählt zum 20-TB-Kontingent des Servers (≈ 5.500 Stunden Video). Preise vor der Buchung bitte in der Hetzner Console prüfen.

---

## Installation

### 1. Twitch-App anlegen
[dev.twitch.tv/console/apps](https://dev.twitch.tv/console/apps) → *Register Your Application*: Name beliebig, OAuth Redirect `http://localhost`, Kategorie *Other*, Client-Typ *Confidential*. **Client-ID** und **Client-Secret** notieren.

### 2. Server + Storage Box
1. Cloud-Server **CX43** (Debian 13 / Ubuntu 24.04) und **Storage Box** (z. B. BX21) am selben Standort (Deutschland) anlegen.
2. In der Storage Box **SMB-Support** aktivieren. Empfohlen ist ein **Sub-Account** nur für rewind.
3. Auf dem Server:
   ```bash
   curl -fsSL https://raw.githubusercontent.com/DerSeb90/twitch-vod-archiver/main/deploy/setup-host.sh -o setup-host.sh
   sudo SB_USER=u123456-sub1 SB_PASS='storagebox-passwort' bash setup-host.sh
   ```
   Das Skript installiert Docker und `cifs-utils` und bindet die Storage Box per `/etc/fstab` (SMB 3, systemd-Automount) unter `/mnt/storagebox` ein. Das Passwort liegt nur in `/etc/storagebox.cred` (chmod 600). Außerdem legt es `/opt/rewind` mit `docker-compose.yml` und `.env` an.

### 3. VPN
Die App hat bewusst keinen Login und läuft über **HTTP**. Sie darf deshalb **nur per VPN** erreichbar sein:
- **WireGuard** (z. B. [wg-easy](https://github.com/wg-easy/wg-easy)) oder **Tailscale**.
- In der `.env` setzt du `BIND_ADDR` auf die VPN-IP des Servers (z. B. `10.8.0.1` oder die `100.x`-Tailscale-IP).
- **Hetzner Cloud Firewall**: eingehend nur SSH (22/tcp) und den VPN-Port (z. B. 51820/udp). Wichtig: Docker umgeht `ufw`. Schutz bieten nur die Cloud Firewall und das `BIND_ADDR`-Binding.

### 4. Konfigurieren & starten
```bash
cd /opt/rewind
nano .env                  # TWITCH_CLIENT_ID, TWITCH_CLIENT_SECRET, ADMIN_TOKEN, BIND_ADDR
docker compose up -d
docker compose logs -f
```
Danach `http://<VPN-IP>:8080/admin` öffnen, Kanäle hinzufügen, fertig. Alle Optionen stehen kommentiert in [`deploy/.env.example`](deploy/.env.example).

Automatische Updates bei neuen Images: `docker compose --profile autoupdate up -d` (Watchtower).

### 5. Apps
- **Web**: `http://<VPN-IP>:8080`. Läuft in jedem Browser.
- **Android / Windows**: unter [Releases](https://github.com/DerSeb90/twitch-vod-archiver/releases) herunterladen:
  - `rewind-android.apk`: installieren; Updates lassen sich direkt drüberinstallieren
  - `rewind-windows-setup.exe`: Installer ohne Admin-Rechte, mit Startmenü- und optional Desktop-Verknüpfung; Updates einfach drüberinstallieren
  - `rewind-windows-portable.zip`: ohne Installation lauffähig
  
  Beim ersten Start die Server-Adresse eintragen, z. B. `http://10.8.0.1:8080`.
- iOS/macOS: `cd app && flutter build ios|macos` (braucht eigenes Apple-Signing).

---

## Bedienung

| Bereich | Was |
|---|---|
| `/` | Neueste Aufnahme als Hero, **Gerade live** (läuft mit, inkl. Zuschauer- und Chatzahl), Weiterschauen, Kanäle, alle VODs |
| `/c/<kanal>` | Kanalseite mit Banner, Logo, allen Aufnahmen |
| `/v/<id>` | Player: Chat-Replay daneben (mobil als Tab), Vorschaubilder beim Überfahren der Zeitleiste, Chat-Heatmap, Kapitel, Tastatur (Leertaste, ←/→, J/L, F, M, C) |
| `/admin` | **Verwaltung**: Kanal hinzufügen / pausieren / entfernen (inkl. aller VODs), laufende Aufnahmen pausieren / fortsetzen / abschließen, Aufnahmen löschen, fehlgeschlagene Verarbeitung erneut starten, Speicherplatz, Werbefrei-Status |

**Laufende Aufnahmen steuern**
- **Pausieren**: stoppt den Mitschnitt. Das bisher Aufgenommene ist sofort als normales Video mit Chat abspielbar.
- **Fortsetzen**: nur solange der Kanal noch live ist. Der neue Teil wird an **dieselbe** Aufnahme angehängt. Chat aus der Pause wird nicht in das Video gestapelt.
- **Abschließen**: beendet die Aufnahme sofort, der Rest dieses Streams wird nicht mehr aufgenommen. Beim nächsten Stream nimmt rewind wieder normal auf.
- Pausiert und der Kanal geht offline: Die Aufnahme wird automatisch abgeschlossen und auf die Storage Box verschoben.

Chat läuft minimal versetzt? Im Player über das Uhr-Symbol oder in den Einstellungen um ±x Sekunden verschieben.

---

## Wie es funktioniert

- **Live-Erkennung**: Helix `GET /streams` alle 30 s für alle Kanäle in einem Request (App-Token, Client-Credentials).
- **Video**: `streamlink --stdout … best` wird ohne Neukodierung an ffmpeg durchgereicht. ffmpeg schneidet daraus 4-s-MPEG-TS-Segmente plus HLS-Playlist auf die lokale NVMe. Die Segmente bleiben auch bei einem Absturz lesbar. Bricht der Stream kurz ab und kommt innerhalb von `OFFLINE_GRACE` (Standard 3 min) mit derselben Stream-ID zurück, entsteht ein weiterer Teil derselben Aufnahme. Dasselbe gilt für Pausieren und Fortsetzen und für Container-Updates während eines Streams.
- **Live/DVR**: Solange die Aufnahme noch lokal liegt, erzeugt der Server unter `/live/<vod>/index.m3u8` eine gemeinsame HLS-Playlist über alle Teile, getrennt durch Discontinuity-Markierungen. Der Chat dazu wird aus dem wachsenden Log live auf die Zeitleiste gerechnet. Die App spielt das mit hls.js (Web) bzw. mpv (nativ) ab.
- **Chat**: anonyme IRC-Verbindung (`justinfan…`), kein Account nötig. Beim Aufnahmestart werden die letzten Minuten Chat über den Dienst recent-messages nachgeladen, den auch Chatterino nutzt (`CHAT_HISTORY`). So beginnt das Replay nicht leer. Die Chat-Zeitleiste wird um den Rückstand korrigiert, mit dem die Aufnahme hinter dem Live-Punkt startet (~8 s). Gelöschte Nachrichten und Nachrichten gebannter Nutzer werden beim Finalisieren entfernt. Emote-Sets (7TV/BTTV/FFZ) und Badges werden zum Aufnahmezeitpunkt gesichert.
- **Finalisieren**: Thumbnail (bis 1080p), Storyboard-Sprites (nur Keyframes decodiert), Chat in 5-min-gzip-Chunks plus Aktivitäts-Histogramm, jeweils lokal. Danach Remux `ts → mp4` ohne Re-Encoding direkt auf die Storage Box und atomares Verschieben in den Zielordner. Die SQLite-DB liegt lokal (nie auf SMB). Jede Aufnahme bekommt zusätzlich eine `info.json` mit allen Metadaten.
- **Emotes & Badges** laufen über den Server (`/img`, nur Twitch-, BTTV-, 7TV- und FFZ-CDNs). Das umgeht fehlende CORS-Header (BTTV) im Browser, und einmal geladene Emotes bleiben lokal gespeichert, auch wenn sie später auf der Plattform gelöscht werden.
- **Browser-Wiedergabe**: Chrome und Edge können HLS inzwischen nativ, dort aber ohne Spulen in wachsenden Playlists. Die Web-App erzwingt deshalb das mitgelieferte hls.js (siehe `app/web/index.html`).
- **Ausliefern**: Go liefert MP4 mit HTTP-Range-Requests aus. Chat-Chunks sind vorkomprimiert, das Web-Bundle ist vorkomprimiert und wird per `Content-Encoding: gzip` ausgeliefert.

### Werbung
Ohne weitere Einstellung schneidet streamlink Twitch-Werbung heraus. Im Video entsteht an diesen Stellen eine kurze Lücke, Werbung ist keine zu sehen. Ganz ohne Unterbrechung geht es mit einem Account mit **Turbo** (werbefrei auf allen Kanälen) oder einem **Abo** des jeweiligen Kanals.

1. Am besten in einem **eigenen Browser-Profil oder Inkognito-Fenster** bei twitch.tv mit dem Turbo-Account einloggen.
2. DevTools (F12) → *Application/Storage* → *Cookies* → `https://www.twitch.tv` → Wert von **`auth-token`** kopieren.
3. Das Fenster **schließen, ohne dich auszuloggen**. Ein Logout macht das Token sofort ungültig.
4. Den Wert als `TWITCH_USER_OAUTH=` in die `.env` eintragen und `docker compose up -d` ausführen.

**Wie lange gilt das Token?** Es hat keine feste Laufzeit wie die 4-Stunden-App-Tokens. Es gilt, bis die Browser-Sitzung beendet wird: durch Logout, eine Passwort- oder 2FA-Änderung, „Von allen Geräten abmelden“ oder wenn Twitch Sitzungen selbst zurücksetzt. In der Praxis hält es meist Monate.
rewind prüft das Token beim Start und danach **alle 6 Stunden** (`id.twitch.tv/oauth2/validate`):
- **gültig**: Aufnahmen laufen werbefrei, `/admin` zeigt „Werbefrei über <account>“.
- **abgelaufen**: Die Aufnahme läuft **trotzdem weiter**, nur ohne Token, also mit herausgeschnittener Werbung. `/admin` zeigt eine Warnung, im Log steht `TWITCH_USER_OAUTH is invalid`. Dann ein neues Token eintragen und neu starten.

Das Token ist ein vollwertiger Login für den Account. Es gehört nur in die `.env` und darf nie ins Repo.

---

## Entwicklung

### Lokal auf Windows (VS Code)
Einmalig ausführen. Alles landet in `dev\` (gitignored), es wird nichts systemweit installiert und es braucht keine Admin-Rechte:
```powershell
powershell -ExecutionPolicy Bypass -File scripts\dev-setup.ps1 -Demo
```
Das Skript legt einen Python-venv mit **streamlink** an, lädt **ffmpeg** nach `dev\tools` und erzeugt die Ordner `dev\data`, `dev\recordings` und `dev\archive`. Fehlt die `.env`, wird sie aus der Vorlage angelegt. `-Demo` erzeugt eine Demo-Aufnahme (Testbild + Chat), damit die Oberfläche ohne laufenden Stream etwas zeigt.

Danach in der `.env` `TWITCH_CLIENT_ID` und `TWITCH_CLIENT_SECRET` eintragen und in VS Code unter **Run and Debug** eine der Konfigurationen starten:

| Konfiguration | Was |
|---|---|
| **Server + App (Chrome)** | Go-Server mit Debugger (Breakpoints) auf `localhost:8080`, Flutter-Web mit Hot Reload auf `localhost:5173` |
| **Server + App (Windows)** | dasselbe mit der nativen Windows-App |
| Server (Go) | nur der Server. Die zuletzt gebaute Web-App liegt unter `http://localhost:8080` |

Lokal gibt es kein `ADMIN_TOKEN`: `http://localhost:8080/admin` → Kanal eintragen → sobald er live geht, wird nach `dev\archive` aufgenommen.

Alternativ läuft das komplette Image wie auf dem Server in Docker Desktop:
```powershell
docker compose -f docker-compose.dev.yml up --build
```

### Tests
```bash
cd server
go test ./...                      # Unit-Tests
go test -tags integration ./...    # inkl. ffmpeg-Pipeline (ffmpeg im PATH)
# echter Twitch-Kanal (ohne Zugangsdaten), prüft Aufnahme + Chat:
LIVE_CHANNEL=<kanal-der-gerade-live-ist> go test -tags live -v ./internal/recorder/ ./internal/chat/
cd ../app && flutter analyze
```

### CI/CD
- **`.github/workflows/docker.yml`**: Tests, danach Multi-Arch-Image (`amd64`, `arm64`) nach `ghcr.io/derseb90/twitch-vod-archiver` (`latest`, `sha-…`, Semver-Tags). Läuft bei jedem Push auf `main`, bei Tags und **wöchentlich**, damit neue streamlink-Versionen (Twitch-Änderungen) automatisch ins Image kommen.
- **`.github/workflows/app.yml`**: `flutter analyze`, danach signierte Android-APK und Windows-Build mit Inno-Setup-Installer. Ein **neues Release** entsteht mit einem Tag:
  ```bash
  git tag v1.1.0 && git push origin v1.1.0
  ```
  Die Versionsnummer der Apps kommt aus dem Tag.
- **APK-Signatur**: Die Secrets `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS` und `ANDROID_KEY_PASSWORD` enthalten den Release-Schlüssel. **Den Schlüssel gut sichern** (Original liegt lokal unter `%USERPROFILE%\.rewind-signing\`). Geht er verloren, lassen sich neue APKs nicht mehr über die installierte App installieren.
- Nach dem ersten Push das Paket in GitHub unter *Packages → Package settings* auf **Public** stellen. Dann braucht der Server kein `docker login`.

### Secrets
Alle Secrets stehen ausschließlich in `.env` (gitignored) bzw. in GitHub-Secrets. Das Repo enthält nur [`deploy/.env.example`](deploy/.env.example) ohne Werte.
