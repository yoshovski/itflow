# ITFlow container image (yoshovski fork)

`ghcr.io/yoshovski/itflow` packages upstream ITFlow the way the
[official install script](https://docs.itflow.org/installation_script) sets it up
(Debian 13, Apache + mod_php, PHP 8.4, same extensions and php.ini overrides, `cron.php` every minute),
with code baked into the image instead of a git checkout.

## Branches and tags

| Ref | Purpose |
|---|---|
| `master` | Untouched mirror of `itflow-org/itflow` master |
| `internal` | `master` + `docker/`, `.dockerignore`, `.github/workflows/container-image.yml` |
| `v<ITFlow version>-internal-v<N>` | Release tag on `internal`, e.g. `v26.09.3-internal-v1`. Pushing it builds, smoke-tests and publishes the image with the same tag |

## Updating to a new ITFlow release

```bash
git fetch upstream
git switch master && git merge --ff-only upstream/master && git push origin master
git switch internal && git rebase master
grep APP_VERSION includes/app_version.php          # e.g. 26.10.1
git push --force-with-lease origin internal
git tag -a v26.10.1-internal-v1 -m "ITFlow 26.10.1" && git push origin v26.10.1-internal-v1
```

When the workflow is green, set `IMAGE_TAG` in the Portainer stack and redeploy. The web container applies
pending database migrations on start (`scripts/update_cli.php --update_db`), so no manual DB step is needed.
Take a DB backup first. The ITFlow in-app updater doesn't apply here, because the image has no `.git`.
Disable the `update_check` job in Maintenance > Cron.

Image-only changes (Dockerfile, entrypoint) on the same ITFlow version bump the suffix: `-internal-v2`.

## Runtime layout

| Path | What | Persist |
|---|---|---|
| `/var/www/config/config.php` | Written by the setup wizard; symlinked from `/var/www/html/config.php` | volume |
| `/var/www/html/uploads` | Files, logos, attachments, backups. `.htaccess` guards re-seeded on every start | volume |
| everything else in `/var/www/html` | Application code from this branch | image |

Container commands: default = Apache (runs DB migrations first; `ITFLOW_AUTO_DB_UPDATE=0` disables that),
`cron` = `cron.php` loop, anything else is exec'd.

## Access model (Cloudflare Access)

ITFlow has no self-registration: agents are created by an admin, and client-portal logins only exist
for contacts you enable (leave the client portal off). On top of that, Cloudflare Access decides who
can reach the host at all:

| Access application | Path | Policy |
|---|---|---|
| `ops.<domain>` | (whole host) | **Allow**: your e-mail only |
| `ops.<domain>` | `/guest` | **Bypass**: everyone |
| `ops.<domain>` | `/css`, `/js`, `/libs` | **Bypass**: everyone (static assets used by guest pages) |
| `ops.<domain>` | `/uploads/settings` | **Bypass**: everyone (company logo on guest pages) |

The most specific path wins, so guests reach only the `/guest/*` pages. Each guest link carries its own
random key. Everything else, including `/login.php`, the API and client files under `/uploads/clients`,
stays behind your login. Guest downloads of shared files go through `/guest/guest_download_file.php`.

What a guest link can show:
- **Shared item** (Share button on an asset, document, file, contact or credential): expiry date and
  view-count limit, and it can be revoked.
- **Ticket** (`/guest/guest_view_ticket.php?ticket_id=…&url_key=…`): read-only subject, details, status
  and public replies. Internal notes and ticket tasks aren't shown. It never expires. ITFlow sends it in
  the ticket e-mails to the ticket's contact. There is no copy-link button in the agent UI.

`ITFLOW_HOST` sets `$config_base_url`, so these links point at the right host.

## After first install

1. Maintenance > Cron: turn cron **on**. It ships off and nothing scheduled runs until it's enabled.
   Disable `update_check` and `app_update`, since updates come from new image tags.
2. Admin > Modules: set which modules you use.

## Local test

```bash
docker build -f docker/Dockerfile -t itflow:test .
docker/smoke-test.sh itflow:test
```

`compose.yml` in this folder is the Portainer stack.
