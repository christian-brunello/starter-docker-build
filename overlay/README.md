# Config overlay (image defaults)

Files under [`etc/starter/`](etc/starter/) are baked into the image as
**defaults** at `/usr/local/share/starter/defaults/etc/starter/`.

At container start, [`seed-volumes.sh`](../scripts/seed-volumes.sh) copies
each default file into the persistent volume `/usr/local/etc/starter`
**only if that path does not already exist**. Manual edits on the volume
are never overwritten by a rebuild.

## Populate from the host

```bash
./scripts/sync-config-overlay.sh
./build.sh
./run.sh          # first run seeds missing files into volume starter-etc
```

## Layout

```
overlay/etc/starter/
  rules.conf
  shelly.ini
  configurable-adapter/
  configurable-service/
```

Site files are gitignored (see [`.gitignore`](../.gitignore)).
