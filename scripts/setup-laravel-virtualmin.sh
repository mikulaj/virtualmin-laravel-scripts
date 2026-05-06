#!/usr/bin/env bash
set -Eeuo pipefail

# Laravel + Virtualmin + Nginx + PostgreSQL setup script
# Profiles:
#   plain-laravel
#   filament-postgres
#
# Example:
#   bash scripts/setup-laravel-virtualmin.sh \
#     --domain=fucty.sk \
#     --user=fucty \
#     --db=fucty \
#     --db-user=fucty \
#     --profile=filament-postgres \
#     --app-name="FÚčty"

DOMAIN=""
APP_USER=""
DB_NAME=""
DB_USER=""
DB_PASS=""
APP_NAME="Laravel"
APP_DIR=""
PROFILE="plain-laravel"
PHP_VERSION=""
PRECHECK_ONLY=0
INSTALL_DEPS=0
INSTALL_FILAMENT=0
FILAMENT_VERSION="^4.0"
CREATE_ADMIN=1
ADMIN_NAME="Admin"
ADMIN_EMAIL=""
ADMIN_PASSWORD=""
RUN_NPM_BUILD=1
ENABLE_SSL=1
ENABLE_QUEUE=0

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

log()  { echo "${BLUE}==>${NC} $*"; }
ok()   { echo "${GREEN}[OK]${NC} $*"; }
warn() { echo "${YELLOW}[WARN]${NC} $*"; }
fail() { echo "${RED}[ERROR]${NC} $*" >&2; exit 1; }

usage() {
  cat <<USAGE
Použitie:
  bash scripts/setup-laravel-virtualmin.sh --domain=DOMENA [voľby]

Povinné / odporúčané:
  --domain=fucty.sk
  --user=fucty
  --db=fucty
  --db-user=fucty
  --profile=filament-postgres
  --app-name="FÚčty"

Voľby:
  --precheck                  Len kontrola prostredia, nevytvára aplikáciu
  --install-deps              Pri prechecku aj doinštaluje chýbajúce balíky
  --db-pass=HESLO             Heslo DB používateľa; ak chýba, vygeneruje sa
  --app-dir=/home/user/app    Predvolená cesta je /home/USER/laravel-app
  --php-version=8.4           Ak chýba, skript sa pokúsi zistiť aktívnu PHP verziu
  --filament-version="^4.0"   Predvolená verzia Filamentu
  --no-filament               Preskočí inštaláciu Filamentu
  --no-admin                  Nevytvorí admin používateľa
  --admin-name="Admin"
  --admin-email=admin@domena.sk
  --admin-password=heslo
  --no-npm-build              Preskočí npm install/build
  --no-ssl                    Nepokúsi sa spustiť Let's Encrypt cez Virtualmin
  --with-queue                Pripraví Supervisor queue worker

Príklady:
  bash scripts/setup-laravel-virtualmin.sh --precheck --install-deps

  bash scripts/setup-laravel-virtualmin.sh \\
    --domain=fucty.sk \\
    --user=fucty \\
    --db=fucty \\
    --db-user=fucty \\
    --profile=filament-postgres \\
    --app-name="FÚčty"
USAGE
}

for arg in "$@"; do
  case "$arg" in
    --domain=*) DOMAIN="${arg#*=}" ;;
    --user=*) APP_USER="${arg#*=}" ;;
    --db=*) DB_NAME="${arg#*=}" ;;
    --db-user=*) DB_USER="${arg#*=}" ;;
    --db-pass=*) DB_PASS="${arg#*=}" ;;
    --app-name=*) APP_NAME="${arg#*=}" ;;
    --app-dir=*) APP_DIR="${arg#*=}" ;;
    --profile=*) PROFILE="${arg#*=}" ;;
    --php-version=*) PHP_VERSION="${arg#*=}" ;;
    --filament-version=*) FILAMENT_VERSION="${arg#*=}" ;;
    --precheck) PRECHECK_ONLY=1 ;;
    --install-deps) INSTALL_DEPS=1 ;;
    --no-filament) INSTALL_FILAMENT=0 ;;
    --no-admin) CREATE_ADMIN=0 ;;
    --admin-name=*) ADMIN_NAME="${arg#*=}" ;;
    --admin-email=*) ADMIN_EMAIL="${arg#*=}" ;;
    --admin-password=*) ADMIN_PASSWORD="${arg#*=}" ;;
    --no-npm-build) RUN_NPM_BUILD=0 ;;
    --no-ssl) ENABLE_SSL=0 ;;
    --with-queue) ENABLE_QUEUE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Neznámy parameter: $arg" ;;
  esac
