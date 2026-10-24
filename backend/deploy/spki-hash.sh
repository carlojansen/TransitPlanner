#!/usr/bin/env bash
# Berechnet SPKI-SHA-256-Pins (Base64) fuer das Public-Key-Pinning der App (AGENT.md 3.2.2).
#
#   ./spki-hash.sh host api.example.de       Pin des live ausgelieferten Schluessels
#   ./spki-hash.sh key backup-key.pem        Pin aus einer Schluesseldatei (privat oder oeffentlich)
#   ./spki-hash.sh new-backup backup-key.pem Erzeugt einen Offline-Backup-Schluessel (P-256) und gibt seinen Pin aus
#
# In der App IMMER zwei Pins hinterlegen: aktueller Schluessel + Backup-Schluessel.
# Den Backup-Schluessel offline aufbewahren (nicht auf dem Server). Faellt der aktuelle Schluessel
# weg, wird das Zertifikat mit dem Backup-Schluessel ausgestellt und die App laeuft ohne Update weiter.
#
# Notfall (aktueller Schluessel kompromittiert/verloren). Caddys ACME-Automatik uebernimmt keinen
# vorgegebenen Schluessel, daher manuell:
#   openssl req -new -key backup-key.pem -subj "/CN=api.example.de" -out api.csr
#   sudo certbot certonly --standalone --csr api.csr      (Port 80 kurz frei machen)
#   Im Caddyfile:  tls /etc/caddy/0000_cert.pem /etc/caddy/backup-key.pem  { protocols tls1.3 }
# Danach in der naechsten App-Version einen neuen Backup-Pin nachziehen.
set -euo pipefail

pin_from_pubkey_pem() {
  openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | openssl enc -base64
}

mode="${1:-}"; arg="${2:-}"
case "$mode" in
  host)
    [ -n "$arg" ] || { echo "Hostname fehlt"; exit 1; }
    openssl s_client -connect "${arg}:443" -servername "$arg" -tls1_3 </dev/null 2>/dev/null \
      | openssl x509 -pubkey -noout | pin_from_pubkey_pem
    ;;
  key)
    [ -f "$arg" ] || { echo "Datei fehlt: $arg"; exit 1; }
    if grep -q "PUBLIC KEY" "$arg"; then pin_from_pubkey_pem < "$arg"
    else openssl pkey -in "$arg" -pubout | pin_from_pubkey_pem; fi
    ;;
  new-backup)
    [ -n "$arg" ] || { echo "Zieldatei fehlt"; exit 1; }
    [ ! -e "$arg" ] || { echo "Existiert bereits: $arg"; exit 1; }
    (umask 077; openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$arg")
    openssl pkey -in "$arg" -pubout | pin_from_pubkey_pem
    ;;
  *)
    sed -n '2,19p' "$0"; exit 1;;
esac
