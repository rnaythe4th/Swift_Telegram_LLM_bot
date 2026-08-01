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

FROM swift:6.2-bookworm-slim AS runtime
WORKDIR /run

COPY --from=build /app/.build/release/LLM_chat_bot /usr/local/bin/app

# Nothing here needs root, and a container that runs as root turns any code
# execution bug into a container takeover. Free.
USER 65532:65532

CMD ["/usr/local/bin/app"]
