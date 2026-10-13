# syntax=docker/dockerfile:1
# Build with:
#   docker build -t ghcr.io/<you>/atm10:$(cat VERSION) .
FROM eclipse-temurin:21-jre

LABEL org.opencontainers.image.title="atm10-server" \
      org.opencontainers.image.description="All the Mods 10 Minecraft server"

RUN apt-get update \
 && apt-get install -y --no-install-recommends curl unzip jq \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --uid 99 --gid 100 --home-dir /data --create-home --shell /bin/bash minecraft

COPY VERSION /VERSION
COPY --chmod=755 launch.sh /launch.sh

USER minecraft
WORKDIR /data
VOLUME /data
EXPOSE 25565/tcp

CMD ["/launch.sh"]