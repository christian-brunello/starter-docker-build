# Grafana runner

Starts a Grafana OSS container with host-gateway and optional attachment to
`mysql-server` Docker networks. **No provisioning or dashboards** are included
in this public tree.

See [doc/grafana-starter.md](../doc/grafana-starter.md) for connecting to the
STARTER MySQL database and example SQL.

Site dashboards/datasources: `../docker-build-sitedir/grafana/provisioning/`
(mounted automatically by `run-grafana.sh` when present).

```bash
sudo mkdir -p /mnt/grafana
./deploy.sh
```
