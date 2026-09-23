#!/usr/bin/env bash
# Smoke test for the ITFlow image: fresh install via setup_cli, web checks, .htaccess guards,
# restart with DB migrations, and one cron.php run.   Usage: docker/smoke-test.sh <image>
set -euo pipefail

IMAGE="${1:?usage: $0 <image>}"
P="itflow-smoke-$$"
DB_PASS="smoke-$(openssl rand -hex 8)"

cleanup() {
    docker rm -f -v "$P-web" "$P-cron" "$P-db" >/dev/null 2>&1 || true
    docker volume rm "$P-config" "$P-uploads" >/dev/null 2>&1 || true
    docker network rm "$P" >/dev/null 2>&1 || true
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; docker logs "$P-web" 2>&1 | tail -40 >&2 || true; exit 1; }
ok() { echo "ok: $*"; }

wait_healthy() {
    for _ in $(seq 1 60); do
        [ "$(docker inspect -f '{{.State.Health.Status}}' "$1" 2>/dev/null)" = healthy ] && return 0
        sleep 2
    done
    fail "$1 never became healthy"
}

# Cloudflare Tunnel always sends X-Forwarded-Proto: https; ITFlow is HTTPS-only by default
http_code() {
    docker exec "$P-web" curl -s -o /dev/null -w '%{http_code}' -H 'X-Forwarded-Proto: https' "http://127.0.0.1$1"
}

start_web() {
    docker run -d --name "$P-web" --network "$P" -e ITFLOW_HOST="${ITFLOW_HOST:-}" \
        -v "$P-config:/var/www/config" -v "$P-uploads:/var/www/html/uploads" \
        --health-cmd 'curl -fsS -o /dev/null http://127.0.0.1/login.php' --health-interval 2s \
        "$IMAGE" >/dev/null
    wait_healthy "$P-web"
}

docker network create "$P" >/dev/null
docker run -d --name "$P-db" --network "$P" --network-alias itflow-db \
    -e MARIADB_RANDOM_ROOT_PASSWORD=true -e MARIADB_DATABASE=itflow \
    -e MARIADB_USER=itflow -e MARIADB_PASSWORD="$DB_PASS" \
    --health-cmd 'healthcheck.sh --connect --innodb_initialized' --health-interval 2s \
    mariadb:11.8 >/dev/null
wait_healthy "$P-db"
ok "mariadb healthy"

start_web
ok "web healthy before setup"

# Started before setup, like a fresh Portainer deploy: it must wait rather than run jobs
docker run -d --name "$P-cron" --network "$P" \
    -v "$P-config:/var/www/config" -v "$P-uploads:/var/www/html/uploads" \
    "$IMAGE" cron >/dev/null

docker exec -u www-data -w /var/www/html/scripts "$P-web" php setup_cli.php \
    --host=itflow-db --username=itflow --password="$DB_PASS" --database=itflow \
    --base-url=localhost --locale=en_US --timezone=Europe/Madrid --currency=EUR \
    --company-name="Smoke Test" --country="Spain" --user-name="Smoke Test" \
    --user-email="smoke@example.com" --user-password="Sm0ke-$(openssl rand -hex 6)" \
    --non-interactive || fail "setup_cli.php"
docker exec "$P-web" test -s /var/www/config/config.php || fail "config.php not written to the config volume"
ok "setup_cli installed; config.php is on the volume"

c=$(http_code /login.php); [ "$c" = 200 ] || { docker exec "$P-web" curl -s -i -H "X-Forwarded-Proto: https" http://127.0.0.1/login.php | head -20; fail "login.php returned $c"; }
docker exec "$P-web" curl -s -H 'X-Forwarded-Proto: https' http://127.0.0.1/login.php | grep -qi 'password' || fail "login form missing"
ok "login page served"

[ "$(http_code /config.php)" = 401 ] || fail "config.php reachable ($(http_code /config.php))"
[ "$(http_code /cron/cron.php)" = 403 ] || fail "cron/ reachable ($(http_code /cron/cron.php))"
[ "$(http_code /scripts/update_cli.php)" = 403 ] || fail "scripts/ reachable"
docker exec "$P-web" sh -c 'echo "<?php echo 1;" > /var/www/html/uploads/clients/x.php'
[ "$(http_code /uploads/clients/x.php)" = 403 ] || fail "PHP executes inside uploads/"
ok ".htaccess guards active"

docker exec "$P-web" curl -sI http://127.0.0.1/login.php | tr -d '\r' | grep -qi '^Server: Apache$' || fail "Apache version leaks in Server header"
ok "Server header minimal"

docker rm -f "$P-web" >/dev/null
ITFLOW_HOST=ops.example.com start_web
docker logs "$P-web" 2>&1 | grep -q "applying pending database updates" || fail "update_db did not run on restart"
docker exec "$P-web" grep -q "^\$config_base_url = 'ops.example.com';" /var/www/config/config.php || fail "ITFLOW_HOST not applied"
docker exec "$P-web" test -L /var/www/html/config.php || fail "config.php symlink replaced"
[ "$(http_code /login.php)" = 200 ] || fail "login.php not 200 after restart"
ok "restart keeps install (config + migrations)"

docker exec -u www-data -w /var/www/html/cron "$P-web" php cron.php || fail "cron.php"
ok "cron.php ran"

for _ in $(seq 1 15); do
    docker logs "$P-cron" 2>&1 | grep -q "cron started" && break
    sleep 2
done
[ "$(docker inspect -f '{{.State.Running}}' "$P-cron")" = true ] || fail "cron container exited"
docker logs "$P-cron" 2>&1 | grep -q "cron started" || fail "cron container did not start after setup"
sleep 3
! docker logs "$P-cron" 2>&1 | grep -q "cron.php exited" || fail "cron.php failed in cron container"
ok "cron container waited for setup, then ran cleanly"

echo "SMOKE TEST PASSED"
