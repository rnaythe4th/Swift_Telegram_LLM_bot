# syntax=docker/dockerfile:1

FROM swift:6.2-bookworm AS build
WORKDIR /app

# Package.resolved is copied too, so the image builds the exact dependency
# versions that were tested locally. Without it every remote build re-resolves
# and can silently pick up a newer minor release of a transitive package.
COPY Package.swift Package.resolved ./
RUN swift package resolve

# Tests are copied because SwiftPM validates every target in the manifest: with
# Tests/ missing the test target claims Sources/ and the build fails outright.
COPY Sources ./Sources
COPY Tests ./Tests
# The tests are copied anyway (SwiftPM validates every target in the manifest),
# so running them costs one build stage and turns a broken deploy into a broken
# build. The database tests skip themselves without TEST_DATABASE_URL.
RUN swift test
RUN swift build -c release --product LLM_chat_bot
RUN strip .build/release/LLM_chat_bot || true

FROM swift:6.2-bookworm-slim AS browser-runtime
WORKDIR /run
ARG TARGETARCH
RUN apt-get update \
    && apt-get install --no-install-recommends -y ca-certificates curl firefox-esr fonts-liberation \
        python3 python3-venv tini util-linux x11-utils x11vnc xauth xvfb \
    && rm -rf /var/lib/apt/lists/*

# Keep the driver on the same version on Railway's amd64 and local arm64.
RUN case "$TARGETARCH" in \
        amd64) asset=linux64; checksum=0bde38707eb0a686a20c6bd50f4adcc7d60d4f73c60eb83ee9e0db8f65823e04 ;; \
        arm64) asset=linux-aarch64; checksum=b5fd13fc8f05ca99292700896d43fa986747a01b5fdc77f7bfc88a3707dc4241 ;; \
        *) exit 1 ;; \
    esac \
    && curl -fsSL --retry 3 -o /tmp/geckodriver.tar.gz \
        "https://github.com/mozilla/geckodriver/releases/download/v0.36.0/geckodriver-v0.36.0-${asset}.tar.gz" \
    && echo "$checksum  /tmp/geckodriver.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/geckodriver.tar.gz -C /usr/local/bin geckodriver \
    && rm /tmp/geckodriver.tar.gz \
    && groupadd -g 65532 bot \
    && useradd -l -K UID_MAX=65532 -u 65532 -g bot -d /run/bot -M -s /bin/bash bot \
    && install -d -m 0700 -o 65532 -g 65532 /run/bot /run/deepseek-web \
    && install -d -m 1777 -o root -g root /tmp/.X11-unix \
    && python3 -m venv /opt/deepseek-venv

ENV HOME=/run/bot \
    PYTHONUNBUFFERED=1 \
    PATH=/opt/deepseek-venv/bin:$PATH

COPY --chmod=755 deploy/deepseek-web/entrypoint.sh /usr/local/bin/start-bot
COPY --chmod=755 deploy/deepseek-web/maintenance.sh /usr/local/bin/deepseek-web-maintenance
COPY deploy/deepseek-web/*.py /opt/deepseek-web/

FROM browser-runtime AS runtime
COPY deepseek-web/requirements.txt /opt/deepseek-web/requirements.txt
RUN pip install --no-cache-dir -r /opt/deepseek-web/requirements.txt
COPY deepseek-web/*.py /opt/deepseek-web/
COPY --from=build /app/.build/release/LLM_chat_bot /usr/local/bin/app

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/start-bot"]
