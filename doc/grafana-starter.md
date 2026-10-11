# Grafana and STARTER MySQL

The public tree ships a **Grafana runner only** (`grafana/run-grafana.sh`): image,
port 3000, data volume, Docker networks toward `mysql-server`. No dashboards or
datasources are baked in.

House dashboards live in the private sibling
`docker-build-sitedir/grafana/provisioning/` and are mounted automatically when
that path exists.

## Start Grafana

```bash
# data dir must exist on the host
sudo mkdir -p /mnt/grafana
./grafana/deploy.sh
# → http://127.0.0.1:3000  (default admin/admin on first boot)
```

Optional env:

| Variable | Purpose |
|----------|---------|
| `GRAFANA_DATA` | Host path for `/var/lib/grafana` (default `/mnt/grafana`) |
| `STARTER_SITE_DIR` | If `…/grafana/provisioning` exists, mount it |
| `GRAFANA_PROVISIONING` | Explicit provisioning directory |
| `GF_INSTALL_PLUGINS` | Comma-separated plugins (empty by default) |

## Connect to STARTER MySQL

1. Ensure `mysql-server` is running and Grafana is on its networks
   (`run-grafana.sh` connects `mysql-server_default` and `rack-net` when present).
2. Reader credentials are created by STARTER init and stored in the container as
   `/usr/local/etc/starter/db-credentials` (`DB_READER_USER` / `DB_READER_PASS`,
   typically `STReader`).
3. In Grafana UI: **Connections → Data sources → Add MySQL**

| Field | Value |
|-------|--------|
| Host | `mysql-server:3306` (Docker DNS) or `host.docker.internal:3306` |
| Database | `STARTER` |
| User | `STReader` (or value from `db-credentials`) |
| Password | from `db-credentials` |

Read password from the running starter container:

```bash
docker exec starter sed -n 's/^DB_READER_PASS=//p' /usr/local/etc/starter/db-credentials
```

## Example queries

Schema sketch (see `sql/skeleton.sql`):

- `labels` — I/O metadata (`name`, `type`, `unit`, …)
- `history` — time series (`timestamp`, `label_id`, `value`, `source`)
- `stats` — per-service process stats

**List labels**

```sql
SELECT id, name, type, unit, min, max
FROM labels
ORDER BY name
LIMIT 50;
```

**Latest value per label (Grafana: Format = Table)**

```sql
SELECT l.name, h.value, h.timestamp, h.source
FROM history h
JOIN labels l ON l.id = h.label_id
INNER JOIN (
  SELECT label_id, MAX(timestamp) AS ts
  FROM history
  GROUP BY label_id
) last ON last.label_id = h.label_id AND last.ts = h.timestamp
ORDER BY l.name;
```

**Time series for one label (Grafana: Format = Time series)**

```sql
SELECT
  h.timestamp AS time,
  h.value AS value
FROM history h
JOIN labels l ON l.id = h.label_id
WHERE l.name = 'KitThermostat:temperature'
  AND h.timestamp BETWEEN $__timeFrom() AND $__timeTo()
ORDER BY h.timestamp;
```

Replace the label name with one from your `labels` table. With Grafana MySQL
macro support, `$__timeFrom()` / `$__timeTo()` track the dashboard range.

**Recent history (debug)**

```sql
SELECT h.timestamp, l.name, h.value, h.source
FROM history h
JOIN labels l ON l.id = h.label_id
ORDER BY h.timestamp DESC
LIMIT 100;
```

## Optional: parameters HTTP API

STARTER’s parameters adapter (if enabled) often listens on port `18765`. From a
Grafana container on bridge networking, use `http://host.docker.internal:18765/params`
(Infinity or other HTTP plugin). That API is independent of the MySQL datasource.

## Site provisioning

If you maintain dashboards privately:

```text
docker-build-sitedir/grafana/provisioning/
  datasources/
  dashboards/
```

Then `./grafana/deploy.sh` mounts them. Keep that tree out of the public repo.
