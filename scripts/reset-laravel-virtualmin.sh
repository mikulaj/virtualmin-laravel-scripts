#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Bezpečný reset skript pre opakované pokusy s Laravel projektom na existujúcej Virtualmin doméne.

Použitie:
  sudo bash reset-laravel-virtualmin.sh \
    --domain nbv.sk \
    --user nbv

Voliteľné:
  --db-name NAME            default: <user>
  --db-user NAME            default: <user>
  --app-dir PATH            default: /home/<user>/laravel-app
  --php-version VERSION     default: 8.4
  --drop-db                 zmaže aj PostgreSQL databázu
  --drop-role               zmaže aj PostgreSQL rolu/usera (vyžaduje --drop-db)
  --remove-supervisor-only  zmaže len supervisor config a cron, projekt ponechá
  --yes                     bez interaktívneho potvrdenia
  --dry-run                 iba vypíše kroky, nič nemení
  -h, --help                zobrazí túto nápovedu

Čo resetuje štandardne:
- /home/<user>/laravel-app
- Laravel cron riadok používateľa
- supervisor worker config pre daného usera

Čo NEROBÍ:
- nemaže Virtualmin doménu
- nemaže nginx Virtualmin site config domény
- nemaže SSL certifikáty
- nemaže doménového linux používateľa
USAGE
}

if [[ $# -eq 0 ]]; then
  usage
  exit 0
fi

DOMAIN=""
DOMAIN_USER=""
DB_NAME=""
DB_USER=""
APP_DIR=""
PHP_VERSION="8.4"
DROP_DB=0
DROP_ROLE=0
REMOVE_SUPERVISOR_ONLY=0
ASSUME_YES=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="$2"; shift 2 ;;
    --user) DOMAIN_USER="$2"; shift 2 ;;
    --db-name) DB_NAME="$2"; shift 2 ;;
    --db-user) DB_USER="$2"; shift 2 ;;
    --app-dir) APP_DIR="$2"; shift 2 ;;
    --php-version) PHP_VERSION="$2"; shift 2 ;;
    --drop-db) DROP_DB=1; shift ;;
    --drop-role) DROP_ROLE=1; shift ;;
    --remove-supervisor-only) REMOVE_SUPERVISOR_ONLY=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "Skript spusti ako root." >&2; exit 1; }
[[ -n "$DOMAIN" && -n "$DOMAIN_USER" ]] || { usage; exit 1; }

DB_NAME="${DB_NAME:-${DOMAIN_USER}}"
DB_USER="${DB_USER:-${DOMAIN_USER}}"
APP_DIR="${APP_DIR:-/home/${DOMAIN_USER}/laravel-app}"
PHP_FPM_SERVICE="php${PHP_VERSION}-fpm"
SUPERVISOR_CONF="/etc/supervisor/conf.d/${DOMAIN_USER}-laravel-worker.conf"
CRONLINE="* * * * * cd ${APP_DIR} && php artisan schedule:run >> /dev/null 2>&1"

log() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
die() { echo "[ERROR] $*" >&2; exit 1; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "+ $*"
  else
    eval "$@"
  fi
}

