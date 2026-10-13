#!/usr/bin/env bash
# Merge Avahi host settings into /etc/avahi/avahi-daemon.conf and reload.
# Prefers STARTER_SITE_DIR/host/avahi-daemon.conf, else the public example.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SITE_DIR="${STARTER_SITE_DIR:-$(cd "${ROOT}/.." && pwd)/docker-build-sitedir}"
SITE_CONF="${SITE_DIR}/host/avahi-daemon.conf"
EXAMPLE_CONF="${ROOT}/systemd/avahi-daemon.conf.example"
DST=/etc/avahi/avahi-daemon.conf

if [[ "$(id -u)" -ne 0 ]]; then
    echo "error: run as root (sudo $0)" >&2
    exit 1
fi

if [[ ! -f "${DST}" ]]; then
    echo "error: missing ${DST}" >&2
    exit 1
fi

SRC=""
if [[ -f "${SITE_CONF}" ]]; then
    SRC="${SITE_CONF}"
elif [[ -f "${EXAMPLE_CONF}" ]]; then
    SRC="${EXAMPLE_CONF}"
else
    echo "error: no Avahi fragment (tried ${SITE_CONF}, ${EXAMPLE_CONF})" >&2
    exit 1
fi

echo "Using fragment: ${SRC}"

stamp="$(date +%Y%m%d-%H%M%S)"
cp -a "${DST}" "${DST}.bak-${stamp}"
echo "Backup: ${DST}.bak-${stamp}"

# Apply KEY=VALUE under [section] (or last section if none). Creates the
# section if missing. Replaces commented or active lines with the same key.
python3 - "${DST}" "${SRC}" <<'PY'
import re, sys
from pathlib import Path

dst_path, src_path = Path(sys.argv[1]), Path(sys.argv[2])
text = dst_path.read_text()

# Parse fragment into section -> {key: value}
frag_sections: dict[str, dict[str, str]] = {}
section = "server"
for raw in src_path.read_text().splitlines():
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    m = re.match(r"^\[(.+)\]$", line)
    if m:
        section = m.group(1).strip().lower()
        frag_sections.setdefault(section, {})
        continue
    if "=" not in line:
        continue
    key, val = line.split("=", 1)
    frag_sections.setdefault(section, {})[key.strip()] = val.strip()

# Split destination into sections preserving order / preamble
parts: list[tuple[str | None, list[str]]] = []
cur_name: str | None = None
cur_lines: list[str] = []
for line in text.splitlines(keepends=True):
    m = re.match(r"^\[(.+)\]\s*$", line.strip())
    if m:
        parts.append((cur_name, cur_lines))
        cur_name = m.group(1).strip().lower()
        cur_lines = [line]
    else:
        cur_lines.append(line)
parts.append((cur_name, cur_lines))

def upsert_section(name: str, kv: dict[str, str], lines: list[str]) -> list[str]:
    """Replace or append keys in a section body (lines include [header] if any)."""
    out: list[str] = []
    seen: set[str] = set()
    key_re = re.compile(r"^#?\s*([A-Za-z0-9-]+)\s*=")
    for line in lines:
        stripped = line.strip()
        m = key_re.match(stripped)
        if m and m.group(1) in kv:
            k = m.group(1)
            nl = "\n" if line.endswith("\n") else ""
            out.append(f"{k}={kv[k]}{nl}")
            seen.add(k)
        else:
            out.append(line)
    # Append missing keys before trailing blank lines
    missing = [k for k in kv if k not in seen]
    if missing:
        # ensure file ends with newline before appends
        if out and not out[-1].endswith("\n"):
            out[-1] = out[-1] + "\n"
        insert_at = len(out)
        while insert_at > 0 and out[insert_at - 1].strip() == "":
            insert_at -= 1
        block = "".join(f"{k}={kv[k]}\n" for k in missing)
        out.insert(insert_at, block)
    return out

# Index existing sections
by_name = {name: i for i, (name, _) in enumerate(parts) if name is not None}

for sec, kv in frag_sections.items():
    if not kv:
        continue
    if sec in by_name:
        i = by_name[sec]
        name, lines = parts[i]
        parts[i] = (name, upsert_section(sec, kv, lines))
    else:
        block = [f"[{sec}]\n"] + [f"{k}={v}\n" for k, v in kv.items()] + ["\n"]
        parts.append((sec, block))
        by_name[sec] = len(parts) - 1

new_text = "".join("".join(lines) for _, lines in parts)
if not new_text.endswith("\n"):
    new_text += "\n"
dst_path.write_text(new_text)
print(f"Updated {dst_path}")
for sec, kv in sorted(frag_sections.items()):
    for k, v in kv.items():
        print(f"  [{sec}] {k}={v}")
PY

# Sanity: avahi-daemon -f dry? not available; use daemon-reload + restart
systemctl restart avahi-daemon.service
systemctl is-active avahi-daemon.service

echo
echo "Avahi reloaded (IPv4-only + fragment applied)."
echo "If STARTER peers were on fe80::, also: systemctl restart starter-docker.service"
echo "Check: avahi-browse -art | head"
