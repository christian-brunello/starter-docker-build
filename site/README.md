# STARTER public site (packaging)

Website **sources** live in the sibling [`www/`](../../www) tree.
This directory only packages and runs the container (same idea as importing
other components into `docker-build`).

```text
www/                     # Eleventy content + UI (edit here)
docker-build/site/       # import → image → container
  apply-www.sh           # rsync www → site/import/
  deploy.sh              # apply-www + run-site
  run-site.sh
  Dockerfile
  nginx/default.conf
```

## Deploy

```bash
cd /path/to/docker-build
./site/deploy.sh
# optional: STARTER_WWW_DIR=/path/to/www STARTER_WWW_PORT=8090 ./site/deploy.sh
```

Default publish: `0.0.0.0:8090` (LAN reachable before Cloudflare).
For tunnel-only later: `STARTER_WWW_BIND=127.0.0.1 ./site/deploy.sh`.

## Cloudflare (later)

Add an ingress line, then reload cloudflared — do **not** install host nginx:

```yaml
  - hostname: starter.brncrs.net   # confirm hostname
    service: http://localhost:8090
```
