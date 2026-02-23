# Steam-Link-Cloud-Server
A Nextcloud Installation with Steam Link to stream to with AMP and Pi-hole.

## Raspberry Pi Script: Steam Link automatisch mit HDMI/Controller

Dieses Repository enthält jetzt ein Script für **Raspberry Pi OS Lite 64-bit**, das folgendes tut:

- installiert Steam Link und benötigte Tools (optional)
- startet Steam Link automatisch, sobald ein HDMI-Display erkannt wird
- sendet bei neu verbundenem Controller ein CEC-Power-On (TV/Monitor einschalten)
- beendet Steam Link automatisch, wenn kein aktives HDMI-Display mehr erkannt wird

### Dateien

- `steamlink-hdmi-daemon.sh`
- `steamlink-hdmi-daemon.service`

### Installation auf dem Pi

```bash
chmod +x steamlink-hdmi-daemon.sh
sudo cp steamlink-hdmi-daemon.sh /usr/local/bin/
sudo cp steamlink-hdmi-daemon.service /etc/systemd/system/
sudo /usr/local/bin/steamlink-hdmi-daemon.sh --install
sudo systemctl daemon-reload
sudo systemctl enable --now steamlink-hdmi-daemon.service
```

### Wichtig bei „Steam Link startet, aber öffnet sich nicht“

Die Service-Datei läuft als root (für Hardware-Events), startet **Steam Link selbst aber immer als Nicht-Root-User**. Das behebt den Fehler `cannot run as root user`.

- Falls dein Benutzer nicht `pi` heißt, passe in `steamlink-hdmi-daemon.service` `Environment=STEAMLINK_USER=...` an.
- Log prüfen:

```bash
journalctl -u steamlink-hdmi-daemon.service -f
cat /tmp/steamlink-daemon.log
```

### Hinweise

- CEC Power-On funktioniert nur, wenn TV/Monitor CEC unterstützt und CEC aktiviert ist.
- Bei mehreren HDMI-Ausgängen versucht das Script den ersten verbundenen HDMI-Port als Steam-Link-Display zu verwenden.
