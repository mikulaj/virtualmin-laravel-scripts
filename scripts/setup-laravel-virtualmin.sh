#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Parametrický setup skript pre Laravel + Filament + PostgreSQL na existujúcej Virtualmin doméne.

Použitie:
  sudo bash setup-laravel-virtualmin.sh \
    --domain fema.sk \
    --user fema \
    --db-pass 'SILNE_HESLO'

Voliteľné:
  --db-name NAME            default: <user>_matrika
  --db-user NAME            default: <user>_matrika_user
  --app-dir PATH            default: /home/<user>/laravel-app
  --php-version VERSION     default: 8.4
  --skip-packages           preskočí apt install
  --skip-cert-check         preskočí kontrolu HTTPS certifikátu na konci
  --dry-run                 iba vypíše kroky, nič nemení

Reset pred deployom:
  --reset-first             zmaže starý Laravel pokus pred novým deployom
  --reset-drop-db           pri resetovaní zmaže aj PostgreSQL databázu
  --reset-drop-role         pri resetovaní zmaže aj PostgreSQL rolu / usera
  --reset-yes               nepotvrdzuje reset interaktívne

  -h, --help                zobrazí túto nápovedu

Poznámky:
- Skript predpokladá, že Virtualmin doména už existuje.
- Aplikačné kroky bežia vždy cez: su - <user>
- Nerieši DNS ani vystavenie SSL certifikátu.
- Vytvorenie Filament admin používateľa necháva na konci ako ručný krok.
USAGE
}

if [[ $# -eq 0 ]]; then
  usage
  exit 0
fi

DOMAIN=""
DOMAIN_USER=""
DB_PASS=""
DB_NAME=""
DB_USER=""
APP_DIR=""
PHP_VERSION="8.4"
SKIP_PACKAGES=0
SKIP_CERT_CHECK=0
DRY_RUN=0
RESET_FIRST=0
RESET_DROP_DB=0
RESET_DROP_ROLE=0
RESET_YES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="$2"; shift 2 ;;
    --user) DOMAIN_USER="$2"; shift 2 ;;
    --db-pass) DB_PASS="$2"; shift 2 ;;
    --db-name) DB_NAME="$2"; shift 2 ;;
    --db-user) DB_USER="$2"; shift 2 ;;
    --app-dir) APP_DIR="$2"; shift 2 ;;
    --php-version) PHP_VERSION="$2"; shift 2 ;;
    --skip-packages) SKIP_PACKAGES=1; shift ;;
    --skip-cert-check) SKIP_CERT_CHECK=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --reset-first) RESET_FIRST=1; shift ;;
    --reset-drop-db) RESET_DROP_DB=1; shift ;;
    --reset-drop-role) RESET_DROP_ROLE=1; shift ;;
    --reset-yes) RESET_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "Skript spusti ako root." >&2; exit 1; }
[[ -n "$DOMAIN" && -n "$DOMAIN_USER" && -n "$DB_PASS" ]] || { usage; exit 1; }

DB_NAME="${DB_NAME:-${DOMAIN_USER}_matrika}"
DB_USER="${DB_USER:-${DOMAIN_USER}_matrika_user}"
APP_DIR="${APP_DIR:-/home/${DOMAIN_USER}/laravel-app}"
APP_PUBLIC_DIR="${APP_DIR}/public"
NGINX_CONF="/etc/nginx/sites-available/${DOMAIN}.conf"
NGINX_ENABLED="/etc/nginx/sites-enabled/${DOMAIN}.conf"
BOOTSTRAP_PROVIDERS="${APP_DIR}/bootstrap/providers.php"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
PHP_FPM_SERVICE="php${PHP_VERSION}-fpm"
CRONLINE="* * * * * cd ${APP_DIR} && php artisan schedule:run >> /dev/null 2>&1"
SUPERVISOR_CONF="/etc/supervisor/conf.d/${DOMAIN_USER}-laravel-worker.conf"

log() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
die() { echo "[ERROR] $*" >&2; exit 1; }
command_exists() { command -v "$1" >/dev/null 2>&1; }
require_file() { [[ -f "$1" ]] || die "Chýba súbor: $1"; }
require_dir() { [[ -d "$1" ]] || die "Chýba adresár: $1"; }