validate_pg_identifier() {
  local value="$1"
  local label="$2"
  [[ "$value" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || die "${label}='${value}' nie je bezpečný PostgreSQL identifikátor."
}

confirm() {
  local prompt="$1"
  if [[ $ASSUME_YES -eq 1 || $DRY_RUN -eq 1 ]]; then
    return 0
  fi

  read -r -p "$prompt [yes/N]: " reply
  [[ "$reply" == "yes" ]]
}

remove_cron() {
  if ! id "$DOMAIN_USER" >/dev/null 2>&1; then
    warn "Používateľ ${DOMAIN_USER} neexistuje, cron preskakujem."
    return 0
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "+ remove cron line for ${DOMAIN_USER}: ${CRONLINE}"
    return 0
  fi

  local tmp
  tmp="$(mktemp)"
  if crontab -u "$DOMAIN_USER" -l > "$tmp" 2>/dev/null; then
    grep -Fvx "$CRONLINE" "$tmp" > "${tmp}.new" || true
    crontab -u "$DOMAIN_USER" "${tmp}.new"
    rm -f "$tmp" "${tmp}.new"
    log "Cron pre ${DOMAIN_USER} bol upravený."
  else
    rm -f "$tmp"
    warn "Používateľ ${DOMAIN_USER} nemá crontab, preskakujem."
  fi
}

remove_supervisor() {
  if [[ -f "$SUPERVISOR_CONF" ]]; then
    run "rm -f '${SUPERVISOR_CONF}'"
    if command_exists supervisorctl; then
      run "supervisorctl reread || true"
      run "supervisorctl update || true"
      run "supervisorctl stop ${DOMAIN_USER}-laravel-worker:* || true"
      run "supervisorctl remove ${DOMAIN_USER}-laravel-worker:* || true"
    fi
  else
    warn "Supervisor config ${SUPERVISOR_CONF} neexistuje, preskakujem."
  fi
}

remove_app_dir() {
  if [[ "$APP_DIR" != /home/${DOMAIN_USER}/* ]]; then
    die "Bezpečnostná poistka: APP_DIR musí byť pod /home/${DOMAIN_USER}/"
  fi

  if [[ -d "$APP_DIR" ]]; then
    run "rm -rf --one-file-system '${APP_DIR}'"
  else
    warn "Adresár ${APP_DIR} neexistuje, preskakujem mazanie projektu."
  fi
}

drop_db_and_role() {
  validate_pg_identifier "$DB_NAME" "DB_NAME"
  validate_pg_identifier "$DB_USER" "DB_USER"

  if ! command_exists psql; then
    die "Chýba psql. Nemôžem zmazať PostgreSQL objekty."
  fi

  if [[ $DROP_DB -eq 1 ]]; then
    log "Mažem PostgreSQL databázu ${DB_NAME}..."
    run "sudo -u postgres psql -v ON_ERROR_STOP=1 -d postgres -c \"SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${DB_NAME}' AND pid <> pg_backend_pid();\" >/dev/null"
    run "sudo -u postgres psql -v ON_ERROR_STOP=1 -d postgres -c \"DROP DATABASE IF EXISTS ${DB_NAME};\""
  fi

  if [[ $DROP_ROLE -eq 1 ]]; then
    log "Mažem PostgreSQL rolu ${DB_USER}..."
    run "sudo -u postgres psql -v ON_ERROR_STOP=1 -d postgres -c \"DROP ROLE IF EXISTS ${DB_USER};\""
  fi
}

[[ $DROP_ROLE -eq 0 || $DROP_DB -eq 1 ]] || die "--drop-role vyžaduje aj --drop-db"

if [[ ! -d "/home/${DOMAIN_USER}" ]]; then
  warn "Domovský adresár /home/${DOMAIN_USER} neexistuje."
fi

log "Pripravujem reset pre doménu ${DOMAIN}"
log "User: ${DOMAIN_USER}"
log "App dir: ${APP_DIR}"
log "Drop DB: ${DROP_DB}"
log "Drop role: ${DROP_ROLE}"
log "Len supervisor/cron: ${REMOVE_SUPERVISOR_ONLY}"

if ! confirm "Naozaj chceš pokračovať v resete?"; then
  die "Reset zrušený používateľom."
fi

remove_cron
remove_supervisor

if [[ $REMOVE_SUPERVISOR_ONLY -eq 0 ]]; then
  remove_app_dir
fi

if [[ $DROP_DB -eq 1 || $DROP_ROLE -eq 1 ]]; then
  if confirm "Pokračovať aj v mazaní PostgreSQL objektov?"; then
    drop_db_and_role
  else
    warn "Mazanie PostgreSQL objektov preskočené."
  fi
fi

run "systemctl restart ${PHP_FPM_SERVICE} || true"
run "systemctl restart nginx || true"

log "Reset dokončený."
echo
echo "Ďalší pokus o deploy potom spusti napríklad takto:"
echo "  bash setup-laravel-virtualmin.sh --domain ${DOMAIN} --user ${DOMAIN_USER} --db-pass 'NOVE_HESLO' --skip-packages"
