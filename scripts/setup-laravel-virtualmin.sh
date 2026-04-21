#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
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
  --dry-run                 iba vypíše kroky, nič nemení

Poznámky:
- Skript predpokladá, že Virtualmin doména už existuje.
- Aplikačné kroky bežia vždy cez: su - <user>
- Nerieši DNS ani vystavenie SSL certifikátu.
- Vytvorenie Filament admin používateľa necháva na konci ako ručný krok.
EOF
}

DOMAIN=""
DOMAIN_USER=""
DB_PASS=""
DB_NAME=""
DB_USER=""
APP_DIR=""
PHP_VERSION="8.4"
SKIP_PACKAGES=0
DRY_RUN=0

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
    --dry-run) DRY_RUN=1; shift ;;
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

require_file() {
  [[ -f "$1" ]] || { echo "Chýba súbor: $1" >&2; exit 1; }
}

require_dir() {
  [[ -d "$1" ]] || { echo "Chýba adresár: $1" >&2; exit 1; }
}

require_dir "/home/${DOMAIN_USER}"
require_file "$NGINX_CONF"

if [[ $SKIP_PACKAGES -eq 0 ]]; then
  run "apt update"
  run "apt install -y git unzip curl ca-certificates composer postgresql postgresql-client nodejs npm redis-server supervisor php${PHP_VERSION}-cli php${PHP_VERSION}-fpm php${PHP_VERSION}-pgsql php${PHP_VERSION}-mbstring php${PHP_VERSION}-xml php${PHP_VERSION}-curl php${PHP_VERSION}-zip php${PHP_VERSION}-bcmath php${PHP_VERSION}-intl php${PHP_VERSION}-gd php${PHP_VERSION}-redis"
  run "systemctl enable --now postgresql redis-server supervisor php${PHP_VERSION}-fpm nginx"
fi

# PostgreSQL create if missing
if [[ $DRY_RUN -eq 0 ]]; then
  if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" | grep -q 1; then
    sudo -u postgres psql -c "CREATE ROLE ${DB_USER} WITH LOGIN PASSWORD '${DB_PASS//\'/\'\'}';"
  fi
  if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1; then
    sudo -u postgres psql -c "CREATE DATABASE ${DB_NAME} OWNER ${DB_USER} ENCODING 'UTF8';"
  fi
  sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};" >/dev/null
else
  echo "+ create PostgreSQL role ${DB_USER} if missing"
  echo "+ create PostgreSQL database ${DB_NAME} if missing"
fi

# Laravel skeleton
if [[ ! -d "$APP_DIR" ]]; then
  run_user "composer create-project laravel/laravel '${APP_DIR}'"
fi

run "chown -R ${DOMAIN_USER}:${DOMAIN_USER} '${APP_DIR}'"
run "mkdir -p '${APP_DIR}/storage/logs' '${APP_DIR}/bootstrap/cache'"
run "chmod -R ug+rwx '${APP_DIR}/storage' '${APP_DIR}/bootstrap/cache'"

# .env
APP_KEY_CURRENT=""
[[ -f "${APP_DIR}/.env" ]] && APP_KEY_CURRENT="$(grep -E '^APP_KEY=' "${APP_DIR}/.env" | head -1 | cut -d= -f2- || true)"
[[ -f "${APP_DIR}/.env" ]] && run "cp '${APP_DIR}/.env' '${APP_DIR}/.env.bak.${TIMESTAMP}'"

cat > "${APP_DIR}/.env" <<EOF
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
DB_PASSWORD='${DB_PASS}'

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
EOF
run "chown ${DOMAIN_USER}:${DOMAIN_USER} '${APP_DIR}/.env'"

# Ensure AppServiceProvider exists
mkdir -p "${APP_DIR}/app/Providers" "${APP_DIR}/app/Providers/Filament"
if [[ ! -f "${APP_DIR}/app/Providers/AppServiceProvider.php" ]]; then
cat > "${APP_DIR}/app/Providers/AppServiceProvider.php" <<'PHP'
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
PHP
fi

# Install Livewire + Filament only if missing
run_user "cd '${APP_DIR}' && composer show livewire/livewire >/dev/null 2>&1 || composer require livewire/livewire"
run_user "cd '${APP_DIR}' && composer show filament/filament >/dev/null 2>&1 || composer require filament/filament:'^5.0' -W"

# AdminPanelProvider with corrected middleware and default panel
cat > "${APP_DIR}/app/Providers/Filament/AdminPanelProvider.php" <<'PHP'
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
PHP

# User model with FilamentUser fix (403 fix)
cat > "${APP_DIR}/app/Models/User.php" <<'PHP'
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
PHP

run "chown -R ${DOMAIN_USER}:${DOMAIN_USER} '${APP_DIR}/app'"

# Ensure provider registration
if [[ -f "$BOOTSTRAP_PROVIDERS" ]]; then
  if ! grep -q "App\\Providers\\Filament\\AdminPanelProvider::class" "$BOOTSTRAP_PROVIDERS"; then
    python3 - <<PY
from pathlib import Path
p=Path(r"$BOOTSTRAP_PROVIDERS")
text=p.read_text()
marker='return ['
insert="return [\n    App\\\\Providers\\\\Filament\\\\AdminPanelProvider::class,"
if marker in text:
    text=text.replace(marker, insert, 1)
