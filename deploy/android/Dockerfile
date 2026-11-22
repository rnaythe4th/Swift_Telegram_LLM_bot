# syntax=docker/dockerfile:1

FROM swift:6.2.4-bookworm AS build
WORKDIR /app
COPY Package.swift Package.resolved ./
RUN swift package resolve --force-resolved-versions
COPY Sources ./Sources
COPY Tests ./Tests
RUN swift build --force-resolved-versions --configuration release --product LLM_chat_bot --jobs 4 \
    && strip --strip-all .build/release/LLM_chat_bot

# Swift's static SDK allocator uses ARMv8.1 instructions on aarch64. The Mi 5s
# needs an ARMv8.0 build, so bundle the Debian loader and the actual runtime
# dependencies in the release, where they do not affect Alpine packages.
FROM swift:6.2.4-bookworm-slim AS bundle
COPY --from=build /app/.build/release/LLM_chat_bot /release/bin/LLM_chat_bot
RUN set -eu; \
    mkdir /release/lib; \
    ldd /release/bin/LLM_chat_bot > /tmp/linked-libs; \
    if grep -q 'not found' /tmp/linked-libs; then cat /tmp/linked-libs >&2; exit 1; fi; \
    awk '$2 == "=>" && $3 ~ /^\// {print $3} $1 ~ /^\// {print $1}' /tmp/linked-libs > /tmp/lib-paths; \
    while IFS= read -r library; do cp -L "$library" /release/lib/; done < /tmp/lib-paths; \
    /release/lib/ld-linux-aarch64.so.1 --inhibit-cache --library-path /release/lib \
        --list /release/bin/LLM_chat_bot

FROM scratch AS artifact
COPY --from=bundle /release/ /
