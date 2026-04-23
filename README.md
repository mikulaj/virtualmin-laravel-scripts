# Virtualmin Laravel Scripts

A practical deployment toolkit for Laravel + Filament on existing Virtualmin domains with Nginx and PostgreSQL.

## What this project is

This repository contains Bash scripts for deploying, resetting, and removing **Laravel + Filament** projects on **existing Virtualmin domains** that use:

- **Nginx**
- **PHP-FPM**
- **PostgreSQL**
- **Debian-based systems**

The scripts automate the repetitive parts of the deployment workflow so you can provision new Laravel + Filament projects faster and more consistently.

## Who this is for

This project is useful for people who already manage servers with a stack similar to this:

- Virtualmin
- Nginx
- PHP-FPM
- PostgreSQL
- Laravel + Filament

It is especially helpful if you regularly:

- deploy fresh Laravel projects on new domains
- repeat deployments during testing
- want consistent database, Nginx, queue, and admin-user setup
- want generated credentials stored safely for later use

## Who this is not for

This is **not** a general-purpose Laravel installer for arbitrary server setups.

It does **not** create the Virtualmin domain itself, and it assumes the domain already exists.

If your environment is significantly different from the stack above, you will likely need to adapt the scripts.

## What the scripts do

### `scripts/setup-laravel-virtualmin.sh`

Deploys a Laravel + Filament project on an existing Virtualmin domain.

It can:

- verify the environment and required services
- install required packages unless `--skip-packages` is used
- create or recreate the PostgreSQL database and role
- create a new Laravel project
- install Livewire and Filament
- configure `.env`
- generate strong passwords if you do not provide them manually
- create the first Filament admin user
- publish and verify Filament assets
- create or repair the Nginx configuration for Laravel
- detect SSL certificates and configure HTTPS when available
- configure cron for `schedule:run`
- configure a Supervisor worker for queues
- store generated credentials in a root-only file under `/root`

### `scripts/reset-laravel-virtualmin.sh`

Removes the current Laravel deployment attempt so you can redeploy cleanly.

### `scripts/remove-laravel-virtualmin.sh`

Removes the Laravel project and can also optionally remove:

- PostgreSQL database
- PostgreSQL role / user
- Nginx config
- generated credentials files

## What this project assumes already exists

Before running the setup script, make sure that:

- the Virtualmin domain already exists
- the domain system user already exists
- DNS points to the server
- Nginx and PHP-FPM are available
- PostgreSQL is available
- you run the script as `root`

## What makes this useful

This project automates the repetitive parts of deploying Laravel + Filament on Virtualmin, including:

- PostgreSQL database and role creation
- `.env` generation
- admin user creation
- Filament asset publishing and verification
- Nginx setup
- SSL detection
- Supervisor and cron setup

## Quick start

### Dry run first

```bash
bash scripts/setup-laravel-virtualmin.sh \
  --domain example.com \
  --user exampleuser \
  --skip-packages \
  --dry-run
```

### First real deployment

```bash
bash scripts/setup-laravel-virtualmin.sh \
  --domain example.com \
  --user exampleuser
```

If you do not provide `--db-pass` or `--admin-pass`, the script generates them automatically.

## Typical workflows

### 1. First deployment on a new Virtualmin domain

```bash
bash scripts/setup-laravel-virtualmin.sh \
  --domain example.com \
  --user exampleuser
```

### 2. Repeated clean redeploy during testing

```bash
bash scripts/setup-laravel-virtualmin.sh \
  --domain example.com \
  --user exampleuser \
  --skip-packages \
  --reset-first \
  --reset-drop-db \
  --reset-drop-role \
  --reset-yes
```

### 3. Re-run after a Let's Encrypt certificate has been issued

If the project already exists and you only need to enable HTTPS after issuing a certificate in Virtualmin, run the setup script again **without reset**:

```bash
bash scripts/setup-laravel-virtualmin.sh \
  --domain example.com \
  --user exampleuser \
  --skip-packages
```

### 4. Remove the deployment attempt and try again

```bash
bash scripts/reset-laravel-virtualmin.sh \
  --domain example.com \
  --user exampleuser \
  --drop-db \
  --drop-role \
  --yes
```

### 5. Remove the Laravel project completely

```bash
bash scripts/remove-laravel-virtualmin.sh \
  --domain example.com \
  --user exampleuser \
  --drop-db \
  --drop-role \
  --remove-nginx-conf \
  --remove-credentials \
  --yes
```

## Important options

### Core options

- `--domain DOMAIN`  
  Domain name, for example `example.com`

- `--user USER`  
  Domain system user, for example `exampleuser`

- `--db-name NAME`  
  default: `<user>`

- `--db-user NAME`  
  default: `<user>`

- `--db-pass PASS`  
  PostgreSQL password; if omitted, the script generates one

- `--app-dir PATH`  
  default: `/home/<user>/laravel-app`

- `--php-version VERSION`  
  default: `8.4`

