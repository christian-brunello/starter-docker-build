# STARTER multi-component image: clone pinned GitHub commits and build with
# each project's existing autotools stack. Ubuntu 22.04 LTS.
# Runtime includes MySQL with STARTER skeleton, system user "starter",
# and org.starter.core gsettings wired to generated DB credentials.
#
# Build: ./build.sh

ARG UBUNTU_VERSION=22.04

# ---------------------------------------------------------------------------
# builder
# ---------------------------------------------------------------------------
FROM ubuntu:${UBUNTU_VERSION} AS builder

ENV DEBIAN_FRONTEND=noninteractive \
    PKG_CONFIG_PATH=/usr/local/lib/pkgconfig \
    LD_LIBRARY_PATH=/usr/local/lib \
    PREFIX=/usr/local

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        autoconf \
        automake \
        libtool \
        pkg-config \
        bison \
        flex \
        git \
        ca-certificates \
        texinfo \
        libglib2.0-dev \
        libavahi-client-dev \
        libavahi-glib-dev \
        default-libmysqlclient-dev \
        libreadline-dev \
        libxml2-dev \
        libjson-glib-dev \
        libsoup-3.0-dev \
        libsqlite3-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

# Build-args (defaults match versions.env; override via build.sh)
ARG STARTER_CORE_REPO=https://github.com/christian-brunello/starter-core.git
ARG STARTER_CORE_COMMIT
ARG STARTER_DEBUGGER_REPO=https://github.com/christian-brunello/starter-debugger.git
ARG STARTER_DEBUGGER_COMMIT
ARG STARTER_CONFIGURABLE_SERVICE_REPO=https://github.com/christian-brunello/starter-configurable-service.git
ARG STARTER_CONFIGURABLE_SERVICE_COMMIT
ARG STARTER_CONFIGURABLE_ADAPTER_REPO=https://github.com/christian-brunello/starter-configurable-adapter.git
ARG STARTER_CONFIGURABLE_ADAPTER_COMMIT
ARG STARTER_ARISTON_PLUGIN_REPO=https://github.com/christian-brunello/starter-configurable-adapter-ariston-plugin.git
ARG STARTER_ARISTON_PLUGIN_COMMIT
ARG STARTER_PARAMETERS_PLUGIN_REPO=https://github.com/christian-brunello/starter-configurable-adapter-parameters-plugin.git
ARG STARTER_PARAMETERS_PLUGIN_COMMIT

# --- starter-core (with remote debug server for starter-debugger) ---
RUN git clone --filter=blob:none "${STARTER_CORE_REPO}" starter-core \
    && cd starter-core \
    && git checkout "${STARTER_CORE_COMMIT}" \
    && ./autogen.sh \
    && ./configure --prefix="${PREFIX}" --enable-debug-server \
    && make -j"$(nproc)" \
    && make install \
    && install -d "${PREFIX}/share/glib-2.0/schemas" \
    && install -m 644 src/schemas/org.starter.gschema.xml \
        "${PREFIX}/share/glib-2.0/schemas/" \
    && glib-compile-schemas "${PREFIX}/share/glib-2.0/schemas" \
    && ldconfig

# --- starter-debugger ---
RUN git clone --filter=blob:none "${STARTER_DEBUGGER_REPO}" starter-debugger \
    && cd starter-debugger \
    && git checkout "${STARTER_DEBUGGER_COMMIT}" \
    && ./autogen.sh \
    && ./configure --prefix="${PREFIX}" \
    && make -j"$(nproc)" \
    && make install \
    && ldconfig

# --- starter-configurable-service (depends on installed starter-core.pc) ---
RUN git clone --filter=blob:none "${STARTER_CONFIGURABLE_SERVICE_REPO}" starter-configurable-service \
    && cd starter-configurable-service \
    && git checkout "${STARTER_CONFIGURABLE_SERVICE_COMMIT}" \
    && ./autogen.sh \
    && ./configure --prefix="${PREFIX}" \
    && make -j"$(nproc)" \
    && make install \
    && ldconfig

# --- starter-configurable-adapter ---
RUN git clone --filter=blob:none "${STARTER_CONFIGURABLE_ADAPTER_REPO}" starter-configurable-adapter \
    && cd starter-configurable-adapter \
    && git checkout "${STARTER_CONFIGURABLE_ADAPTER_COMMIT}" \
    && ./autogen.sh \
    && ./configure --prefix="${PREFIX}" \
    && make -j"$(nproc)" \
    && make install \
    && ldconfig

# --- out-of-tree STCA plugins ---
RUN git clone --filter=blob:none "${STARTER_ARISTON_PLUGIN_REPO}" stca-plugin-ariston \
    && cd stca-plugin-ariston \
    && git checkout "${STARTER_ARISTON_PLUGIN_COMMIT}" \
    && ./autogen.sh \
    && ./configure --prefix="${PREFIX}" \
    && make -j"$(nproc)" \
    && make install \
    && ldconfig

