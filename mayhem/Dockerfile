FROM ghcr.io/savantenvs/base:20260621
ARG COMMIT
ARG REPO_URL
ARG SOURCE_DATE_EPOCH
ARG SANITIZER_FLAGS
ARG COVERAGE_FLAGS=
ARG MAYHEM_JOBS=

# OpenSlide build deps (meson + C library stack) and its developer test-suite
# deps (cjpeg/djpeg/xdelta3 programs; python3-venv so the meson test build can
# create test/env and pip-install driver.py's requirements — yaml/requests/boto3).
# libdicom has no Debian package — it comes from the meson wrap subproject,
# cached by mayhem/build.sh.
USER root
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        meson \
        libglib2.0-dev \
        libcairo2-dev \
        libtiff-dev \
        libjpeg62-turbo-dev \
        libpng-dev \
        libopenjp2-7-dev \
        libxml2-dev \
        libsqlite3-dev \
        zlib1g-dev \
        libzstd-dev \
        libjpeg-turbo-progs \
        xdelta3 \
        python3-venv \
        python3-pip \
    && rm -rf /var/lib/apt/lists/*

USER mayhem
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem
RUN bash mayhem/build.sh
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh — repo ships no functional tests"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