done

if [[ "$PROFILE" == "filament-postgres" ]]; then
  INSTALL_FILAMENT=1
fi

require_root() {
  [[ "${EUID}" -eq 0 ]] || fail "Skript musíš spustiť ako root."
}

derive_defaults() {
  [[ -n "$DOMAIN" ]] || {
    if [[ "$PRECHECK_ONLY" -eq 0 ]]; then
      fail "Chýba --domain=fucty.sk"
    fi
  }

  if [[ -n "$DOMAIN" ]]; then
    local base="${DOMAIN%%.*}"
    base="${base//-/_}"

    [[ -n "$APP_USER" ]] || APP_USER="${DOMAIN%%.*}"
    [[ -n "$DB_NAME" ]] || DB_NAME="$base"
    [[ -n "$DB_USER" ]] || DB_USER="$base"
    [[ -n "$ADMIN_EMAIL" ]] || ADMIN_EMAIL="admin@$DOMAIN"
  fi

  if [[ -n "$APP_USER" && -z "$APP_DIR" ]]; then
    APP_DIR="/home/$APP_USER/laravel-app"
  fi

  if [[ -z "$PHP_VERSION" ]]; then
    PHP_VERSION="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true)"
  fi
}

validate_inputs() {
  [[ "$PRECHECK_ONLY" -eq 1 ]] && return 0

  [[ "$DOMAIN" =~ ^[a-zA-Z0-9.-]+$ ]] || fail "Neplatná doména: $DOMAIN"
  [[ "$APP_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || fail "Neplatný Linux používateľ: $APP_USER"
  [[ "$DB_NAME" =~ ^[a-zA-Z0-9_]+$ ]] || fail "Neplatný názov databázy: $DB_NAME"
  [[ "$DB_USER" =~ ^[a-zA-Z0-9_]+$ ]] || fail "Neplatný DB používateľ: $DB_USER"
  [[ -n "$APP_DIR" ]] || fail "Chýba APP_DIR."
}

detect_nginx_conf() {
  local candidates=(
    "/etc/nginx/sites-available/$DOMAIN.conf"
    "/etc/nginx/sites-enabled/$DOMAIN.conf"
    "/etc/nginx/conf.d/$DOMAIN.conf"
  )

  for f in "${candidates[@]}"; do
    if [[ -f "$f" ]]; then
      echo "$f"
      return 0
    fi
  done

  return 1
}

run_as_app_user() {
  local app_home="/home/$APP_USER"
  local cmd="$*"

  runuser -u "$APP_USER" -- env \
    HOME="$app_home" \
    COMPOSER_HOME="$app_home/.composer" \
    NPM_CONFIG_CACHE="$app_home/.npm" \
    bash -lc "cd /tmp && $cmd"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

install_packages() {
  log "Inštalujem chýbajúce systémové balíky"

  apt-get update

  local packages=(
    ca-certificates
    curl
    git
    unzip
    zip
    acl
    nginx
    postgresql
    postgresql-client
    composer
    nodejs
    npm
    python3
    python3-venv
    supervisor
  )

  if [[ -n "$PHP_VERSION" ]]; then
    packages+=(
      "php$PHP_VERSION-cli"
      "php$PHP_VERSION-fpm"
      "php$PHP_VERSION-pgsql"
      "php$PHP_VERSION-mbstring"
      "php$PHP_VERSION-xml"
      "php$PHP_VERSION-curl"
      "php$PHP_VERSION-zip"
      "php$PHP_VERSION-gd"
      "php$PHP_VERSION-intl"
      "php$PHP_VERSION-bcmath"
    )
  fi

  apt-get install -y "${packages[@]}"
}

precheck() {
  log "Kontrola prostredia"

  local missing=0

  for cmd in virtualmin nginx php composer psql git curl; do
    if need_cmd "$cmd"; then
      ok "$cmd je dostupný"
    else
      warn "$cmd chýba"
      missing=1
    fi
  done

  if need_cmd php; then
    ok "PHP verzia: $(php -r 'echo PHP_VERSION;')"
  fi

  if [[ -n "$PHP_VERSION" ]]; then
    for ext in pgsql mbstring xml curl zip gd intl bcmath; do
      if php -m | grep -qi "^$ext$"; then
        ok "PHP extension $ext je dostupná"
      else
        warn "PHP extension $ext chýba"
        missing=1
      fi
    done
  fi

  if systemctl is-active --quiet nginx; then
    ok "nginx beží"
  else
    warn "nginx nebeží"
  fi

  if systemctl is-active --quiet postgresql; then
    ok "postgresql beží"
  else
    warn "postgresql nebeží"
  fi

  if [[ "$INSTALL_DEPS" -eq 1 ]]; then
    install_packages
    ok "Kontrola/doinštalovanie balíkov dokončené"
  elif [[ "$missing" -eq 1 ]]; then
    warn "Niečo chýba. Spusti precheck s parametrom --install-deps."
  fi
}

ensure_virtualmin_domain() {
  log "Kontrolujem Virtualmin doménu $DOMAIN"

  if virtualmin list-domains --domain "$DOMAIN" >/dev/null 2>&1; then
    ok "Virtualmin doména $DOMAIN už existuje"
    return 0
  fi

  warn "Doména $DOMAIN neexistuje, vytváram ju vo Virtualmine"

  local vm_pass
  vm_pass="$(openssl rand -base64 24 | tr -d '\n')"

  virtualmin create-domain \
    --domain "$DOMAIN" \
    --user "$APP_USER" \
    --pass "$vm_pass" \
    --desc "$DOMAIN" \
    --unix \
    --dir \
    --web \
    --dns || fail "Virtualmin doménu sa nepodarilo vytvoriť."

  mkdir -p /root/virtualmin-created-passwords
  chmod 700 /root/virtualmin-created-passwords
  printf '%s\n' "$vm_pass" > "/root/virtualmin-created-passwords/$DOMAIN.user-password.txt"
  chmod 600 "/root/virtualmin-created-passwords/$DOMAIN.user-password.txt"

  ok "Virtualmin doména vytvorená"
  warn "Heslo Linux/Virtualmin používateľa je uložené v /root/virtualmin-created-passwords/$DOMAIN.user-password.txt"
}

ensure_postgres() {
  log "Pripravujem PostgreSQL databázu"

  systemctl enable --now postgresql >/dev/null 2>&1 || true

  if [[ -z "$DB_PASS" ]]; then
    DB_PASS="$(openssl rand -base64 32 | tr -d '\n')"
    mkdir -p /root/laravel-db-passwords
    chmod 700 /root/laravel-db-passwords
    printf '%s\n' "$DB_PASS" > "/root/laravel-db-passwords/$DOMAIN.db-password.txt"
    chmod 600 "/root/laravel-db-passwords/$DOMAIN.db-password.txt"
    warn "DB heslo bolo vygenerované a uložené v /root/laravel-db-passwords/$DOMAIN.db-password.txt"
  fi

  local db_pass_sql
  db_pass_sql="${DB_PASS//\'/\'\'}"

  sudo -u postgres psql -v ON_ERROR_STOP=1 <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '$DB_USER') THEN
    CREATE ROLE "$DB_USER" LOGIN PASSWORD '$db_pass_sql';
  ELSE
    ALTER ROLE "$DB_USER" WITH LOGIN PASSWORD '$db_pass_sql';
  END IF;
END
\$\$;

SELECT 'CREATE DATABASE "$DB_NAME" OWNER "$DB_USER"'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$DB_NAME')\\gexec
SQL

  ok "PostgreSQL databáza a používateľ sú pripravené"
}

ensure_laravel_app() {
  log "Pripravujem Laravel aplikáciu v $APP_DIR"

  [[ -d "/home/$APP_USER" ]] || fail "Domovský adresár /home/$APP_USER neexistuje."

  mkdir -p "/home/$APP_USER/.composer"
  chown -R "$APP_USER:$APP_USER" "/home/$APP_USER/.composer"

  if [[ ! -f "$APP_DIR/artisan" ]]; then
    if [[ -d "$APP_DIR" && -n "$(ls -A "$APP_DIR" 2>/dev/null || true)" ]]; then
      fail "$APP_DIR existuje, ale nie je to Laravel aplikácia. Skontroluj adresár ručne."
    fi

    rm -rf "$APP_DIR"
    run_as_app_user "composer create-project laravel/laravel '$APP_DIR' --no-interaction"
  else
    ok "Laravel aplikácia už existuje"
  fi

  chown -R "$APP_USER:$APP_USER" "$APP_DIR"
  chmod -R u+rwX,go+rX "$APP_DIR"
  chmod -R ug+rwX "$APP_DIR/storage" "$APP_DIR/bootstrap/cache" 2>/dev/null || true
}

set_env_value() {
  local key="$1"
  local value="$2"
  local env_file="$APP_DIR/.env"

  python3 - "$env_file" "$key" "$value" <<'PY'
import sys
from pathlib import Path

env_file = Path(sys.argv[1])
key = sys.argv[2]
value = sys.argv[3]

def quote(v: str) -> str:
    escaped = v.replace("\\", "\\\\").replace('"', '\\"')
    return f'{key}="{escaped}"'

line = quote(value)
lines = env_file.read_text(encoding="utf-8").splitlines() if env_file.exists() else []
out = []
found = False

for existing in lines:
    if existing.startswith(key + "="):
        out.append(line)
        found = True
    else:
        out.append(existing)

if not found:
    out.append(line)

env_file.write_text("\n".join(out) + "\n", encoding="utf-8")
PY
}

configure_laravel_env() {
  log "Nastavujem .env"

  if [[ ! -f "$APP_DIR/.env" ]]; then
    cp "$APP_DIR/.env.example" "$APP_DIR/.env"
    chown "$APP_USER:$APP_USER" "$APP_DIR/.env"
  fi

  set_env_value "APP_NAME" "$APP_NAME"
  set_env_value "APP_ENV" "production"
  set_env_value "APP_DEBUG" "false"
  set_env_value "APP_URL" "https://$DOMAIN"

  set_env_value "DB_CONNECTION" "pgsql"
  set_env_value "DB_HOST" "127.0.0.1"
  set_env_value "DB_PORT" "5432"
  set_env_value "DB_DATABASE" "$DB_NAME"
  set_env_value "DB_USERNAME" "$DB_USER"
  set_env_value "DB_PASSWORD" "$DB_PASS"

  set_env_value "FILESYSTEM_DISK" "local"
  set_env_value "QUEUE_CONNECTION" "database"
  set_env_value "CACHE_STORE" "database"
  set_env_value "SESSION_DRIVER" "database"

  chown "$APP_USER:$APP_USER" "$APP_DIR/.env"

  run_as_app_user "cd '$APP_DIR' && php artisan key:generate --force"

  ok ".env je nastavený"
}

install_filament() {
  [[ "$INSTALL_FILAMENT" -eq 1 ]] || return 0

  log "Inštalujem Filament panel"

  if ! run_as_app_user "cd '$APP_DIR' && composer show filament/filament >/dev/null 2>&1"; then
    run_as_app_user "cd '$APP_DIR' && composer require filament/filament:\"$FILAMENT_VERSION\" --no-interaction"
  else
    ok "Filament už je nainštalovaný"
  fi

  if [[ ! -f "$APP_DIR/app/Providers/Filament/AdminPanelProvider.php" ]]; then
    run_as_app_user "cd '$APP_DIR' && php artisan filament:install --panels --no-interaction || php artisan filament:install --panels"
  else
    ok "AdminPanelProvider už existuje"
  fi
}

run_laravel_maintenance() {
  log "Spúšťam Laravel údržbu"

  run_as_app_user "cd '$APP_DIR' && composer install --no-interaction --prefer-dist --optimize-autoloader"

  # Prvé čistenie cache musí ísť dočasne cez file driver,
  # lebo pri CACHE_STORE=database ešte pred migráciami neexistuje tabuľka cache.
  run_as_app_user "cd '$APP_DIR' && CACHE_STORE=file SESSION_DRIVER=file php artisan optimize:clear || true"

  run_as_app_user "cd '$APP_DIR' && php artisan migrate --force"

  # Po migráciách už tabuľky cache/session/jobs existujú, takže môžeme čistiť normálne.
  run_as_app_user "cd '$APP_DIR' && php artisan optimize:clear || true"

  if [[ ! -L "$APP_DIR/public/storage" ]]; then
    run_as_app_user "cd '$APP_DIR' && php artisan storage:link || true"
  fi

  if [[ "$RUN_NPM_BUILD" -eq 1 && -f "$APP_DIR/package.json" ]]; then
    run_as_app_user "cd '$APP_DIR' && npm install && npm run build"
  fi

  if [[ "$INSTALL_FILAMENT" -eq 1 ]]; then
    run_as_app_user "cd '$APP_DIR' && php artisan filament:optimize || true"
  fi

  run_as_app_user "cd '$APP_DIR' && php artisan config:cache || true"
  run_as_app_user "cd '$APP_DIR' && php artisan route:cache || true"
  run_as_app_user "cd '$APP_DIR' && php artisan view:cache || true"

  ok "Laravel údržba dokončená"
}

create_admin_user() {
  [[ "$CREATE_ADMIN" -eq 1 ]] || return 0
  [[ "$INSTALL_FILAMENT" -eq 1 ]] || return 0

  log "Pripravujem admin používateľa"

  if [[ -z "$ADMIN_PASSWORD" ]]; then
    ADMIN_PASSWORD="$(openssl rand -base64 18 | tr -d '\n')"
    mkdir -p /root/laravel-admin-passwords
    chmod 700 /root/laravel-admin-passwords
    printf '%s\n' "$ADMIN_PASSWORD" > "/root/laravel-admin-passwords/$DOMAIN.admin-password.txt"
    chmod 600 "/root/laravel-admin-passwords/$DOMAIN.admin-password.txt"
    warn "Admin heslo bolo vygenerované a uložené v /root/laravel-admin-passwords/$DOMAIN.admin-password.txt"
  fi

  if run_as_app_user "cd '$APP_DIR' && php artisan make:filament-user --name='$ADMIN_NAME' --email='$ADMIN_EMAIL' --password='$ADMIN_PASSWORD' --no-interaction"; then
    ok "Filament admin používateľ pripravený"
  else
    warn "make:filament-user neprebehlo, skúšam fallback cez User model"

    run_as_app_user "cd '$APP_DIR' && php artisan tinker --execute=\"\\App\\Models\\User::updateOrCreate(['email' => '$ADMIN_EMAIL'], ['name' => '$ADMIN_NAME', 'password' => \\Illuminate\\Support\\Facades\\Hash::make('$ADMIN_PASSWORD')]);\""

    ok "Admin používateľ pripravený cez fallback"
  fi
}

configure_nginx_for_laravel() {
  log "Nastavujem Nginx root na Laravel public"

  local conf
  conf="$(detect_nginx_conf)" || fail "Nenašiel som Nginx konfiguráciu pre $DOMAIN"

  cp "$conf" "$conf.bak.$(date +%Y%m%d_%H%M%S)"

  python3 - "$conf" "$APP_DIR/public" <<'PY'
import re
import sys
from pathlib import Path

conf = Path(sys.argv[1])
public_root = sys.argv[2]
text = conf.read_text(encoding="utf-8", errors="ignore")

text = re.sub(r'root\s+[^;]+;', f'root {public_root};', text)
text = re.sub(r'index\s+[^;]+;', 'index index.php index.html index.htm;', text)

if 'try_files $uri $uri/ /index.php?$query_string;' not in text:
    m = re.search(r'location\s+/\s*\{[^{}]*\}', text, re.S)
    if m:
        block = """location / {
        try_files $uri $uri/ /index.php?$query_string;
    }"""
        text = text[:m.start()] + block + text[m.end():]
    else:
        text = text.replace(
            f'root {public_root};',
            f'root {public_root};\n\n    location / {{\n        try_files $uri $uri/ /index.php?$query_string;\n    }}',
            1,
        )

text = re.sub(
    r'fastcgi_param\s+SCRIPT_FILENAME\s+[^;]+;',
    'fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;',
    text,
)

conf.write_text(text, encoding="utf-8")
PY

  nginx -t
  systemctl reload nginx

  ok "Nginx je nastavený na $APP_DIR/public"
}

ensure_scheduler_cron() {
  log "Nastavujem Laravel scheduler cron"

  local cron_file="/etc/cron.d/laravel-${APP_USER}-${DOMAIN//./-}"

  cat > "$cron_file" <<EOF
* * * * * $APP_USER cd $APP_DIR && /usr/bin/php artisan schedule:run >> /dev/null 2>&1
EOF

  chmod 644 "$cron_file"

  ok "Scheduler cron vytvorený: $cron_file"
}

configure_queue_supervisor() {
  [[ "$ENABLE_QUEUE" -eq 1 ]] || return 0

  log "Nastavujem Supervisor queue worker"

  local conf="/etc/supervisor/conf.d/laravel-${APP_USER}-${DOMAIN//./-}-queue.conf"

  cat > "$conf" <<EOF
[program:laravel-${APP_USER}-${DOMAIN//./-}-queue]
process_name=%(program_name)s_%(process_num)02d
command=/usr/bin/php $APP_DIR/artisan queue:work --sleep=3 --tries=3 --max-time=3600
autostart=true
autorestart=true
stopasgroup=true
killasgroup=true
user=$APP_USER
numprocs=1
redirect_stderr=true
stdout_logfile=$APP_DIR/storage/logs/queue-worker.log
stopwaitsecs=3600
EOF

  supervisorctl reread || true
  supervisorctl update || true

  ok "Supervisor queue worker pripravený"
}

try_letsencrypt() {
  [[ "$ENABLE_SSL" -eq 1 ]] || return 0

  log "Pokúšam sa vystaviť Let's Encrypt certifikát cez Virtualmin"

  if virtualmin generate-letsencrypt-cert --domain "$DOMAIN" >/dev/null 2>&1; then
    ok "Let's Encrypt certifikát bol vystavený alebo obnovený"
  else
    warn "Let's Encrypt sa nepodarilo vystaviť automaticky. Skontroluj DNS a Virtualmin SSL ručne."
  fi
}

health_check() {
  log "Záverečná kontrola"

  [[ -d "$APP_DIR" ]] && ok "$APP_DIR existuje" || warn "$APP_DIR neexistuje"
  [[ -d "$APP_DIR/public" ]] && ok "$APP_DIR/public existuje" || warn "$APP_DIR/public neexistuje"
  [[ -f "$APP_DIR/.env" ]] && ok ".env existuje" || warn ".env neexistuje"
  [[ -n "$(grep '^APP_KEY=' "$APP_DIR/.env" | cut -d= -f2-)" ]] && ok "APP_KEY je nastavený" || warn "APP_KEY nie je nastavený"

  if [[ -L "$APP_DIR/public/storage" ]]; then
    ok "storage link existuje"
  else
    warn "storage link neexistuje"
  fi

  if run_as_app_user "cd '$APP_DIR' && php artisan about >/dev/null 2>&1"; then
    ok "php artisan about funguje"
  else
    warn "php artisan about zlyhalo"
  fi

  if [[ "$INSTALL_FILAMENT" -eq 1 ]]; then
    if run_as_app_user "cd '$APP_DIR' && php artisan route:list --path=admin >/dev/null 2>&1"; then
      ok "Filament /admin route existuje"
    else
      warn "Filament /admin route sa nepodarilo overiť"
    fi
  fi

  local conf
  if conf="$(detect_nginx_conf 2>/dev/null)"; then
    if grep -q "$APP_DIR/public" "$conf"; then
      ok "Nginx root smeruje na $APP_DIR/public"
    else
      warn "Nginx root možno nesmeruje na $APP_DIR/public"
    fi
  fi

  nginx -t >/dev/null 2>&1 && ok "nginx -t je OK" || warn "nginx -t hlási problém"

  if curl -k -I --max-time 10 "https://$DOMAIN" >/dev/null 2>&1; then
    ok "HTTPS odpoveď z https://$DOMAIN je dostupná"
  else
    warn "HTTPS kontrola neprešla. Môže ísť o DNS/SSL/cache problém."
  fi

  echo
  echo "Hotovo."
  echo "Doména:      https://$DOMAIN"
  echo "Admin:       https://$DOMAIN/admin"
  echo "Aplikácia:   $APP_DIR"
  echo "DB:          $DB_NAME"
  echo "DB user:     $DB_USER"

  if [[ "$CREATE_ADMIN" -eq 1 && "$INSTALL_FILAMENT" -eq 1 ]]; then
    echo "Admin email: $ADMIN_EMAIL"
    echo "Admin heslo: ak bolo generované, je v /root/laravel-admin-passwords/$DOMAIN.admin-password.txt"
  fi
}

main() {
  require_root
  derive_defaults
  validate_inputs

  precheck

  if [[ "$PRECHECK_ONLY" -eq 1 ]]; then
    exit 0
  fi

  ensure_virtualmin_domain
  ensure_postgres
  ensure_laravel_app
  configure_laravel_env
  install_filament
  run_laravel_maintenance
  create_admin_user
  configure_nginx_for_laravel
  ensure_scheduler_cron
  configure_queue_supervisor
  try_letsencrypt
  health_check
}

main "$@"
