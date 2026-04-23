# Virtualmin Laravel Scripts

Parametrický Bash skript na nasadenie **Laravel + Filament + PostgreSQL** na **existujúcej Virtualmin doméne** s **Nginx**.

Skript je určený na rýchly prvý deploy aj na opakované pokusy pri testovaní. Vie pripraviť Laravel projekt, PostgreSQL databázu, Nginx konfiguráciu, Supervisor worker, cron a voliteľne aj prvého Filament admin používateľa.

## Čo skript robí

- overí prostredie a potrebné služby
- vie doinštalovať potrebné balíky, ak nepoužiješ `--skip-packages`
- vytvorí alebo obnoví PostgreSQL databázu a rolu
- vytvorí nový Laravel projekt
- doinštaluje Livewire a Filament
- nastaví `.env`
- vygeneruje silné heslá, ak ich nezadáš ručne
- vytvorí prvého admin používateľa do Filamentu
- publikuje **Filament assety**
- overí existenciu Filament CSS/JS súborov
- nastaví alebo opraví Nginx pre Laravel
- nastaví cron pre `schedule:run`
- nastaví Supervisor worker pre queue
- uloží prihlasovacie údaje do root-only súboru v `/root`

## Predpoklady

- doména už existuje vo Virtualmine
- systémový používateľ domény už existuje
- Nginx a PHP-FPM sú používané pre web
- skript spúšťaš ako `root`

## Hlavný skript

`scripts/setup-laravel-virtualmin.sh`

## Základné použitie

```bash
sudo bash scripts/setup-laravel-virtualmin.sh \
  --domain nbv.sk \
  --user nbv
```

Ak nezadáš `--db-pass` a `--admin-pass`, skript ich vygeneruje automaticky.

## Dôležité prepínače

### Základné

- `--domain DOMAIN`  
  názov domény, napr. `nbv.sk`

- `--user USER`  
  systémový používateľ domény, napr. `nbv`

- `--db-name NAME`  
  default: `<user>_matrika`

- `--db-user NAME`  
  default: `<user>_matrika_user`

- `--db-pass PASS`  
  PostgreSQL heslo; ak chýba, skript ho vygeneruje

- `--app-dir PATH`  
  default: `/home/<user>/laravel-app`

- `--php-version VERSION`  
  default: `8.4`

- `--skip-packages`  
  preskočí `apt install`

- `--skip-cert-check`  
  preskočí kontrolu HTTPS certifikátu na konci

- `--dry-run`  
  iba vypíše kroky bez vykonania zmien

### Admin používateľ

- `--no-admin`  
  nevytvorí prvého admin používateľa

- `--admin-name NAME`  
  default: `Administrator`

- `--admin-email EMAIL`  
  default: `admin@<domain>`

- `--admin-pass PASS`  
  ak chýba, skript ho vygeneruje

### Reset pred novým deployom

- `--reset-first`  
  zmaže starý Laravel pokus pred novým deployom

- `--reset-drop-db`  
  pri resetovaní zmaže aj PostgreSQL databázu

- `--reset-drop-role`  
  pri resetovaní zmaže aj PostgreSQL rolu / usera

- `--reset-yes`  
  reset prebehne bez interaktívneho potvrdenia

## Odporúčaný postup

### 1. Test nanečisto

```bash
bash scripts/setup-laravel-virtualmin.sh \
  --domain nbv.sk \
  --user nbv \
  --skip-packages \
  --dry-run
```

### 2. Prvý ostrý deploy

```bash
bash scripts/setup-laravel-virtualmin.sh \
  --domain nbv.sk \
  --user nbv
```

### 3. Opakovaný čistý pokus

```bash
bash scripts/setup-laravel-virtualmin.sh \
  --domain nbv.sk \
  --user nbv \
  --skip-packages \
  --reset-first \
  --reset-drop-db \
  --reset-drop-role \
  --reset-yes
```

### 4. Oprava Nginx / SSL po vystavení certifikátu

Ak už projekt existuje a potrebuješ len dorobiť HTTPS konfiguráciu po vystavení certifikátu vo Virtualmine, spusti skript znova **bez resetu**:

```bash
bash scripts/setup-laravel-virtualmin.sh \
  --domain nbv.sk \
  --user nbv \
  --skip-packages
```

## Filament assety

Skript po inštalácii Filamentu automaticky spustí:

```bash
php artisan filament:assets
```

Potom overí, že skutočne existujú aspoň tieto súbory:

- `public/css/filament/filament/app.css`
- `public/js/filament/filament/app.js`

Ak sa po prvom publishi nenájdu, skript publish skúsi ešte raz. Ak stále chýbajú, deploy skončí chybou, aby si nedostal rozbitý login bez štýlov.

## SSL správanie

Skript vie hľadať SSL súbory v týchto cestách:

- `/home/<user>/ssl.combined` + `/home/<user>/ssl.key`
- `/home/<user>/ssl.cert` + `/home/<user>/ssl.key`
- `/etc/letsencrypt/live/<domain>/fullchain.pem` + `/etc/letsencrypt/live/<domain>/privkey.pem`
- fallback aj cez `/etc/letsencrypt/archive/<domain>/`

Ak sa SSL súbory nájdu, skript pripraví HTTPS Nginx blok automaticky.  
Ak sa nenájdu, pripraví HTTP-only konfiguráciu a po vystavení certifikátu stačí skript spustiť znova bez resetu.

## Výstup po úspechu

Po úspešnom behu skript vypíše:

- URL admin loginu
- email a heslo admin používateľa
- PostgreSQL meno databázy, používateľa a heslo
- cestu k root-only súboru s prihlasovacími údajmi

Príklad:

```text
Hotovo. Ďalšie kroky:
1) Skontroluj web: https://nbv.sk/admin/login
2) Prihlasovacie údaje admin používateľa:
   Email: admin@nbv.sk
   Heslo: ...
3) Databázové údaje:
   DB name: nbv_matrika
   DB user: nbv_matrika_user
   DB pass: ...
4) Uložené aj do root súboru: /root/nbv.sk-deploy-credentials-YYYYMMDD-HHMMSS.txt
```

## Kam sa ukladajú vygenerované heslá

Skript vytvorí root-only súbor v tvare:

```text
/root/<domain>-deploy-credentials-<timestamp>.txt
```

Práva sú nastavené na `600`.

## Poznámky

- Pri deployi sa môžu objaviť warningy typu `Migration already exists.` pre voliteľné queue migrácie. To je akceptované a deploy tým nekončí.
- Ak Nginx vypíše warning typu `listen ... http2 directive is deprecated`, ide o nefatálne upozornenie.
- Koreňová route `/` nemusí byť definovaná. Dôležitý test po deployi je `https://<domain>/admin/login`.

## Kontrola po deployi

```bash
openssl s_client -connect nbv.sk:443 -servername nbv.sk </dev/null 2>/dev/null | openssl x509 -noout -subject -issuer -ext subjectAltName
```

Ak je všetko správne, medzi SAN záznamami uvidíš:

- `DNS:nbv.sk`
- `DNS:www.nbv.sk`

## Git workflow

Odporúčaný názov skriptov v repozitári nechaj stabilný:

- `scripts/setup-laravel-virtualmin.sh`
- `scripts/reset-laravel-virtualmin.sh`

Verzie sleduj cez:

- commity
- tagy
- GitHub Releases

Nie cez názvy typu `-v4`, `-v5`, `-final-final`.

## Licencia

Použi podľa potreby v rámci vlastnej infraštruktúry.
