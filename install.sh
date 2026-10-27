#!/bin/bash
# Installe les apps Traffik sur ce Mac (sans blocage Gatekeeper) :
#   curl -fsSL https://rayanesabi.github.io/traffik-apps/install.sh | bash -s clac halo
#   curl -fsSL https://rayanesabi.github.io/traffik-apps/install.sh | bash -s toutes
# Pour chaque app : téléchargement, vérification de l'empreinte SHA-256, de la signature Ed25519 et du certificat
# de signature, installation dans /Applications (ou ~/Applications), retrait de la quarantaine, ouverture.
set -u
BASE="${TRAFFIK_BASE:-https://rayanesabi.github.io/traffik-apps}"   # TRAFFIK_BASE / TRAFFIK_DEST / TRAFFIK_NO_OPEN : tests uniquement
PUBKEY="V6TU3jcjyA1ivs/qDIvZHUN5DdiY6xFn72eVuIPsNow="
CERT_SHA256="6a7ee9c5ce004ef10ec9fa2b5bc4b901aedf37cf8ed81cfe032a15006b97b0c5"
VERIFY_JS_SHA256="32fc5d6eae1a7dd0dcdfdc2c5d546c6beffebf382e95504f476629a1d2caf493"

say()  { printf '%s\n' "$*"; }
warn() { printf '⚠️  %s\n' "$*" >&2; }
fail() { printf '❌ %s\n' "$*" >&2; }
sha256() { /usr/bin/openssl dgst -sha256 -r "$1" 2>/dev/null | cut -d' ' -f1 | tr -d '*'; }
fetch() { /usr/bin/curl -fsSL --retry 3 --connect-timeout 15 "$1" -o "$2"; }

say ""
say "Traffik Apps — installation"
say "───────────────────────────"

# Prérequis : macOS 26+, et le bon processeur (vérifié app par app).
OS=$(/usr/bin/sw_vers -productVersion)
MAJOR=${OS%%.*}
if [ "${MAJOR:-0}" -lt 26 ]; then
  fail "Il faut macOS 26 (Tahoe) ou plus récent. Ce Mac a macOS $OS : mettez-le à jour dans Réglages Système › Général › Mise à jour de logiciels."
  exit 1
fi
if [ "$(/usr/sbin/sysctl -in hw.optional.arm64 2>/dev/null)" = "1" ]; then ARCH=arm64; else ARCH=x86_64; fi

if [ $# -eq 0 ]; then
  say "Indiquez les apps à installer, par exemple :"
  say "  curl -fsSL $BASE/install.sh | bash -s clac"
  say "  curl -fsSL $BASE/install.sh | bash -s toutes"
  exit 1
fi

TMP=$(/usr/bin/mktemp -d /tmp/traffik-install.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

SLUGS=""
for a in "$@"; do
  a=$(printf '%s' "$a" | tr 'A-Z' 'a-z')
  case "$a" in
    toutes|tout|all)
      fetch "$BASE/apps.txt" "$TMP/apps.txt" || { fail "Liste des apps inaccessible (connexion ?)."; exit 1; }
      SLUGS="$SLUGS $(tr '\n' ' ' < "$TMP/apps.txt")" ;;
    *) SLUGS="$SLUGS $a" ;;
  esac
done

# Vérificateur de signature Ed25519 (JavaScriptCore, présent sur tous les Mac) dont l'empreinte est fixée ici.
fetch "$BASE/verify-ed25519.js" "$TMP/verify.js" || { fail "Téléchargement du vérificateur impossible (connexion ?)."; exit 1; }
if [ "$(sha256 "$TMP/verify.js")" != "$VERIFY_JS_SHA256" ]; then fail "Le vérificateur de signature a été modifié : installation annulée."; exit 1; fi

