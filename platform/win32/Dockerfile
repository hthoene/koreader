# Cross-compilation environment for the Windows target (`TARGET=win32`).
#
# Build the image with:
#
#   docker build -t koreader/kowin32 platform/win32
#
# The toolchain is llvm-mingw (Clang + LLD + mingw-w64 targeting the Universal
# C Runtime), which supports x86_64, i686 and aarch64 Windows targets.

FROM koreader/kobase:5.0.0-22.04

ARG LLVM_MINGW_VERSION=20260922
ARG LLVM_MINGW_SHA256=bb7bb7654b33d5aa8712acb837c963b2e0c56352560c76105270a3268c665c21

USER root

# NSIS is used to generate the installer, rsync is handy to sync a source tree into the container.
RUN apt-get update \
    && apt-get install -y --no-install-recommends nsis rsync \
    && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    name="llvm-mingw-${LLVM_MINGW_VERSION}-ucrt-ubuntu-22.04-x86_64"; \
    curl -fsSL -o /tmp/llvm-mingw.tar.xz \
        "https://github.com/mstorsjo/llvm-mingw/releases/download/${LLVM_MINGW_VERSION}/${name}.tar.xz"; \
    echo "${LLVM_MINGW_SHA256}  /tmp/llvm-mingw.tar.xz" | sha256sum -c -; \
    tar -xJf /tmp/llvm-mingw.tar.xz -C /opt; \
    mv "/opt/${name}" /opt/llvm-mingw; \
    rm /tmp/llvm-mingw.tar.xz

ENV PATH=/opt/llvm-mingw/bin:${PATH}

USER ko
