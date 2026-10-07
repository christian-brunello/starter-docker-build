#!/usr/bin/env bash
# Seed mutable paths from image defaults without overwriting existing volume data.
set -euo pipefail

DEFAULTS_ETC=/usr/local/share/starter/defaults/etc/starter
LIVE_ETC=/usr/local/etc/starter

seed_etc() {
    install -d -m 755 "${LIVE_ETC}"

    if [[ -d "${DEFAULTS_ETC}" ]]; then
        # Copy only files that are not already present (preserve manual edits).
        find "${DEFAULTS_ETC}" -type f ! -name '.gitkeep' ! -name 'README.md' -print \
        | while read -r f; do
            rel="${f#${DEFAULTS_ETC}/}"
            dest="${LIVE_ETC}/${rel}"
            if [[ ! -e "${dest}" ]]; then
                install -d "$(dirname "${dest}")"
                install -m 644 "${f}" "${dest}"
                echo "seeded config: ${rel}"
            fi
        done
    fi

    # Package example → live rules.conf only if neither was provided by overlay/volume
    if [[ ! -e "${LIVE_ETC}/rules.conf" ]]; then
        if [[ -f "${LIVE_ETC}/rules.conf.example" ]]; then
            install -m 644 "${LIVE_ETC}/rules.conf.example" "${LIVE_ETC}/rules.conf"
            echo "seeded config: rules.conf (from rules.conf.example)"
        elif [[ -f "${DEFAULTS_ETC}/rules.conf.example" ]]; then
            install -m 644 "${DEFAULTS_ETC}/rules.conf.example" "${LIVE_ETC}/rules.conf"
            echo "seeded config: rules.conf (from defaults example)"
        fi
    fi

    chown -R starter:starter "${LIVE_ETC}" || true
}

seed_home() {
    install -d -o starter -g starter -m 755 /home/starter
    install -d -o starter -g starter -m 700 /home/starter/.config /home/starter/.cache \
        /home/starter/.config/dconf /home/starter/.cache/dconf || true
}

seed_etc
seed_home