OK=0; KO=0; INSTALLED=""
for slug in $SLUGS; do
  case "$slug" in *[!a-z0-9-]*|"") fail "Nom d'app invalide : $slug"; KO=$((KO+1)); continue ;; esac
  FEED="$TMP/$slug.json"
  if ! fetch "$BASE/feeds/$slug.json" "$FEED"; then fail "« $slug » : app inconnue ou pas encore publiée."; KO=$((KO+1)); continue; fi
  get() { /usr/bin/plutil -extract "$1" raw -o - "$FEED" 2>/dev/null; }
  NAME=$(get name); BID=$(get bundleId); VER=$(get version); BUILD=$(get build)
  URL=$(get url); SHA=$(get sha256); SIG=$(get signature); MINOS=$(get minimumSystemVersion)
  ARCHS=$(/usr/bin/plutil -extract archs json -o - "$FEED" 2>/dev/null)
  case "$NAME" in *[!A-Za-z0-9\ ]*|"") fail "Fiche de « $slug » invalide."; KO=$((KO+1)); continue ;; esac
  case "$ARCHS" in
    *"\"$ARCH\""*) ;;
    *) fail "$NAME ne fonctionne pas sur ce Mac : il faut un Mac Apple Silicon (M1 ou plus récent)."; KO=$((KO+1)); continue ;;
  esac
  if [ "${MAJOR}" -lt "${MINOS%%.*}" ]; then fail "$NAME demande macOS $MINOS ou plus récent."; KO=$((KO+1)); continue; fi

  say ""
  say "⬇︎  $NAME ${VER}…"
  if ! fetch "$URL" "$TMP/$slug.zip"; then fail "Téléchargement de $NAME impossible."; KO=$((KO+1)); continue; fi
  if [ "$(sha256 "$TMP/$slug.zip")" != "$SHA" ]; then fail "$NAME : fichier incomplet ou modifié, installation refusée."; KO=$((KO+1)); continue; fi
  MSG=$(printf 'traffik-update-v1\n%s\n%s\n%s' "$BID" "$BUILD" "$SHA")
  if [ "$(/usr/bin/osascript -l JavaScript "$TMP/verify.js" "$PUBKEY" "$MSG" "$SIG" 2>/dev/null)" != "ok" ]; then
    fail "$NAME : signature Ed25519 invalide, installation refusée."; KO=$((KO+1)); continue
  fi
  say "   ✓ signature vérifiée"
  mkdir -p "$TMP/$slug"
  /usr/bin/ditto -x -k "$TMP/$slug.zip" "$TMP/$slug" || { fail "$NAME : archive illisible."; KO=$((KO+1)); continue; }
  APP="$TMP/$slug/$NAME.app"
  if [ ! -d "$APP" ] || [ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$APP/Contents/Info.plist" 2>/dev/null)" != "$BID" ]; then
    fail "$NAME : contenu inattendu, installation refusée."; KO=$((KO+1)); continue
  fi
  if ! /usr/bin/codesign --verify --strict "$APP" 2>/dev/null; then fail "$NAME : signature de code invalide."; KO=$((KO+1)); continue; fi
  (cd "$TMP/$slug" && /usr/bin/codesign -d --extract-certificates "$APP" >/dev/null 2>&1)
  if [ "$(sha256 "$TMP/$slug/codesign0")" != "$CERT_SHA256" ]; then fail "$NAME : certificat de signature inconnu."; KO=$((KO+1)); continue; fi
  say "   ✓ certificat Traffik Web vérifié"

  DEST="${TRAFFIK_DEST:-/Applications}"
  [ -n "${TRAFFIK_DEST:-}" ] && mkdir -p "$DEST"
  if [ ! -w "$DEST" ]; then DEST="$HOME/Applications"; mkdir -p "$DEST"; fi
  TARGET="$DEST/$NAME.app"
  # L'app qu'on remplace est ouverte : on la ferme proprement (seulement celle de cet emplacement).
  for pid in $(/usr/bin/pgrep -x "$NAME"); do
    case "$(/bin/ps -o comm= -p "$pid")" in
      "$TARGET"/*)
        say "   fermeture de ${NAME}…"
        kill -TERM "$pid" 2>/dev/null
        for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
        kill -KILL "$pid" 2>/dev/null ;;
    esac
  done
  if [ -e "$TARGET" ]; then
    mv "$TARGET" "$TMP/ancien-$slug.app" || { fail "Impossible de remplacer $TARGET."; KO=$((KO+1)); continue; }
  fi
  if ! /usr/bin/ditto "$APP" "$TARGET"; then
    [ -e "$TMP/ancien-$slug.app" ] && mv "$TMP/ancien-$slug.app" "$TARGET"
    fail "Copie de $NAME dans $DEST impossible."; KO=$((KO+1)); continue
  fi
  /usr/bin/xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$TARGET" >/dev/null 2>&1
  if [ -z "${TRAFFIK_NO_OPEN:-}" ]; then
    /usr/bin/open "$TARGET"
    say "✅ $NAME $VER installée dans $DEST et ouverte"
  else
    say "✅ $NAME $VER installée dans $DEST"
  fi
  OK=$((OK+1)); INSTALLED="$INSTALLED $NAME"
done

say ""
if [ $OK -gt 0 ]; then
  say "Terminé :$INSTALLED."
  say "Au premier lancement, chaque app explique les autorisations dont elle a besoin (bouton « Autoriser »)."
  say "Les mises à jour sont ensuite automatiques."
fi
[ $KO -eq 0 ]
