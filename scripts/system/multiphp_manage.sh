#!/bin/bash
# ==============================================================================
# multiphp_manage.sh — Install or remove PHP versions
# Usage: inetp multiphp_manage --action install --version 7.4
#        inetp multiphp_manage --action remove  --version 7.4
#
# Runs apt-get detached from PHP-FPM via systemd-run.
# Writes status to /var/www/inetpanel/storage/multiphp_{action}_{version}:
#   'running' during execution, 'error\n...' on failure, removed on success.
# ==============================================================================

ACTION=""
VERSION=""
DOMAIN=""
PANEL_DIR="/var/www/inetpanel"
PANEL_DB="$PANEL_DIR/db/inetpanel.db"
STATUS_DIR="$PANEL_DIR/storage"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --action)  ACTION="$2";  shift 2 ;;
        --version) VERSION="$2"; shift 2 ;;
        --domain)  DOMAIN="$2";  shift 2 ;;
        --run-detached) RUN_DETACHED=1; shift ;;
        *) shift ;;
    esac
done

if [[ -z "$ACTION" || -z "$VERSION" ]]; then
    echo '{"success":false,"error":"Usage: --action install|remove --version X.Y"}'
    exit 1
fi

# ── Per-domain PHP version switch (synchronous; not an apt operation) ─────────
# Repoints one domain's FPM pool + Apache vhost handler at another installed PHP
# version. Runs as root here, so it can write /etc/php/*/pool.d and rewrite the
# vhost — unlike the old api/multiphp.php inline 'sudo cp/sed', which used the
# wrong pool name and a malformed sed delimiter and isn't permitted by sudoers.
if [[ "$ACTION" == "set_domain" ]]; then
    [ -z "$DOMAIN" ] && { echo '{"success":false,"error":"--domain required."}'; exit 1; }
    if ! echo "$DOMAIN" | grep -qP '^[a-zA-Z0-9][a-zA-Z0-9.-]{1,253}[a-zA-Z0-9]$'; then
        echo '{"success":false,"error":"Invalid domain."}'; exit 1
    fi
    if ! echo "$VERSION" | grep -qP '^\d+\.\d+$'; then
        echo '{"success":false,"error":"Invalid version format."}'; exit 1
    fi
    if [ ! -f "/usr/sbin/php-fpm${VERSION}" ]; then
        echo "{\"success\":false,\"error\":\"PHP ${VERSION} is not installed.\"}"; exit 1
    fi
    USERNAME=$(sqlite3 "$PANEL_DB" "SELECT h.username FROM domains d JOIN hosting_users h ON d.hosting_user_id=h.id WHERE d.domain_name='${DOMAIN}' LIMIT 1" 2>/dev/null)
    [ -z "$USERNAME" ] && { echo '{"success":false,"error":"Domain not found in panel DB."}'; exit 1; }

    POOL_NAME="${USERNAME}_$(echo "$DOMAIN" | tr '.-' '_')"
    NEW_SOCK="/run/php/php${VERSION}-fpm-${POOL_NAME}.sock"
    NEW_POOL="/etc/php/${VERSION}/fpm/pool.d/${POOL_NAME}.conf"
    VHOST="/etc/apache2/sites-available/${DOMAIN}.conf"
    RELOAD_VERS="$VERSION"

    OLD_POOL=$(ls /etc/php/*/fpm/pool.d/"${POOL_NAME}".conf 2>/dev/null | head -1)
    if [ -n "$OLD_POOL" ] && [ "$OLD_POOL" != "$NEW_POOL" ]; then
        cp "$OLD_POOL" "$NEW_POOL"
        OLD_VER=$(echo "$OLD_POOL" | grep -oP '(?<=/php/)[0-9.]+(?=/fpm)')
        rm -f "$OLD_POOL"
        [ -n "$OLD_VER" ] && [ "$OLD_VER" != "$VERSION" ] && RELOAD_VERS="$RELOAD_VERS $OLD_VER"
    elif [ ! -f "$NEW_POOL" ]; then
        echo '{"success":false,"error":"FPM pool for this domain not found."}'; exit 1
    fi

    # Point the pool at the new version's socket path
    sed -i "s#^listen[[:space:]]*=.*#listen = ${NEW_SOCK}#" "$NEW_POOL"

    # Repoint the Apache vhost FPM handler at the new socket (keeps |fcgi://localhost)
    if [ -f "$VHOST" ]; then
        sed -i "s#proxy:unix:/run/php/[^|\"]*#proxy:unix:${NEW_SOCK}#" "$VHOST"
        a2ensite "${DOMAIN}.conf" >/dev/null 2>&1
        systemctl reload apache2 2>/dev/null
    fi

    # Reload affected FPM masters (restart fallback ensures the new pool is created)
    for rv in $RELOAD_VERS; do
        systemctl reload "php${rv}-fpm" 2>/dev/null || systemctl restart "php${rv}-fpm" 2>/dev/null
    done

    echo "{\"success\":true,\"output\":\"${DOMAIN} switched to PHP ${VERSION}\"}"
    exit 0
fi

if [[ "$ACTION" != "install" && "$ACTION" != "remove" ]]; then
    echo '{"success":false,"error":"Action must be install or remove."}'
    exit 1
fi

# Validate version format
if ! echo "$VERSION" | grep -qP '^\d+\.\d+$'; then
    echo '{"success":false,"error":"Invalid version format."}'
    exit 1
fi

# Panel default PHP version
DEFAULT_PHP=$(sqlite3 "$PANEL_DB" "SELECT value FROM settings WHERE key='php_default_version'" 2>/dev/null)
DEFAULT_PHP=${DEFAULT_PHP:-8.5}

if [[ "$ACTION" == "remove" && "$VERSION" == "$DEFAULT_PHP" ]]; then
    echo '{"success":false,"error":"Cannot remove the panel default PHP version."}'
    exit 1
fi

# Ensure storage dir exists
mkdir -p "$STATUS_DIR"
chown www-data:www-data "$STATUS_DIR"

STATUS_FILE="${STATUS_DIR}/multiphp_${ACTION}_${VERSION}"

# If not already detached, re-launch ourselves in a separate systemd scope
# so that dpkg triggers restarting php-fpm won't kill this script.
if [[ -z "$RUN_DETACHED" ]]; then
    echo "running" > "$STATUS_FILE"
    chown www-data:www-data "$STATUS_FILE"
    chmod 0666 "$STATUS_FILE"
    echo '{"success":true,"output":"started"}'

    # Try systemd-run scope (isolates from FPM restarts).
    # Falls back to direct execution if systemd-run fails (LXC containers).
    if systemd-run --scope --quiet bash "$0" \
        --action "$ACTION" --version "$VERSION" --run-detached \
        >> "$STATUS_DIR/multiphp.log" 2>&1 &
    then
        :
    else
        bash "$0" --action "$ACTION" --version "$VERSION" --run-detached \
            >> "$STATUS_DIR/multiphp.log" 2>&1 &
    fi
    exit 0
fi

# === From here we are in our own systemd scope, safe from FPM restarts ===

export DEBIAN_FRONTEND=noninteractive

# ── Lift the version pin for THIS install only ────────────────────────────────
# install_LAMP.sh writes /etc/apt/preferences.d/php pinning every PHP version
# except the panel's own to Pin-Priority: -1, which stops phpmyadmin's php-cli
# dependency dragging in Debian's parallel PHP stack. -1 means "never install",
# so it also made this feature impossible: `apt-get install php8.3-fpm` returned
# "Package 'php8.3-fpm' has no installation candidate" on every fresh install
# (reported as issue #24).
#
# A deliberate install is not the accident the pin exists to prevent, so allow
# just the requested version for the duration of the run. APT uses the FIRST
# matching entry in preferences.d file order, so this file must sort before
# "php" — hence the 00- prefix. Verified: with it, 8.3 installs while 8.4, 8.2
# and the php-cli virtual dependency all stay blocked.
ALLOW_PIN="/etc/apt/preferences.d/00-inetpanel-multiphp-allow"
cleanup_allow_pin() { rm -f "$ALLOW_PIN"; }

if [[ "$ACTION" == "install" ]]; then
    # Trap before writing, so an interrupt can never leave the pin weakened.
    trap cleanup_allow_pin EXIT INT TERM
    cat > "$ALLOW_PIN" << ALLOWEOF
# Temporary — written by inetp multiphp_manage for a deliberate install of
# PHP ${VERSION}, and removed when it finishes. If this file is still here, a
# previous run was killed; it is safe to delete.
Package: php${VERSION}*
Pin: origin packages.sury.org
Pin-Priority: 600
ALLOWEOF
    chmod 0644 "$ALLOW_PIN"

    # Refresh the lists. sury publishes new builds constantly, and a box whose
    # index predates the requested version sees the same "no installation
    # candidate" error for an entirely different reason. Non-fatal: a single
    # unrelated broken repo must not block the install.
    apt-get update -o Dir::Etc::sourceparts=/etc/apt/sources.list.d < /dev/null >/dev/null 2>&1 || true
fi

# Run apt — retry once if dpkg was interrupted
for attempt in 1 2; do
    dpkg --configure -a < /dev/null 2>/dev/null || true

    if [[ "$ACTION" == "install" ]]; then
        RESULT=$(apt-get install -y "php${VERSION}-fpm" "php${VERSION}-cli" "php${VERSION}-common" \
            "php${VERSION}-mysql" "php${VERSION}-xml" "php${VERSION}-mbstring" "php${VERSION}-curl" \
            "php${VERSION}-zip" < /dev/null 2>&1)
    else
        RESULT=$(apt-get purge -y "php${VERSION}-*" < /dev/null 2>&1)
        apt-get autoremove -y < /dev/null 2>/dev/null
    fi

    dpkg --configure -a < /dev/null 2>/dev/null || true

    # Verify by checking the actual binary
    if [[ "$ACTION" == "install" && -f "/usr/sbin/php-fpm${VERSION}" ]]; then
        break
    elif [[ "$ACTION" == "remove" && ! -f "/usr/sbin/php-fpm${VERSION}" ]]; then
        break
    fi

    [[ $attempt -eq 2 ]] && break
done

# Final verification
if [[ "$ACTION" == "install" ]]; then
    if [[ ! -f "/usr/sbin/php-fpm${VERSION}" ]]; then
        echo "error" > "$STATUS_FILE"
        echo "$RESULT" >> "$STATUS_FILE"
        exit 1
    fi
else
    if [[ -f "/usr/sbin/php-fpm${VERSION}" ]]; then
        echo "error" > "$STATUS_FILE"
        echo "$RESULT" >> "$STATUS_FILE"
        exit 1
    fi
fi

# Core operation succeeded — remove status file so UI unblocks immediately
rm -f "$STATUS_FILE"

# Post-install setup
if [[ "$ACTION" == "install" ]]; then
    systemctl enable "php${VERSION}-fpm" 2>/dev/null
    systemctl start "php${VERSION}-fpm" 2>/dev/null
    INI="/etc/php/${VERSION}/fpm/php.ini"
    if [[ -f "$INI" ]]; then
        sed -i 's/^upload_max_filesize[[:space:]]*=.*/upload_max_filesize = 100M/' "$INI"
        sed -i 's/^post_max_size[[:space:]]*=.*/post_max_size = 100M/' "$INI"
    fi
    systemctl reload "php${VERSION}-fpm" 2>/dev/null
fi

# Post-remove cleanup: reinstall default PHP packages that may have been broken
if [[ "$ACTION" == "remove" ]]; then
    dpkg --configure -a < /dev/null 2>/dev/null || true
    apt-get install --reinstall -y "php${DEFAULT_PHP}-mysql" "php${DEFAULT_PHP}-sqlite3" \
        "php${DEFAULT_PHP}-common" phpmyadmin < /dev/null 2>/dev/null
    dpkg --configure -a < /dev/null 2>/dev/null || true
    phpenmod -v "$DEFAULT_PHP" -s fpm calendar ctype curl dom exif fileinfo ftp gd gettext \
        gmp iconv intl mbstring mysqli pdo_mysql pdo_sqlite phar posix readline shmop \
        simplexml sockets sqlite3 sysvmsg sysvsem sysvshm tokenizer xmlreader xmlwriter \
        xsl zip 2>/dev/null
fi

# Restart panel default FPM
systemctl restart "php${DEFAULT_PHP}-fpm" 2>/dev/null