run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "+ $*"
  else
    eval "$@"
  fi
}

run_user() {
  local cmd="$*"
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "+ su - ${DOMAIN_USER} -c $(printf '%q' "$cmd")"
  else
    su - "$DOMAIN_USER" -c "$cmd"
  fi
}

write_file() {
  local path="$1"
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "+ write file ${path}"
    cat >/dev/null
  else
    cat >"$path"
  fi
}

append_or_replace_cron_line() {
  local user="$1"
  local line="$2"

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "+ ensure crontab for ${user}: ${line}"
    return 0
  fi

  local tmp
  tmp="$(mktemp)"
  crontab -u "$user" -l 2>/dev/null | grep -Fvx "$line" >"$tmp" || true
  echo "$line" >>"$tmp"
  crontab -u "$user" "$tmp"
  rm -f "$tmp"
}

remove_cron_line() {
  local user="$1"
  local line="$2"

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "+ remove cron line for ${user}: ${line}"
    return 0
  fi

  local tmp
  tmp="$(mktemp)"
  crontab -u "$user" -l 2>/dev/null | grep -Fvx "$line" >"$tmp" || true
  if [[ -s "$tmp" ]]; then
    crontab -u "$user" "$tmp"
  else
    crontab -u "$user" -r 2>/dev/null || true
  fi
  rm -f "$tmp"
}

