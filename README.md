# STARTER Docker image

Docker build and runtime for the STARTER stack (Ubuntu 22.04, pinned GitHub
commits, MySQL, persistent volumes).

**Documentation:** [doc/starter-docker.md](doc/starter-docker.md)

```bash
./scripts/sync-config-overlay.sh   # optional: configs from /usr/local/etc/starter
./build.sh
STARTER_MYSQL_PORT=3307 ./run.sh   # if host already uses port 3306
```