else:
    raise SystemExit('Neviem upraviť bootstrap/providers.php')
p.write_text(text)
PY
  fi
fi

# Ensure queue migrations if missing
if [[ $DRY_RUN -eq 0 ]]; then
  shopt -s nullglob
  JOB_MIG=("${APP_DIR}"/database/migrations/*_create_jobs_table.php)
  BATCH_MIG=("${APP_DIR}"/database/migrations/*_create_job_batches_table.php)
  FAILED_MIG=("${APP_DIR}"/database/migrations/*_create_failed_jobs_table.php)
  shopt -u nullglob
  [[ ${#JOB_MIG[@]} -gt 0 ]] || run_user "cd '${APP_DIR}' && php artisan queue:table"
  [[ ${#BATCH_MIG[@]} -gt 0 ]] || run_user "cd '${APP_DIR}' && php artisan make:queue-batches-table"
  [[ ${#FAILED_MIG[@]} -gt 0 ]] || run_user "cd '${APP_DIR}' && php artisan queue:failed-table"
else
  echo "+ ensure queue migration files exist"
fi

# App setup as domain user
run_user "cd '${APP_DIR}' && php artisan key:generate --force"
run_user "cd '${APP_DIR}' && php artisan storage:link || true"
run_user "cd '${APP_DIR}' && php artisan migrate --force"
run_user "cd '${APP_DIR}' && npm install"
run_user "cd '${APP_DIR}' && npm run build"
run_user "cd '${APP_DIR}' && composer dump-autoload -o"
run_user "cd '${APP_DIR}' && php artisan optimize:clear"
run_user "cd '${APP_DIR}' && php artisan optimize"

# Patch nginx conf while preserving current socket/ssl paths
require_file "$NGINX_CONF"
run "cp '${NGINX_CONF}' '${NGINX_CONF}.bak.${TIMESTAMP}'"
python3 - <<PY
import re
from pathlib import Path
conf = Path(r"$NGINX_CONF")
text = conf.read_text()

domain = r"$DOMAIN"
app_public = r"$APP_PUBLIC_DIR"

text = re.sub(r"server_name\s+[^;]+;", f"server_name {domain} www.{domain};", text, count=1)
text = re.sub(r"root\s+[^;]+;", f"root {app_public};", text, count=1)
text = re.sub(r'fastcgi_param\s+SCRIPT_FILENAME\s+"[^"]+\\\$fastcgi_script_name";', f'fastcgi_param SCRIPT_FILENAME "{app_public}\\$fastcgi_script_name";', text, count=1)
text = re.sub(r"fastcgi_param\s+DOCUMENT_ROOT\s+[^;]+;", f"fastcgi_param DOCUMENT_ROOT {app_public};", text, count=1)

if 'location / {' not in text:
    replacement = "location ^~ /.well-known/ {\n\t\ttry_files $uri /;\n\t}\n\tlocation / {\n\t\ttry_files $uri $uri/ /index.php?$query_string;\n\t}"
    text = text.replace("location ^~ /.well-known/ {\n\t\ttry_files $uri /;\n\t}", replacement, 1)

conf.write_text(text)
PY

# Ensure enabled symlink
if [[ ! -L "$NGINX_ENABLED" ]]; then
  run "rm -f '${NGINX_ENABLED}'"
  run "ln -s '${NGINX_CONF}' '${NGINX_ENABLED}'"
fi

run "nginx -t"
run "systemctl restart php${PHP_VERSION}-fpm"
run "systemctl restart nginx"

# Scheduler cron
CRONLINE="* * * * * cd ${APP_DIR} && php artisan schedule:run >> /dev/null 2>&1"
if [[ $DRY_RUN -eq 0 ]]; then
  crontab -u "$DOMAIN_USER" -l 2>/dev/null | grep -F "$CRONLINE" >/dev/null || \
    (crontab -u "$DOMAIN_USER" -l 2>/dev/null; echo "$CRONLINE") | crontab -u "$DOMAIN_USER" -
else
  echo "+ ensure crontab for ${DOMAIN_USER}: ${CRONLINE}"
fi

# Supervisor queue worker
SUPERVISOR_CONF="/etc/supervisor/conf.d/${DOMAIN_USER}-laravel-worker.conf"
cat > "$SUPERVISOR_CONF" <<EOF
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
EOF
run "supervisorctl reread"
run "supervisorctl update"
run "supervisorctl restart ${DOMAIN_USER}-laravel-worker:* || supervisorctl start ${DOMAIN_USER}-laravel-worker:*"

# Final checks
run_user "cd '${APP_DIR}' && php artisan about"
run_user "cd '${APP_DIR}' && php artisan route:list | grep admin || true"

echo
echo "Hotovo. Ďalšie kroky:"
echo "1) Skontroluj web: https://${DOMAIN}/admin/login"
echo "2) Vytvor Filament admin usera ako ${DOMAIN_USER}:"
echo "   su - ${DOMAIN_USER}"
echo "   cd ${APP_DIR}"
echo "   php artisan make:filament-user"
echo "3) Ak treba, vystav/obnov SSL vo Virtualmine pre ${DOMAIN} a www.${DOMAIN}."
