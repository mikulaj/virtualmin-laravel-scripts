# README - setup-laravel-virtualmin.sh

Tento skript je určený na **čisté alebo takmer čisté nasadenie Laravel + Filament + PostgreSQL** na **už existujúcej Virtualmin doméne** s Nginx.

Je robený tak, aby aplikačné kroky bežali správne cez používateľa domény, napríklad:

```bash
su - fema
```

nie ako `root`.

---

## Na čo je skript určený

Skript automatizuje tieto kroky:

- overenie / doinštalovanie potrebných balíkov
- vytvorenie PostgreSQL databázy a používateľa
- vytvorenie Laravel projektu
- vytvorenie `.env`
- inštaláciu Livewire a Filament
- opravu `AdminPanelProvider.php`
- opravu `User.php` kvôli Filament 403 po prihlásení
- Laravel migrácie
- `storage:link`
- frontend build cez npm
- opravu Nginx root na Laravel `public`
- cron pre scheduler
- Supervisor pre queue worker

---

## Predpoklady

Pred spustením skriptu musí platiť:

1. Virtualmin doména už existuje.
2. Existuje systémový používateľ domény, napríklad `fema`.
3. Existuje Nginx config domény:
   - `/etc/nginx/sites-available/<domena>.conf`
4. Skript spúšťaš ako `root`.
5. DNS a SSL riešiš samostatne.

---

## Čo skript nerieši

Skript zámerne nerieši:

- vytvorenie Virtualmin domény
- DNS záznamy
- vystavenie SSL certifikátu
- vytvorenie Filament admin používateľa interaktívne

Po dobehnutí skriptu admin usera vytvoríš ručne.

---

## Základné použitie

```bash
sudo bash setup-laravel-virtualmin.sh \
  --domain fema.sk \
  --user fema \
  --db-pass 'SILNE_HESLO'
```

---

## Parametre

### Povinné

- `--domain` - doména, napr. `fema.sk`
- `--user` - systémový používateľ domény, napr. `fema`
- `--db-pass` - heslo pre PostgreSQL používateľa

### Voliteľné

- `--db-name` - názov databázy
  - default: `<user>_matrika`
- `--db-user` - názov DB používateľa
  - default: `<user>_matrika_user`
- `--app-dir` - cieľový adresár aplikácie
  - default: `/home/<user>/laravel-app`
- `--php-version` - verzia PHP
  - default: `8.4`
- `--skip-packages` - nebeží `apt install`
- `--dry-run` - iba vypíše kroky, nič nemení

---

## Príklady

### Minimálny príklad

```bash
sudo bash setup-laravel-virtualmin.sh \
  --domain fema.sk \
  --user fema \
  --db-pass 'MojeSilneHeslo'
```

### Vlastná DB a vlastný app adresár

```bash
sudo bash setup-laravel-virtualmin.sh \
  --domain fema.sk \
  --user fema \
  --db-pass 'MojeSilneHeslo' \
  --db-name fema_app \
  --db-user fema_app_user \
  --app-dir /home/fema/apps/matrika
```

### Test bez zásahu

```bash
sudo bash setup-laravel-virtualmin.sh \
  --domain fema.sk \
  --user fema \
  --db-pass 'MojeSilneHeslo' \
  --dry-run
```

---

## Odporúčaný postup použitia

1. skontrolovať, že Virtualmin doména už existuje
2. spraviť `--dry-run`
3. spraviť zálohu nginx configu a databáz, ak ide o starší server
4. spustiť skript na testovacej alebo starej doméne
5. po úspechu spustiť na novej doméne

---

## Čo skript mení

### Laravel adresár

Default:

```text
/home/<user>/laravel-app
```

### Webroot

Skript patchuje Nginx tak, aby root smeroval na:

```text
/home/<user>/laravel-app/public
```

### PostgreSQL

Vytvorí:

- DB používateľa
- databázu
- granty

### Laravel `.env`

Nastaví najmä:

- `APP_ENV=production`
- `APP_DEBUG=false`
- `APP_URL=https://<domain>`
- `DB_CONNECTION=pgsql`
- `SESSION_DRIVER=file`
- `CACHE_STORE=file`
- `QUEUE_CONNECTION=database`

### Filament opravy

Skript pridá / opraví:

- `AdminPanelProvider.php`
- `User.php` s `FilamentUser` a `canAccessPanel()`

To rieši aj častý problém:

- `403 Forbidden` po prihlásení do Filamentu

---

## Čo spraviť po dobehnutí skriptu

### 1. vytvoriť Filament admin používateľa

```bash
su - fema
cd /home/fema/laravel-app
php artisan make:filament-user
```

### 2. overiť admin login

```text
https://fema.sk/admin/login
```

### 3. ak ešte nie je SSL
vystaviť ho cez Virtualmin samostatne

---

## Dôležité upozornenia

### 1. Virtualmin môže config neskôr prepísať
Skript síce upraví Nginx config správne pre Laravel, ale ak neskôr Virtualmin vygeneruje config znovu, môže časť zmien prepísať.

Preto je dobré:

- otestovať skript na starej / testovacej doméne
- po finálnom nastavení si skontrolovať `fema.sk.conf`

### 2. Nie je to skript na opravu úplne rozbitého prostredia
Najlepšie funguje na:

- novej doméne
- čistej inštalácii
- alebo aspoň na prehľadnom testovacom serveri

### 3. Filament admin používateľa nerobí automaticky
Je to zámer. Heslo admina sa lepšie zadáva ručne.

---

## Rýchla kontrola po inštalácii

Ako používateľ domény:

```bash
su - fema
cd /home/fema/laravel-app
php artisan about
php artisan route:list | grep admin
```

Ako root:

```bash
nginx -t
systemctl status nginx
systemctl status php8.4-fpm
systemctl status postgresql
systemctl status supervisor
```

---

## Typické problémy

### 404 na `/admin/login`
Najčastejšie zle nastavený Nginx root alebo chýbajúce `try_files`.

### 500 Server Error
Pozrieť:

```bash
tail -f /var/log/virtualmin/<domena>_error_log
su - <user>
cd /home/<user>/laravel-app
tail -f storage/logs/laravel.log
```

### 403 po prihlásení
Zvyčajne chýba správne upravený `User.php`.
Tento skript to rieši automaticky.

### Filament panel nejde
Skontrolovať:

- `bootstrap/providers.php`
- `app/Providers/Filament/AdminPanelProvider.php`
- `php artisan optimize:clear`

---

## Odporúčanie na test
Pred ostrým použitím:

- spusti skript na starej VPS alebo testovacej doméne
- ideálne s `--dry-run`
- potom ostrá doména

---

## Súvisiace ručné príkazy po úspešnom nasadení

```bash
su - <user>
cd /home/<user>/laravel-app
php artisan make:filament-user
php artisan optimize
```

---

## Stručné zhrnutie

Tento skript je vhodný na:

- novú Laravel + Filament inštaláciu
- existujúcu Virtualmin doménu
- PostgreSQL
- Nginx
- nasadenie s korektným `su - <user>` workflow

Na ostrý produkčný server je najlepšie ho najprv preveriť na testovacej doméne.
