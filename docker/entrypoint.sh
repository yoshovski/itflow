#!/bin/sh
# ITFlow container entrypoint.
#
#   apache2-foreground (default)  web server; applies pending DB migrations first
#   cron                          runs cron/cron.php once a minute (the script install's crontab line)
#   anything else                 exec'd as-is (e.g. `php scripts/update_cli.php --update_db`)
set -eu

WEBROOT=/var/www/html
CONFIG="$WEBROOT/config.php"   # symlink -> /var/www/config/config.php

as_www() {
    setpriv --reuid=www-data --regid=www-data --init-groups -- "$@"
}

log() {
    echo "itflow: $*"
}

# ITFLOW_HOST (e.g. ops.example.com) pins $config_base_url, which ITFlow uses to build every
# e-mailed and guest link. Setup records whatever host it was opened on; this keeps the
# stack's value authoritative, including after a rename.
apply_host() {
    [ -n "${ITFLOW_HOST:-}" ] && [ -s "$CONFIG" ] || return 0
    case "$ITFLOW_HOST" in
        *[!A-Za-z0-9./:-]*)
            log "ignoring ITFLOW_HOST='$ITFLOW_HOST': use a hostname without scheme, e.g. ops.example.com"
            return 0
            ;;
    esac
    # Edit the real file, not the symlink, so sed -i does not replace the link with a copy
    as_www sed -i "s|^\$config_base_url = .*|\$config_base_url = '$ITFLOW_HOST';|" /var/www/config/config.php
    log "base URL: $ITFLOW_HOST"
}

# The uploads volume starts as a copy of the image's uploads/, but a volume created by an older
# image won't get new guard files. Re-seed without overwriting anything already there.
cp -a --update=none /usr/src/itflow-uploads/. "$WEBROOT/uploads/"
chown www-data:www-data "$WEBROOT/uploads" /var/www/config

log "image $(cat /usr/src/itflow-image-version)"

case "${1:-}" in
    cron)
        # Nothing to run until the setup wizard has written config.php
        until [ -s "$CONFIG" ]; do
            log "cron waiting for setup (no config.php yet)"
            sleep 30
        done
        log "cron started"
        cd "$WEBROOT/cron"
        while :; do
            # The dispatcher tracks what is due in the database, so a late or missed tick is caught up
            as_www php cron.php || log "cron.php exited with $?"
            sleep $((60 - $(date +%s) % 60))
        done
        ;;

    apache2-foreground)
        if [ -s "$CONFIG" ]; then
            apply_host
            if [ "${ITFLOW_AUTO_DB_UPDATE:-1}" = "1" ]; then
                log "applying pending database updates"
                (cd "$WEBROOT/scripts" && as_www php update_cli.php --update_db)
            fi
        else
            log "no config.php yet - open https://<host>/setup to install"
        fi
        exec docker-php-entrypoint "$@"
        ;;

    *)
        exec "$@"
        ;;
esac