- `--skip-packages`  
  skips `apt install`

- `--skip-cert-check`  
  skips HTTPS certificate validation at the end

- `--dry-run`  
  prints the steps without applying changes

### Admin user options

- `--no-admin`  
  do not create the first admin user

- `--admin-name NAME`  
  default: `Administrator`

- `--admin-email EMAIL`  
  default: `admin@<domain>`

- `--admin-pass PASS`  
  if omitted, the script generates one

### Reset options before a new deployment

- `--reset-first`  
  removes the previous Laravel attempt before deploying again

- `--reset-drop-db`  
  also drops the PostgreSQL database during reset

- `--reset-drop-role`  
  also drops the PostgreSQL role / user during reset

- `--reset-yes`  
  runs the reset without interactive confirmation

## Filament assets

After installing Filament, the setup script automatically runs:

```bash
php artisan filament:assets
```

Then it verifies that at least these files exist:

- `public/css/filament/filament/app.css`
- `public/js/filament/filament/app.js`

If the assets are not found after the first publish, the script tries again. If they are still missing, deployment stops with an error so you do not end up with a broken login page without styles.

## SSL behavior

The setup script can detect SSL files in these locations:

- `/home/<user>/ssl.combined` + `/home/<user>/ssl.key`
- `/home/<user>/ssl.cert` + `/home/<user>/ssl.key`
- `/etc/letsencrypt/live/<domain>/fullchain.pem` + `/etc/letsencrypt/live/<domain>/privkey.pem`
- fallback through `/etc/letsencrypt/archive/<domain>/`

If SSL files are found, the script automatically prepares an HTTPS Nginx block.

If they are not found, it prepares an HTTP-only configuration. After issuing the certificate, you can simply run the setup script again without reset.

## Output after success

After a successful run, the setup script prints:

- the admin login URL
- the admin user's email and password
- the PostgreSQL database name, user, and password
- the path to the root-only credentials file

Example:

```text
Done. Next steps:
1) Check the website: https://example.com/admin/login
2) Admin credentials:
   Email: admin@example.com
   Password: ...
3) Database credentials:
   DB name: exampleuser
   DB user: exampleuser
   DB pass: ...
4) Also stored in a root file: /root/example.com-deploy-credentials-YYYYMMDD-HHMMSS.txt
```

## Where generated credentials are stored

The script creates a root-only file in this format:

```text
/root/<domain>-deploy-credentials-<timestamp>.txt
```

Permissions are set to `600`.

## Safety notes

Warning:

The reset and remove scripts can delete the Laravel project directory, PostgreSQL database, PostgreSQL role, Nginx config, and generated credentials depending on the options you use.

Always test with `--dry-run` first when you are not fully sure what will happen.

## Troubleshooting

### The login page loads without styles

Run:

```bash
su - exampleuser
cd /home/exampleuser/laravel-app
php artisan filament:assets
php artisan optimize:clear
php artisan optimize
```

Then verify that these files exist:

- `public/css/filament/filament/app.css`
- `public/js/filament/filament/app.js`

### HTTPS uses the wrong certificate

Run the setup script again after the correct certificate has been issued:

```bash
bash scripts/setup-laravel-virtualmin.sh \
  --domain example.com \
  --user exampleuser \
  --skip-packages
```

Then verify:

```bash
openssl s_client -connect example.com:443 -servername example.com </dev/null 2>/dev/null | openssl x509 -noout -subject -issuer -ext subjectAltName
```

SAN should include:

- `DNS:example.com`
- `DNS:www.example.com`

### The website root returns 404

The root route `/` does not have to be defined. The most important post-deploy test is:

```text
https://example.com/admin/login
```

### Optional queue migration warnings appear

Warnings such as `Migration already exists.` for optional queue migrations are acceptable and do not stop the deployment.

## Checks after deployment

### Check Laravel / Filament routes

```bash
su - exampleuser
cd /home/exampleuser/laravel-app
php artisan route:list | grep admin
```

### Check HTTPS certificate

```bash
openssl s_client -connect example.com:443 -servername example.com </dev/null 2>/dev/null | openssl x509 -noout -subject -issuer -ext subjectAltName
```

If everything is correct, SAN should include:

- `DNS:example.com`
- `DNS:www.example.com`

## GitHub repository description

**Deployment and reset scripts for Laravel + Filament + PostgreSQL on Virtualmin with Nginx.**

Suggested GitHub topics:

- `laravel`
- `filament`
- `virtualmin`
- `nginx`
- `postgresql`
- `bash`
- `deployment`
- `php`

## Git workflow

Keep stable script names in the repository:

- `scripts/setup-laravel-virtualmin.sh`
- `scripts/reset-laravel-virtualmin.sh`
- `scripts/remove-laravel-virtualmin.sh`

Track versions through:

- commits
- tags
- GitHub Releases

Not through file names like `-v4`, `-v5`, or `-final-final`.

## License

Use as needed within your own infrastructure and deployment workflow.