validate_pg_identifier() {
  local value="$1"
  local label="$2"
  [[ "$value" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || die "${label}='${value}' nie je bezpečný PostgreSQL identifikátor. Použi len písmená, čísla a _ ; začiatok musí byť písmeno alebo _."
}

sql_escape_literal() {
  printf "%s" "$1" | sed "s/'/''/g"
}

dotenv_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//\$/\\$}"
  printf '"%s"' "$value"
}

print_versions() {
  command_exists php && php -v | head -1 || true
  if command_exists composer; then
    su - "$DOMAIN_USER" -c "composer --version --no-interaction" || true
  fi
  command_exists node && node -v || true
  command_exists npm && npm -v || true
  command_exists psql && psql --version || true
  command_exists nginx && nginx -v 2>&1 || true
  command_exists python3 && python3 --version || true
}

basic_precheck() {
  log "Spúšťam základný precheck..."
  require_dir "/home/${DOMAIN_USER}"
  require_file "$NGINX_CONF"
  id "$DOMAIN_USER" >/dev/null 2>&1 || die "Používateľ ${DOMAIN_USER} neexistuje."
  validate_pg_identifier "$DB_NAME" "DB_NAME"
  validate_pg_identifier "$DB_USER" "DB_USER"
  command_exists apt || die "Chýba apt."
  command_exists systemctl || die "Chýba systemctl."
  log "Základný precheck prešiel úspešne."
}

full_precheck() {
  log "Spúšťam plný precheck prostredia..."
  local failed=0

  for cmd in php composer node npm psql nginx python3; do
    if ! command_exists "$cmd"; then
      warn "Chýba príkaz: $cmd"
      failed=1
    fi
  done

  for svc in postgresql "$PHP_FPM_SERVICE" nginx redis-server supervisor; do
    if ! systemctl is-active --quiet "$svc"; then
      warn "Služba ${svc} nebeží."
      failed=1
    fi
  done

  if command_exists php; then
    local phpmods
    phpmods="$(php -m | tr '[:upper:]' '[:lower:]')"
    local required_modules=(bcmath curl gd intl mbstring pdo_pgsql pgsql xml xmlreader xmlwriter zip redis)
    for mod in "${required_modules[@]}"; do
      if ! grep -qx "$mod" <<<"$phpmods"; then
        warn "Chýba PHP modul: $mod"
        failed=1
      fi
    done
  fi

  if systemctl is-active --quiet postgresql; then
    if ! sudo -u postgres psql -tAc "SELECT 1" >/dev/null 2>&1; then
      warn "Nepodarilo sa otestovať PostgreSQL cez postgres používateľa."
      failed=1
    fi
  fi

  log "Základné verzie:"
  print_versions || true

  [[ $failed -eq 0 ]] || die "Plný precheck zlyhal. Doinštaluj alebo oprav chýbajúce komponenty a skús skript znova."
  log "Plný precheck prešiel úspešne."
}

check_cert() {
  if [[ $SKIP_CERT_CHECK -eq 1 ]]; then
    warn "Kontrola certifikátu bola preskočená (--skip-cert-check)."
    return 0
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "+ check DNS and HTTPS certificate for ${DOMAIN}"
    return 0
  fi

  log "Kontrola DNS pre ${DOMAIN}..."
  if ! getent ahosts "$DOMAIN" >/dev/null 2>&1; then
    warn "Doména ${DOMAIN} sa momentálne neprekladá v DNS. Preskakujem kontrolu certifikátu."
    return 0
  fi

  log "Kontrola HTTPS certifikátu pre ${DOMAIN}..."
  local certinfo
  if ! certinfo="$(openssl s_client -connect "${DOMAIN}:443" -servername "$DOMAIN" </dev/null 2>/dev/null | openssl x509 -noout -subject -issuer -ext subjectAltName 2>/dev/null)"; then
    warn "Nepodarilo sa načítať HTTPS certifikát z ${DOMAIN}:443"
    return 0
  fi

  echo "$certinfo"
  if grep -Eq "DNS:${DOMAIN}(,|$)|DNS:${DOMAIN}[[:space:]]" <<<"$certinfo"; then
    log "Certifikát obsahuje doménu ${DOMAIN}."
  else
    warn "Certifikát zrejme NEOBSAHUJE doménu ${DOMAIN}. Skontroluj Virtualmin SSL a nginx konfiguráciu."
  fi
}

perform_reset() {
  log "Bol zadaný --reset-first. Pred deployom vyčistím starý pokus."
  log "Reset app dir: ${APP_DIR}"
  log "Reset drop DB: ${RESET_DROP_DB}"
  log "Reset drop role: ${RESET_DROP_ROLE}"

  if [[ $RESET_YES -eq 0 && $DRY_RUN -eq 0 ]]; then
    local answer
    read -r -p "Naozaj zmazať starý Laravel pokus pre ${DOMAIN}? [yes/N] " answer
    [[ "$answer" == "yes" ]] || die "Reset bol zrušený používateľom."
  fi

  remove_cron_line "$DOMAIN_USER" "$CRONLINE"

  if [[ -f "$SUPERVISOR_CONF" ]]; then
    run "supervisorctl stop ${DOMAIN_USER}-laravel-worker:* || true"
    run "rm -f '${SUPERVISOR_CONF}'"
    run "supervisorctl reread"
    run "supervisorctl update"
  else
    warn "Supervisor config ${SUPERVISOR_CONF} neexistuje, preskakujem."
  fi

  if [[ -d "$APP_DIR" ]]; then
    run "rm -rf --one-file-system '${APP_DIR}'"
  else
    warn "Adresár ${APP_DIR} neexistuje, preskakujem mazanie aplikácie."
  fi

  if [[ $RESET_DROP_DB -eq 1 ]]; then
    log "Mažem PostgreSQL databázu ${DB_NAME}..."
    run "sudo -u postgres psql -v ON_ERROR_STOP=1 -d postgres -c \"SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${DB_NAME}' AND pid <> pg_backend_pid();\" >/dev/null"
    run "sudo -u postgres psql -v ON_ERROR_STOP=1 -d postgres -c \"DROP DATABASE IF EXISTS ${DB_NAME};\""
  fi

  if [[ $RESET_DROP_ROLE -eq 1 ]]; then
    log "Mažem PostgreSQL rolu ${DB_USER}..."
    run "sudo -u postgres psql -v ON_ERROR_STOP=1 -d postgres -c \"DROP ROLE IF EXISTS ${DB_USER};\""
  fi
}

ensure_pg_role_and_db() {
  local escaped_pass
  escaped_pass="$(sql_escape_literal "$DB_PASS")"

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "+ create PostgreSQL role ${DB_USER} if missing"
    echo "+ create PostgreSQL database ${DB_NAME} if missing"
    echo "+ alter PostgreSQL database owner to ${DB_USER}"
    return 0
  fi

  log "Pripravujem PostgreSQL databázu a používateľa..."

  if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" | grep -q 1; then
    sudo -u postgres psql -v ON_ERROR_STOP=1 -c "CREATE ROLE ${DB_USER} WITH LOGIN PASSWORD '${escaped_pass}';"
  fi

  if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1; then
    sudo -u postgres psql -v ON_ERROR_STOP=1 -c "CREATE DATABASE ${DB_NAME} OWNER ${DB_USER} ENCODING 'UTF8';"
  fi

  sudo -u postgres psql -v ON_ERROR_STOP=1 -c "ALTER DATABASE ${DB_NAME} OWNER TO ${DB_USER};" >/dev/null
  sudo -u postgres psql -v ON_ERROR_STOP=1 -d "${DB_NAME}" -c "GRANT ALL ON SCHEMA public TO ${DB_USER};" >/dev/null
}

ensure_laravel_project() {
  if [[ -d "$APP_DIR" ]]; then
    if [[ -f "${APP_DIR}/composer.json" ]]; then
      log "Laravel projekt už existuje v ${APP_DIR}, preskakujem create-project."
      return 0
    fi

    if [[ -z "$(find "$APP_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
      run_user "composer create-project --no-interaction --no-scripts laravel/laravel '${APP_DIR}'"
      return 0
    fi

    die "Adresár ${APP_DIR} už existuje a nie je prázdny, ale nevyzerá ako Laravel projekt."
  fi

  run_user "composer create-project --no-interaction --no-scripts laravel/laravel '${APP_DIR}'"
}

ensure_migration() {
  local pattern="$1"
  local cmd="$2"
  local required="${3:-1}"

  shopt -s nullglob
  local files=("${APP_DIR}"/database/migrations/*_"${pattern}".php)
  shopt -u nullglob

  if [[ ${#files[@]} -eq 0 ]]; then
    if ! run_user "cd '${APP_DIR}' && ${cmd} --no-interaction"; then
      shopt -s nullglob
      files=("${APP_DIR}"/database/migrations/*_"${pattern}".php)
      shopt -u nullglob
      if [[ ${#files[@]} -eq 0 ]]; then
        if [[ "$required" == "0" ]]; then
          warn "Nepodarilo sa vytvoriť voliteľnú migration ${pattern}. Pokračujem bez nej."
          return 0
        fi
        die "Nepodarilo sa vytvoriť migration ${pattern}"
      fi
    fi
  fi
}

basic_precheck

if [[ $SKIP_PACKAGES -eq 0 ]]; then
  log "Doinštalujem/overím požadované balíky..."
  run "apt update"
  run "apt install -y git unzip curl ca-certificates openssl python3 composer postgresql postgresql-client nginx nodejs redis-server supervisor php${PHP_VERSION}-cli php${PHP_VERSION}-fpm php${PHP_VERSION}-pgsql php${PHP_VERSION}-mbstring php${PHP_VERSION}-xml php${PHP_VERSION}-curl php${PHP_VERSION}-zip php${PHP_VERSION}-bcmath php${PHP_VERSION}-intl php${PHP_VERSION}-gd php${PHP_VERSION}-redis"
  run "systemctl enable --now postgresql redis-server supervisor ${PHP_FPM_SERVICE} nginx"
else
  warn "Preskakujem inštaláciu balíkov (--skip-packages)."
fi

full_precheck

if [[ $RESET_FIRST -eq 1 ]]; then
  perform_reset
fi

ensure_pg_role_and_db
ensure_laravel_project

run "chown -R ${DOMAIN_USER}:${DOMAIN_USER} '${APP_DIR}'"
run "mkdir -p '${APP_DIR}/storage/logs' '${APP_DIR}/bootstrap/cache'"
run "chmod -R ug+rwx '${APP_DIR}/storage' '${APP_DIR}/bootstrap/cache'"

APP_KEY_CURRENT=""
[[ -f "${APP_DIR}/.env" ]] && APP_KEY_CURRENT="$(grep -E '^APP_KEY=' "${APP_DIR}/.env" | head -1 | cut -d= -f2- || true)"
[[ -f "${APP_DIR}/.env" ]] && run "cp '${APP_DIR}/.env' '${APP_DIR}/.env.bak.${TIMESTAMP}'"

DB_PASSWORD_ENV="$(dotenv_escape "$DB_PASS")"

write_file "${APP_DIR}/.env" <<EOF_ENV
APP_NAME=${DOMAIN_USER^^}
APP_ENV=production
APP_KEY=${APP_KEY_CURRENT}
APP_DEBUG=false
APP_URL=https://${DOMAIN}

APP_LOCALE=en
APP_FALLBACK_LOCALE=en
APP_FAKER_LOCALE=en_US
APP_MAINTENANCE_DRIVER=file
BCRYPT_ROUNDS=12

LOG_CHANNEL=stack
LOG_STACK=single
LOG_DEPRECATIONS_CHANNEL=null
LOG_LEVEL=info

DB_CONNECTION=pgsql
DB_HOST=127.0.0.1
DB_PORT=5432
DB_DATABASE=${DB_NAME}
DB_USERNAME=${DB_USER}
DB_PASSWORD=${DB_PASSWORD_ENV}

SESSION_DRIVER=file
SESSION_LIFETIME=120
SESSION_ENCRYPT=false
SESSION_PATH=/
SESSION_DOMAIN=null

BROADCAST_CONNECTION=log
FILESYSTEM_DISK=local
QUEUE_CONNECTION=database
CACHE_STORE=file

MEMCACHED_HOST=127.0.0.1
REDIS_CLIENT=phpredis
REDIS_HOST=127.0.0.1
REDIS_PASSWORD=null
REDIS_PORT=6379

MAIL_MAILER=log
MAIL_SCHEME=null
MAIL_HOST=127.0.0.1
MAIL_PORT=2525
MAIL_USERNAME=null
MAIL_PASSWORD=null
MAIL_FROM_ADDRESS="no-reply@${DOMAIN}"
MAIL_FROM_NAME="\${APP_NAME}"

AWS_ACCESS_KEY_ID=
AWS_SECRET_ACCESS_KEY=
AWS_DEFAULT_REGION=us-east-1
AWS_BUCKET=
AWS_USE_PATH_STYLE_ENDPOINT=false

VITE_APP_NAME="\${APP_NAME}"
EOF_ENV
run "chown ${DOMAIN_USER}:${DOMAIN_USER} '${APP_DIR}/.env'"

run "mkdir -p '${APP_DIR}/app/Providers' '${APP_DIR}/app/Providers/Filament' '${APP_DIR}/app/Models'"

if [[ ! -f "${APP_DIR}/app/Providers/AppServiceProvider.php" ]]; then
  write_file "${APP_DIR}/app/Providers/AppServiceProvider.php" <<'EOF_PHP'
<?php

namespace App\Providers;

use Illuminate\Support\ServiceProvider;

class AppServiceProvider extends ServiceProvider
{
    public function register(): void
    {
        //
    }

    public function boot(): void
    {
        //
    }
}
EOF_PHP
fi

run_user "cd '${APP_DIR}' && composer show livewire/livewire >/dev/null 2>&1 || composer require livewire/livewire --no-interaction"
run_user "cd '${APP_DIR}' && composer show filament/filament >/dev/null 2>&1 || composer require filament/filament:'^5.0' -W --no-interaction"

write_file "${APP_DIR}/app/Providers/Filament/AdminPanelProvider.php" <<'EOF_PHP'
<?php

namespace App\Providers\Filament;

use Filament\Http\Middleware\Authenticate;
use Filament\Http\Middleware\AuthenticateSession;
use Filament\Http\Middleware\DisableBladeIconComponents;
use Filament\Http\Middleware\DispatchServingFilamentEvent;
use Filament\Pages\Dashboard;
use Filament\Panel;
use Filament\PanelProvider;
use Filament\Support\Colors\Color;
use Filament\Widgets\AccountWidget;
use Filament\Widgets\FilamentInfoWidget;
use Illuminate\Cookie\Middleware\AddQueuedCookiesToResponse;
use Illuminate\Cookie\Middleware\EncryptCookies;
use Illuminate\Foundation\Http\Middleware\ValidateCsrfToken;
use Illuminate\Routing\Middleware\SubstituteBindings;
use Illuminate\Session\Middleware\StartSession;
use Illuminate\View\Middleware\ShareErrorsFromSession;

class AdminPanelProvider extends PanelProvider
{
    public function panel(Panel $panel): Panel
    {
        return $panel
            ->default()
            ->id('admin')
            ->path('admin')
            ->login()
            ->colors([
                'primary' => Color::Amber,
            ])
            ->discoverResources(in: app_path('Filament/Resources'), for: 'App\\Filament\\Resources')
            ->discoverPages(in: app_path('Filament/Pages'), for: 'App\\Filament\\Pages')
            ->pages([
                Dashboard::class,
            ])
            ->discoverWidgets(in: app_path('Filament/Widgets'), for: 'App\\Filament\\Widgets')
            ->widgets([
                AccountWidget::class,
                FilamentInfoWidget::class,
            ])
            ->middleware([
                EncryptCookies::class,
                AddQueuedCookiesToResponse::class,
                StartSession::class,
                AuthenticateSession::class,
                ShareErrorsFromSession::class,
                ValidateCsrfToken::class,
                SubstituteBindings::class,
                DisableBladeIconComponents::class,
                DispatchServingFilamentEvent::class,
            ])
            ->authMiddleware([
                Authenticate::class,
            ]);
    }
}
EOF_PHP

write_file "${APP_DIR}/app/Models/User.php" <<'EOF_PHP'
<?php

namespace App\Models;

use Filament\Models\Contracts\FilamentUser;
use Filament\Panel;
use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Foundation\Auth\User as Authenticatable;
use Illuminate\Notifications\Notifiable;

class User extends Authenticatable implements FilamentUser
{
    use HasFactory, Notifiable;

    protected $fillable = [
        'name',
        'email',
        'password',
    ];

    protected $hidden = [
        'password',
        'remember_token',
    ];

    protected function casts(): array
    {
        return [
            'email_verified_at' => 'datetime',
            'password' => 'hashed',
        ];
    }

    public function canAccessPanel(Panel $panel): bool
    {
        return true;
    }
}
EOF_PHP

run "chown -R ${DOMAIN_USER}:${DOMAIN_USER} '${APP_DIR}/app'"

if [[ -f "$BOOTSTRAP_PROVIDERS" ]]; then
  if ! grep -q "App\\\\Providers\\\\Filament\\\\AdminPanelProvider::class" "$BOOTSTRAP_PROVIDERS"; then
    if [[ $DRY_RUN -eq 1 ]]; then
      echo "+ add AdminPanelProvider to ${BOOTSTRAP_PROVIDERS}"
    else
      export BOOTSTRAP_PROVIDERS
      python3 - <<'PY'
import os
from pathlib import Path

p = Path(os.environ["BOOTSTRAP_PROVIDERS"])
text = p.read_text()
marker = 'return ['
insert = "return [\n    App\\Providers\\Filament\\AdminPanelProvider::class,"
if marker in text:
    text = text.replace(marker, insert, 1)
else:
    raise SystemExit('Neviem upraviť bootstrap/providers.php')
p.write_text(text)
PY
    fi
  fi
fi

if [[ $DRY_RUN -eq 0 ]]; then
  ensure_migration "create_jobs_table" "php artisan make:queue-table" 1
  ensure_migration "create_job_batches_table" "php artisan make:queue-batches-table" 0
  ensure_migration "create_failed_jobs_table" "php artisan make:queue-failed-table" 0
else
  echo "+ ensure queue migration files exist"
fi

run_user "cd '${APP_DIR}' && php artisan key:generate --force"
run_user "cd '${APP_DIR}' && php artisan storage:link || true"
run_user "cd '${APP_DIR}' && php artisan migrate --force"
run_user "cd '${APP_DIR}' && npm install"
run_user "cd '${APP_DIR}' && npm run build"
run_user "cd '${APP_DIR}' && composer dump-autoload -o --no-interaction"
run_user "cd '${APP_DIR}' && php artisan optimize:clear"
run_user "cd '${APP_DIR}' && php artisan optimize"

require_file "$NGINX_CONF"
run "cp '${NGINX_CONF}' '${NGINX_CONF}.bak.${TIMESTAMP}'"

export DOMAIN APP_PUBLIC_DIR NGINX_CONF
if [[ $DRY_RUN -eq 0 ]]; then
  python3 - <<'PY'
import os
import re
from pathlib import Path

conf = Path(os.environ["NGINX_CONF"])
text = conf.read_text()

domain = os.environ["DOMAIN"]
app_public = os.environ["APP_PUBLIC_DIR"]

text = re.sub(r"server_name\s+[^;]+;", f"server_name {domain} www.{domain};", text, count=1)
text = re.sub(r"root\s+[^;]+;", f"root {app_public};", text, count=1)
text = re.sub(
    r'fastcgi_param\s+SCRIPT_FILENAME\s+"[^"]+\$fastcgi_script_name";',
    f'fastcgi_param SCRIPT_FILENAME "{app_public}\\$fastcgi_script_name";',
    text,
    count=1,
)
text = re.sub(
    r"fastcgi_param\s+DOCUMENT_ROOT\s+[^;]+;",
    f"fastcgi_param DOCUMENT_ROOT {app_public};",
    text,
    count=1,
)

text = re.sub(r"\n\s*if \(\$host = webmail\.[^\n]+\{[\s\S]*?\n\s*\}", "", text, count=1)
text = re.sub(r"\n\s*if \(\$host = admin\.[^\n]+\{[\s\S]*?\n\s*\}", "", text, count=1)

if 'location / {' not in text:
    replacement = "location ^~ /.well-known/ {\n\t\ttry_files $uri /;\n\t}\n\tlocation / {\n\t\ttry_files $uri $uri/ /index.php?$query_string;\n\t}"
    text = text.replace("location ^~ /.well-known/ {\n\t\ttry_files $uri /;\n\t}", replacement, 1)
else:
    text = re.sub(
        r"location / \{[\s\S]*?\}",
        "location / {\n\t\ttry_files $uri $uri/ /index.php?$query_string;\n\t}",
        text,
        count=1,
    )

conf.write_text(text)
PY
else
  echo "+ update nginx config ${NGINX_CONF} for Laravel root ${APP_PUBLIC_DIR}"
fi

if [[ ! -L "$NGINX_ENABLED" ]]; then
  run "rm -f '${NGINX_ENABLED}'"
  run "ln -s '${NGINX_CONF}' '${NGINX_ENABLED}'"
fi

run "nginx -t"
run "systemctl restart ${PHP_FPM_SERVICE}"
run "systemctl restart nginx"

append_or_replace_cron_line "$DOMAIN_USER" "$CRONLINE"

write_file "$SUPERVISOR_CONF" <<EOF_SUP
[program:${DOMAIN_USER}-laravel-worker]
process_name=%(program_name)s_%(process_num)02d
command=/usr/bin/php ${APP_DIR}/artisan queue:work --sleep=3 --tries=3 --timeout=90
directory=${APP_DIR}
autostart=true
autorestart=true
stopasgroup=true
killasgroup=true
user=${DOMAIN_USER}
numprocs=1
redirect_stderr=true
stdout_logfile=${APP_DIR}/storage/logs/worker.log
stopwaitsecs=3600
EOF_SUP

run "supervisorctl reread"
run "supervisorctl update"
run "supervisorctl restart ${DOMAIN_USER}-laravel-worker:* || supervisorctl start ${DOMAIN_USER}-laravel-worker:*"

run_user "cd '${APP_DIR}' && php artisan about"
run_user "cd '${APP_DIR}' && php artisan route:list | grep admin || true"
check_cert

echo

echo "Hotovo. Ďalšie kroky:"
echo "1) Skontroluj web: https://${DOMAIN}/admin/login"
echo "2) Vytvor Filament admin usera ako ${DOMAIN_USER}:"
echo "   su - ${DOMAIN_USER}"
echo "   cd ${APP_DIR}"
echo "   php artisan make:filament-user"
echo "3) Ak treba, vystav/obnov SSL vo Virtualmine pre ${DOMAIN} a www.${DOMAIN}."
