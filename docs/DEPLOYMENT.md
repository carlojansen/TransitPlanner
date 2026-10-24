# Deployment-Runbook (Hetzner Cloud, Stand 24.10.2026)

Server: CAX11 (arm64, 2 vCPU, 4 GB), Ubuntu 26.04, Falkenstein. Firewall `transitplanner`: 22 nur eigene IP, 80 und 443 offen. Wechselt die eigene öffentliche IP (`curl https://api.ipify.org`), läuft SSH in einen Timeout; dann die Regel in der Hetzner Console anpassen.
Host: `static.18.209.104.178.clients.your-server.de` (Hetzner-rDNS, an die IP gebunden). Bei Umzug oder eigener Domain
muss der Name im Caddyfile und der Pin/Host in der App geändert werden.

## Aufbau (so wurde es gemacht)
1. SSH nur per Key: `/etc/ssh/sshd_config.d/00-hardening.conf` (`PasswordAuthentication no`).
2. Pakete: Node 22 (Ubuntu), Caddy 2.11 (offizielles Caddy-Repo, nicht das alte Ubuntu-Paket), git.
3. Benutzer `transitplanner` (System, ohne Login). Code unter `/opt/transitplanner/backend`.
4. Code kopieren: `rsync -a --delete --exclude node_modules --exclude .env backend/ root@<IP>:/opt/transitplanner/backend/`
   danach auf dem Server `npm ci && npm test && npm prune --omit=dev`.
5. `.env` nur auf dem Server: `API_TOKEN` per `openssl rand -base64 32`, `USER_AGENT` mit Kontakt-URL; optional `API_TOKENS` (kommagetrennt, Token-Rotation) und `RATE_LIMIT_LOCATIONS_PER_MINUTE`/`RATE_LIMIT_ROUTES_PER_MINUTE`/`RATE_LIMIT_REFRESH_PER_MINUTE` (Standards 20/8/12); `chown root:transitplanner`, `chmod 640`.
6. `deploy/transitplanner.service` nach `/etc/systemd/system/`, `systemctl enable --now transitplanner`.
7. `deploy/Caddyfile` nach `/etc/caddy/Caddyfile` (Host eintragen), `/var/log/caddy` gehört `caddy`, dann `systemctl restart caddy`.

## Update
Schritt 4 wiederholen, dann `systemctl restart transitplanner`.

## Prüfen
- `curl https://<host>/healthz` -> `{"status":"ok"}`; `/api/*` ohne Token -> 401.
- `curl --tls-max 1.2 https://<host>/healthz` muss scheitern.
- SPKI-Pin: `backend/deploy/spki-hash.sh host <host>`; zweiten Pin mit `new-backup` erzeugen und offline aufbewahren.
- Port 3000 von außen zu, Dienst lauscht nur auf 127.0.0.1; `systemd-analyze security transitplanner` (1.3 OK).

## Token lesen (für die App-Keychain, nicht in Chat oder Repo)
`ssh root@<IP> "grep ^API_TOKEN= /opt/transitplanner/backend/.env"`
