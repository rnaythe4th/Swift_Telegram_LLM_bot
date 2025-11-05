# syntax=docker/dockerfile:1

FROM swift:6.2-bookworm AS build
WORKDIR /app

COPY Package.swift ./
RUN swift package resolve

COPY Sources ./Sources
RUN swift build -c release --product LLM_chat_bot
RUN strip .build/release/LLM_chat_bot || true

FROM swift:6.2-bookworm-slim AS runtime
WORKDIR /run

COPY --from=build /app/.build/release/LLM_chat_bot /usr/local/bin/app

CMD ["/usr/local/bin/app"]