RUN git clone --filter=blob:none "${STARTER_PARAMETERS_PLUGIN_REPO}" stca-plugin-parameters \
    && cd stca-plugin-parameters \
    && git checkout "${STARTER_PARAMETERS_PLUGIN_COMMIT}" \
    && ./autogen.sh \
    && ./configure --prefix="${PREFIX}" \
    && make -j"$(nproc)" \
    && make install \
    && ldconfig

# ---------------------------------------------------------------------------
# runtime
# ---------------------------------------------------------------------------
FROM ubuntu:${UBUNTU_VERSION} AS runtime

ENV DEBIAN_FRONTEND=noninteractive \
    PKG_CONFIG_PATH=/usr/local/lib/pkgconfig \
    LD_LIBRARY_PATH=/usr/local/lib \
    PATH=/usr/local/bin:/usr/local/sbin:$PATH \
    XDG_DATA_DIRS=/usr/local/share:/usr/share

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        openssl \
        m4 \
        dbus \
        dbus-x11 \
        libglib2.0-bin \
        dconf-cli \
        libglib2.0-0 \
        libavahi-client3 \
        libavahi-common3 \
        libavahi-glib1 \
        libmysqlclient21 \
        libreadline8 \
        libxml2 \
        libjson-glib-1.0-0 \
        libsoup-3.0-0 \
        libsqlite3-0 \
        mysql-server \
        mysql-client \
    && rm -rf /var/lib/apt/lists/* \
    && rm -f /var/lib/mysql/auto.cnf \
    && mkdir -p /var/run/mysqld \
    && chown mysql:mysql /var/run/mysqld

# System user matching the production unit (User=starter in starter-core.service)
RUN groupadd --system --gid 999 starter \
    && useradd --system --uid 999 --gid starter \
        --home-dir /home/starter --create-home \
        --shell /usr/sbin/nologin starter \
    && install -d -o starter -g starter -m 755 /home/starter

COPY --from=builder /usr/local /usr/local

COPY sql/skeleton.sql /usr/local/share/starter/sql/skeleton.sql
COPY scripts/entrypoint.sh /usr/local/libexec/starter/entrypoint.sh
COPY scripts/init-starter-db.sh /usr/local/libexec/starter/init-starter-db.sh
COPY scripts/seed-volumes.sh /usr/local/libexec/starter/seed-volumes.sh
COPY mysql/starter.cnf /etc/mysql/mysql.conf.d/starter.cnf
# Overlay → image defaults only (seeded into the etc *volume* on first run)
COPY overlay/ /tmp/starter-overlay/

RUN echo /usr/local/lib > /etc/ld.so.conf.d/usr-local.conf \
    && ldconfig \
    && chmod 755 /usr/local/libexec/starter/entrypoint.sh \
                 /usr/local/libexec/starter/init-starter-db.sh \
                 /usr/local/libexec/starter/seed-volumes.sh \
    && install -d -m 755 /usr/local/etc/starter \
    && install -d -m 755 /usr/local/share/starter/defaults/etc/starter \
    && if [ -f /usr/local/etc/starter/rules.conf.example ]; then \
         install -m 644 /usr/local/etc/starter/rules.conf.example \
             /usr/local/share/starter/defaults/etc/starter/rules.conf.example; \
       fi \
    && if [ -d /tmp/starter-overlay/etc/starter ]; then \
         find /tmp/starter-overlay/etc/starter -type f \
              ! -name '.gitkeep' ! -name 'README.md' -print \
         | while read -r f; do \
             rel="${f#/tmp/starter-overlay/etc/starter/}"; \
             dest="/usr/local/share/starter/defaults/etc/starter/${rel}"; \
             install -d "$(dirname "${dest}")"; \
             install -m 644 "${f}" "${dest}"; \
           done; \
       fi \
    && rm -rf /tmp/starter-overlay \
    && install -d /usr/share/glib-2.0/schemas \
    && if [ -f /usr/local/share/glib-2.0/schemas/org.starter.gschema.xml ]; then \
         install -m 644 /usr/local/share/glib-2.0/schemas/org.starter.gschema.xml \
             /usr/share/glib-2.0/schemas/; \
       fi \
    && glib-compile-schemas /usr/local/share/glib-2.0/schemas \
    && glib-compile-schemas /usr/share/glib-2.0/schemas \
    && chown -R starter:starter /usr/local/etc/starter

# Optional password overrides at first container start (otherwise random).
# STARTER_DB_WRITER_PASS / STARTER_DB_READER_PASS
# STARTER_MYSQL_PORT — mysqld listen port (default 3306; use another if host mysqld conflicts)
ENV STARTER_DB_HOST=127.0.0.1 \
    STARTER_DB_PORT=3306 \
    STARTER_DB_WRITER_USER=STWriter \
    STARTER_DB_READER_USER=STReader \
    STARTER_MYSQL_PORT=3306

EXPOSE 3306

ENTRYPOINT ["/usr/local/libexec/starter/entrypoint.sh"]
WORKDIR /home/starter
CMD ["/bin/bash"]
