# Config overlay (image defaults)

Files under [`etc/starter/`](etc/starter/) are baked into the image as
**defaults** at `/usr/local/share/starter/defaults/etc/starter/`.

At container start, [`seed-volumes.sh`](../scripts/seed-volumes.sh) copies
each default file into the persistent volume `/usr/local/etc/starter`
**only if that path does not already exist**. Manual edits on the volume
are never overwritten by a rebuild.

## Populate from the private sitedir (preferred)

```bash
./scripts/apply-site.sh           # ../docker-build-sitedir → overlay + rag_docs
./build.sh
./run.sh          # first run seeds missing files into volume starter-etc
```

Or sync from a live host tree:

```bash
./scripts/sync-config-overlay.sh
./scripts/sync-boot-services.sh   # enabled starter-core + st-* → boot-services.conf
./build.sh
```

## Layout

```
overlay/etc/starter/
  boot-services.conf          # name|user|command (supervisord programs)
  rules.conf
  shelly.ini
  configurable-adapter/
  configurable-service/
```

Site files are gitignored (see [`.gitignore`](../.gitignore)).
To refresh an already-seeded `boot-services.conf` on the etc volume, copy the
new overlay file into the volume (or remove the volume file) then restart;
seed never overwrites existing paths.