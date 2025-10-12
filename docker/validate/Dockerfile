# syntax=docker/dockerfile:1.4

FROM mcr.microsoft.com/powershell:7.4-debian-12

ARG ACTIONLINT_VERSION=1.7.7

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        curl \
        git \
        python3 \
        python3-pip \
        npm \
        build-essential \
    && curl -sSL "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_linux_amd64.tar.gz" \
        | tar -xz -C /usr/local/bin actionlint \
    && npm install -g markdownlint-cli \
    && python3 -m pip install --no-cache-dir --break-system-packages ruamel.yaml \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

ENTRYPOINT ["pwsh","-NoLogo","-NoProfile"]
