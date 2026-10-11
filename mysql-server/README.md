# Shared MySQL server

Single `mysql:8.0` container for:

- `compute_rack` (rack agents / `rack-user`)
- `STARTER` (schema and users created by the starter container init)

## Files

| File | Role |
|------|------|
| `docker-compose.yml` | bind `MYSQL_DATA_DIR`, require `MYSQL_ROOT_PASSWORD` |
| `init.sql` | first-init databases + `node_hardware` |
| `02-rack-user.sh` | optional `rack-user` when `MYSQL_RACK_PASSWORD` is set |
| `deploy.sh` | create network, start compose, wait for ping |
| `install-systemd.sh` | enable `mysql-server.service` |
| `migrate-from-starter.sh` | one-shot migrate from legacy in-image mysqld |

## Required env

| Variable | Purpose |
|----------|---------|
| `MYSQL_ROOT_PASSWORD` | root password (required) |
| `MYSQL_DATA_DIR` | host datadir bind (required) |
| `MYSQL_RACK_PASSWORD` | optional; creates `rack-user` on first init |
| `STARTER_DATA_ROOT` | optional; if set, default data dir is `$STARTER_DATA_ROOT/mysql-server-data` |

Copy `systemd/mysql-server.default.example` or
`docker-build-sitedir/host/mysql-server.default` to `/etc/default/mysql-server`.

## Quick start

```bash
export MYSQL_ROOT_PASSWORD='…'
export MYSQL_DATA_DIR=/mnt/data/mysql-server-data
./deploy.sh
sudo ./install-systemd.sh
```
