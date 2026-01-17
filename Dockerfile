# --- Build Stage ---
FROM --platform=$BUILDPLATFORM debian:bookworm-slim AS zig

# Build arguments for multi-platform support
ARG TARGETPLATFORM
ARG BUILDPLATFORM
WORKDIR /app

# Install build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
	curl \
	xz-utils \
	make \
	build-essential \
	ca-certificates \
	libcurl4 \
	libcurl4-openssl-dev \
	&& rm -rf /var/lib/apt/lists/*

# Install Zig 0.15.2 autonomously based on BUILDPLATFORM
RUN case "${BUILDPLATFORM}" in \
	"linux/amd64")   ZIG_ARCH="x86_64" ;; \
	"linux/arm64")   ZIG_ARCH="aarch64" ;; \
	*)               ZIG_ARCH="x86_64" ;; \
	esac && \
	echo "Downloading Zig 0.15.2 for ${ZIG_ARCH}..." && \
	curl -fL https://ziglang.org/download/0.15.2/zig-${ZIG_ARCH}-linux-0.15.2.tar.xz -o zig.tar.xz && \
	tar -xJf zig.tar.xz --strip-components=1 -C /usr/local/bin && \
	rm zig.tar.xz

FROM --platform=$BUILDPLATFORM zig AS builder

# Build arguments for multi-platform support
ARG TARGETPLATFORM
ARG BUILDPLATFORM
WORKDIR /app

# Copy project files
COPY . .

RUN zig build --release=safe -Doptimize=ReleaseSafe

# --- Runtime Stage ---
FROM debian:bookworm-slim

# Build arguments to know which binary to copy
ARG TARGETPLATFORM

# Install runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
	libcurl4 \
	ca-certificates \
	&& rm -rf /var/lib/apt/lists/*

# Create necessary directories
RUN mkdir -p /app/storage
WORKDIR /app

# Copy the build artifacts and target info
COPY --from=builder /app/zig-out/bin/pantavisor-mocker /usr/local/bin/pantavisor-mocker

# VOLUME for storage
VOLUME /app/storage

# Set entrypoint
ENTRYPOINT ["pantavisor-mocker"]
