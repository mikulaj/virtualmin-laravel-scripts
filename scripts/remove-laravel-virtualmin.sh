#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Remove / reset skript pre Laravel + Filament + PostgreSQL na existujúcej Virtualmin doméne.

Použitie:
  sudo bash remove-laravel-virtualmin.sh \
    --domain nbv.sk \
    --user nbv

Voliteľné:
  --db-name NAME            default: <user>_matrika
  --db-user NAME            default: <user>_matrika_user
  --app-dir PATH            default: /home/<user>/laravel-app
  --drop-db                 zmaže PostgreSQL databázu
  --drop-role               zmaže PostgreSQL rolu / usera
  --remove-nginx-conf       zmaže nginx config domény a symlink v sites-enabled
  --remove-credentials      zmaže /root/<domain>-deploy-credentials-*.txt
  --yes                     bez interaktívneho potvrdenia
  --dry-run                 iba vypíše kroky, nič nemení
  -h, --help                zobrazí túto nápovedu

Poznámky:
- Skript NEMAŽE Virtualmin doménu ani linux usera domény.
- Bez prepínačov maže len Laravel projekt, cron a supervisor worker.
- --drop-role bez --drop-db zvyčajne nedáva zmysel, ak databáza ešte existuje.
EOF
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
DROP_DB=0
DROP_ROLE=0
REMOVE_NGINX_CONF=0
REMOVE_CREDENTIALS=0
ASSUME_YES=0
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="$2"; shift 2 ;;
    --user) DOMAIN_USER="$2"; shift 2 ;;
    --db-name) DB_NAME="$2"; shift 2 ;;
    --db-user) DB_USER="$2"; shift 2 ;;
    --app-dir) APP_DIR="$2"; shift 2 ;;
    --drop-db) DROP_DB=1; shift ;;
    --drop-role) DROP_ROLE=1; shift ;;
    --remove-nginx-conf) REMOVE_NGINX_CONF=1; shift ;;
    --remove-credentials) REMOVE_CREDENTIALS=1; shift ;;
    --yes) ASSUME_YES=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "Skript spusti ako root." >&2; exit 1; }
[[ -n "$DOMAIN" && -n "$DOMAIN_USER" ]] || { usage; exit 1; }

DB_NAME="${DB_NAME:-${DOMAIN_USER}_matrika}"
DB_USER="${DB_USER:-${DOMAIN_USER}_matrika_user}"
APP_DIR="${APP_DIR:-/home/${DOMAIN_USER}/laravel-app}"
NGINX_CONF="/etc/nginx/sites-available/${DOMAIN}.conf"
NGINX_ENABLED="/etc/nginx/sites-enabled/${DOMAIN}.conf"
SUPERVISOR_CONF="/etc/supervisor/conf.d/${DOMAIN_USER}-laravel-worker.conf"
CRONLINE="* * * * * cd ${APP_DIR} && php artisan schedule:run >> /dev/null 2>&1"

log() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
die() { echo "[ERROR] $*" >&2; exit 1; }

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
  [[ $ASSUME_YES -eq 1 || $DRY_RUN -eq 1 ]] && return 0

  echo
  echo "Chystám sa vykonať tieto operácie:"
  echo "  Doména: ${DOMAIN}"
  echo "  User: ${DOMAIN_USER}"
  echo "  App dir: ${APP_DIR}"
  echo "  Zmazať DB: ${DROP_DB}"
  echo "  Zmazať rolu: ${DROP_ROLE}"
  echo "  Zmazať nginx conf: ${REMOVE_NGINX_CONF}"
  echo "  Zmazať credentials súbory: ${REMOVE_CREDENTIALS}"
  echo
  read -r -p "Pokračovať? [y/N] " ans
  [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]] || die "Zrušené používateľom."
}

remove_cron() {
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "+ remove cron line for ${DOMAIN_USER}: ${CRONLINE}"
    return 0
  fi

  local current
  current="$(crontab -u "$DOMAIN_USER" -l 2>/dev/null || true)"
  if grep -Fq "$CRONLINE" <<<"$current"; then
    printf '%s\n' "$current" | grep -Fv "$CRONLINE" | crontab -u "$DOMAIN_USER" -
    log "Cron riadok bol odstránený."
  else
    warn "Cron riadok sa nenašiel, preskakujem."
  fi
}

