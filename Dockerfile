# syntax=docker/dockerfile:1

FROM swift:6.2-jammy AS build
WORKDIR /app

COPY Package.swift ./
RUN swift package resolve

COPY Sources ./Sources
RUN swift build -c release --product LLM_chat_bot

FROM swift:6.2-jammy AS runtime

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates tzdata libatomic1 libcurl4 libxml2 zlib1g libbsd0 libsqlite3-0 libz3-4 && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /run

COPY --from=build /app/.build/release/LLM_chat_bot /usr/local/bin/app

CMD ["/usr/local/bin/app"]
