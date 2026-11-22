# GitHub's ubuntu-latest, as far as zui's CI uses it. local_ci.py passes the
# packages every `apt-get install` in the workflow and its actions names.
# gcc is there because Zig asks `cc` where the system's headers are, such
# as X11's, and the runner has one.
FROM ubuntu:26.04

ARG APT_PACKAGES
ARG ZIG_VERSION

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates curl git python3 xz-utils xauth \
        gcc \
        $APT_PACKAGES \
    && curl -fsSLo /tmp/chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends /tmp/chrome.deb \
    && rm -rf /tmp/chrome.deb /var/lib/apt/lists/*

RUN node_release=$(curl -fsSL https://nodejs.org/dist/latest-v22.x/SHASUMS256.txt | grep -o 'node-v[0-9.]*-linux-x64.tar.xz' | head -1) \
    && curl -fsSL "https://nodejs.org/dist/latest-v22.x/$node_release" | tar -xJ -C /opt \
    && ln -s /opt/${node_release%.tar.xz}/bin/node /usr/local/bin/node

RUN curl -fsSL "https://ziglang.org/download/$ZIG_VERSION/zig-x86_64-linux-$ZIG_VERSION.tar.xz" | tar -xJ -C /opt \
    && ln -s /opt/zig-x86_64-linux-$ZIG_VERSION/zig /usr/local/bin/zig