remove_supervisor() {
  if [[ ! -f "$SUPERVISOR_CONF" ]]; then
    warn "Supervisor config ${SUPERVISOR_CONF} neexistuje, preskakujem."
    return 0
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "+ supervisorctl stop ${DOMAIN_USER}-laravel-worker:* || true"
    echo "+ rm -f '${SUPERVISOR_CONF}'"
    echo "+ supervisorctl reread"
    echo "+ supervisorctl update"
    return 0
  fi

  supervisorctl stop "${DOMAIN_USER}-laravel-worker:"* >/dev/null 2>&1 || true
  rm -f "$SUPERVISOR_CONF"
  supervisorctl reread >/dev/null || true
  supervisorctl update >/dev/null || true
  log "Supervisor worker bol odstránený."
}

remove_app_dir() {
  if [[ ! -d "$APP_DIR" ]]; then
    warn "App dir ${APP_DIR} neexistuje, preskakujem."
    return 0
  fi

  run "rm -rf --one-file-system '${APP_DIR}'"
}

remove_db() {
  validate_pg_identifier "$DB_NAME" "DB_NAME"

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "+ sudo -u postgres psql -v ON_ERROR_STOP=1 -d postgres -c \"SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${DB_NAME}' AND pid <> pg_backend_pid();\" >/dev/null"
    echo "+ sudo -u postgres psql -v ON_ERROR_STOP=1 -d postgres -c \"DROP DATABASE IF EXISTS ${DB_NAME};\""
    return 0
  fi

  log "Mažem PostgreSQL databázu ${DB_NAME}..."
  sudo -u postgres psql -v ON_ERROR_STOP=1 -d postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${DB_NAME}' AND pid <> pg_backend_pid();" >/dev/null || true
  sudo -u postgres psql -v ON_ERROR_STOP=1 -d postgres -c "DROP DATABASE IF EXISTS ${DB_NAME};"
}

remove_role() {
  validate_pg_identifier "$DB_USER" "DB_USER"

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "+ sudo -u postgres psql -v ON_ERROR_STOP=1 -d postgres -c \"DROP ROLE IF EXISTS ${DB_USER};\""
    return 0
  fi

  log "Mažem PostgreSQL rolu ${DB_USER}..."
  sudo -u postgres psql -v ON_ERROR_STOP=1 -d postgres -c "DROP ROLE IF EXISTS ${DB_USER};"
}

remove_nginx_conf() {
  local changed=0

  if [[ -L "$NGINX_ENABLED" || -e "$NGINX_ENABLED" ]]; then
    run "rm -f '${NGINX_ENABLED}'"
    changed=1
  else
    warn "Nginx symlink ${NGINX_ENABLED} neexistuje, preskakujem."
  fi

  if [[ -f "$NGINX_CONF" ]]; then
    run "rm -f '${NGINX_CONF}'"
    changed=1
  else
    warn "Nginx config ${NGINX_CONF} neexistuje, preskakujem."
  fi

  if [[ $changed -eq 1 ]]; then
    run "nginx -t"
    run "systemctl reload nginx"
  fi
}

remove_credentials_files() {
  local pattern="/root/${DOMAIN}-deploy-credentials-"*.txt
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "+ rm -f ${pattern}"
    return 0
  fi

  shopt -s nullglob
  local files=(/root/${DOMAIN}-deploy-credentials-*.txt)
  shopt -u nullglob

  if [[ ${#files[@]} -eq 0 ]]; then
    warn "Credentials súbory pre ${DOMAIN} sa nenašli, preskakujem."
    return 0
  fi

  rm -f /root/${DOMAIN}-deploy-credentials-*.txt
  log "Credentials súbory boli odstránené."
}

confirm

log "Reset app dir: ${APP_DIR}"
log "Reset drop DB: ${DROP_DB}"
log "Reset drop role: ${DROP_ROLE}"
log "Remove nginx conf: ${REMOVE_NGINX_CONF}"
log "Remove credentials: ${REMOVE_CREDENTIALS}"

remove_cron
remove_supervisor
remove_app_dir

if [[ $DROP_DB -eq 1 ]]; then
  remove_db
fi

if [[ $DROP_ROLE -eq 1 ]]; then
  remove_role
fi

if [[ $REMOVE_NGINX_CONF -eq 1 ]]; then
  remove_nginx_conf
fi

if [[ $REMOVE_CREDENTIALS -eq 1 ]]; then
  remove_credentials_files
fi

echo
echo "Hotovo."
echo "Zachované zostali:"
echo "- Virtualmin doména"
echo "- Linux user ${DOMAIN_USER}"
echo "- SSL certifikáty"
echo
echo "Ak chceš spraviť nový deploy, použi hlavný setup skript znova."
