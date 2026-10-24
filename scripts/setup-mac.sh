#!/usr/bin/env bash
# Richtet den Mac fuer TransitPlanner ein. Idempotent: mehrfach ausfuehren ist unproblematisch.
# Nutzung:  cd ~/Dev/TransitPlanner && ./scripts/setup-mac.sh
set -euo pipefail

say() { printf '\n==> %s\n' "$1"; }
have() { command -v "$1" >/dev/null 2>&1; }

say "Xcode pruefen"
if ! xcode-select -p >/dev/null 2>&1 || [ ! -d "/Applications/Xcode.app" ]; then
  echo "Xcode (nicht nur die Command Line Tools) wird ab Meilenstein 2 gebraucht."
  echo "Installiere es aus dem App Store oder mit:  brew install xcodes && xcodes install --latest"
else
  echo "OK: $(xcodebuild -version | head -1)"
fi

say "Homebrew pruefen"
if ! have brew; then
  echo "Homebrew fehlt. Installieren mit:"
  echo '  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
  exit 1
fi

say "Pakete installieren (node@22, xcodegen, swiftlint, swift-format, jq)"
brew install node@22 xcodegen swiftlint swift-format jq || true
brew link --overwrite --force node@22 >/dev/null 2>&1 || true
echo "Node: $(node -v)"

say "Claude Code CLI pruefen"
if have claude; then
  echo "OK: $(claude --version 2>/dev/null | head -1)"
else
  echo "Claude Code fehlt:  npm install -g @anthropic-ai/claude-code"
fi

say "Backend-Abhaengigkeiten"
cd "$(dirname "$0")/../backend"
npm ci
if [ ! -f .env ]; then
  cp .env.example .env
  token="$(openssl rand -base64 36 | tr -d '\n')"
  # macOS-sed braucht das leere Argument nach -i
  sed -i '' "s|^API_TOKEN=.*|API_TOKEN=${token}|" .env
  echo ".env angelegt, API_TOKEN erzeugt."
fi

say "Tests"
npm test

say "Fertig"
echo "Live-Test gegen die DB:  cd backend && npm run smoke"
echo "Server lokal starten:    cd backend && npm run dev"
