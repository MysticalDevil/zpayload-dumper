FROM debian:trixie

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    curl xz-utils ca-certificates \
    build-essential cmake git pkg-config \
    libbz2-dev \
    && rm -rf /var/lib/apt/lists/*

# Build protobuf v31.1 from source (full build, then install)
RUN git clone --depth 1 --branch v31.1 https://github.com/protocolbuffers/protobuf.git /tmp/protobuf \
    && cd /tmp/protobuf \
    && cmake -S . -B build \
        -DCMAKE_BUILD_TYPE=Release \
        -Dprotobuf_BUILD_LIBUPB=ON \
        -Dprotobuf_BUILD_TESTS=OFF \
        -Dprotobuf_BUILD_SHARED_LIBS=OFF \
    && cmake --build build -j$(nproc) \
    && cmake --install build \
    && ldconfig \
    && rm -rf /tmp/protobuf

# Install Zig 0.16.0 (auto-detect architecture)
RUN ARCH=$(dpkg --print-architecture) \
    && ZIG_ARCH=$([ "$ARCH" = "arm64" ] && echo "aarch64" || echo "$ARCH") \
    && curl -L -o /tmp/zig.tar.xz https://ziglang.org/download/0.16.0/zig-${ZIG_ARCH}-linux-0.16.0.tar.xz \
    && tar -xf /tmp/zig.tar.xz -C /opt \
    && ln -s /opt/zig-${ZIG_ARCH}-linux-0.16.0/zig /usr/local/bin/zig \
    && rm /tmp/zig.tar.xz

WORKDIR /src

CMD ["zig", "build"]
