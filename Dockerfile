FROM elixir:1.17-slim

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      gnupg \
      wireguard-tools \
    && install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && . /etc/os-release \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${VERSION_CODENAME} stable" > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
      docker-ce-cli \
      docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
ENV MIX_ENV=prod

COPY mix.exs ./
COPY lib ./lib

RUN mix escript.build \
    && install -m 0755 wg_key_rotator /usr/local/bin/wg_key_rotator

ENTRYPOINT ["/usr/local/bin/wg_key_rotator"]
CMD ["status"]
