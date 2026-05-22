FROM debian:trixie

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    curl xz-utils ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install Zig 0.16.0 (auto-detect architecture)
RUN ARCH=$(dpkg --print-architecture) \
    && ZIG_ARCH=$([ "$ARCH" = "arm64" ] && echo "aarch64" || echo "$ARCH") \
    && curl -L -o /tmp/zig.tar.xz https://ziglang.org/download/0.16.0/zig-${ZIG_ARCH}-linux-0.16.0.tar.xz \
    && tar -xf /tmp/zig.tar.xz -C /opt \
    && ln -s /opt/zig-${ZIG_ARCH}-linux-0.16.0/zig /usr/local/bin/zig \
    && rm /tmp/zig.tar.xz

WORKDIR /src
COPY . /src/
RUN zig build -Doptimize=ReleaseFast --prefix /opt/zpayload-install
