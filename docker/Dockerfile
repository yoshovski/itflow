# syntax=docker/dockerfile:1.7
#
# ITFlow container image, built to mirror the officially supported install
# (https://docs.itflow.org/installation_script): Debian 13, Apache + mod_php,
# PHP 8.4 with the same extensions and php.ini overrides, cron.php every minute.
#
# Differences from the script install, all deliberate:
#   - Code is baked into the image. Updates ship as new image tags, not via git pull.
#   - config.php lives on a volume (/var/www/config) and is symlinked into the webroot.
#   - uploads/ lives on a volume. Its .htaccess guards are re-seeded on every start.
#   - Pending database migrations run on start (scripts/update_cli.php --update_db).
#   - Cron runs as a second container from the same image: `command: ["cron"]`.
#
# Build from the repository root:  docker build -f docker/Dockerfile .

FROM php:8.4-apache-trixie

ARG ITFLOW_VERSION=dev
ARG VCS_REF=unknown

LABEL org.opencontainers.image.title="ITFlow" \
      org.opencontainers.image.description="ITFlow (IT documentation, ticketing, assets) - Debian/Apache image" \
      org.opencontainers.image.source="https://github.com/yoshovski/itflow" \
      org.opencontainers.image.licenses="GPL-3.0-only" \
      org.opencontainers.image.version="${ITFLOW_VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}"

# Same extension set as the install script (php-intl php-mysqli php-gd php-curl php-mbstring
# php-zip php-xml). curl, mbstring, xml, dom, posix and fileinfo are already compiled into the base.
# whois + dnsutils are used by the domain refresher, as in the script install.
COPY --from=mlocati/php-extension-installer:2 /usr/bin/install-php-extensions /usr/local/bin/
RUN install-php-extensions intl mysqli gd zip \
 && apt-get update \
 && apt-get install -y --no-install-recommends whois dnsutils \
 && rm -rf /var/lib/apt/lists/*

RUN cp "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"
COPY docker/php.ini "$PHP_INI_DIR/conf.d/zz-itflow.ini"

# zz- so it loads after the base image's security.conf (ServerTokens)
COPY docker/apache-itflow.conf /etc/apache2/conf-available/zz-itflow.conf
RUN a2enmod rewrite remoteip headers \
 && a2enconf zz-itflow

COPY --chown=www-data:www-data . /var/www/html/
COPY docker/entrypoint.sh /usr/local/bin/itflow-entrypoint

RUN set -eux; \
    cd /var/www/html; \
    rm -rf docker .dockerignore; \
    # Pristine copy of uploads/ (its .htaccess files block PHP execution) for re-seeding the volume
    cp -a uploads /usr/src/itflow-uploads; \
    # config.php is written by the setup wizard through this symlink onto the config volume
    mkdir -p /var/www/config; \
    chown www-data:www-data /var/www/config; \
    ln -s /var/www/config/config.php /var/www/html/config.php; \
    chown -h www-data:www-data /var/www/html/config.php; \
    chmod +x /usr/local/bin/itflow-entrypoint; \
    echo "${ITFLOW_VERSION}" > /usr/src/itflow-image-version

ENTRYPOINT ["itflow-entrypoint"]
CMD ["apache2-foreground"]
