# --- Build Stage ---
FROM --platform=$BUILDPLATFORM debian:bookworm-slim AS zig

# Build arguments for multi-platform support
ARG TARGETPLATFORM
ARG BUILDPLATFORM
WORKDIR /app

# Install build dependencies, plus the TARGET arch's libcurl (Debian
# multiarch) so zig can cross-link libcurl for the target platform.
RUN set -eux; \
	case "${TARGETPLATFORM}" in \
		linux/arm64)  CROSS=":arm64" ;; \
		linux/arm/v7) CROSS=":armhf" ;; \
		*)            CROSS="" ;; \
	esac; \
	if [ -n "$CROSS" ]; then dpkg --add-architecture "${CROSS#:}"; fi; \
	apt-get update; \
	apt-get install -y --no-install-recommends \
		curl \
		xz-utils \
		make \
		build-essential \
		ca-certificates \
		"libcurl4-openssl-dev$CROSS"; \
	rm -rf /var/lib/apt/lists/*

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

# Cross-compile for TARGETPLATFORM; zig itself runs natively on BUILDPLATFORM.
# The .2.36 suffix pins glibc to bookworm so binaries run on the runtime image
# and similar-era distros (zig's default would be its newest bundled glibc).
RUN set -eux; \
	case "${TARGETPLATFORM}" in \
		linux/arm64)  TRIPLET="aarch64-linux-gnu" ;; \
		linux/arm/v7) TRIPLET="arm-linux-gnueabihf" ;; \
		*)            TRIPLET="" ;; \
	esac; \
	EXTRA=""; \
	if [ -n "$TRIPLET" ] && [ -d "/usr/lib/$TRIPLET" ]; then \
		EXTRA="-Dtarget=$TRIPLET.2.36 -Dcross-include-dir=/usr/include/$TRIPLET -Dcross-lib-dir=/usr/lib/$TRIPLET"; \
	fi; \
	zig build --release=safe -Doptimize=ReleaseSafe $EXTRA

# --- Export Stage ---
# Bare binary for release assets, extracted with:
#   docker buildx build --target export --platform linux/arm64 --output type=local,dest=dist .
FROM scratch AS export
COPY --from=builder /app/zig-out/bin/pantavisor-mocker /pantavisor-mocker

# --- Runtime Stage ---
FROM debian:bookworm-slim

# Build arguments to know which binary to copy
ARG TARGETPLATFORM

# Install runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
	libcurl4 \
	ca-certificates \
	tmux \
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
