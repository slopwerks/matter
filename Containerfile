FROM ubuntu:24.04

ARG ANDROID_NDK_VERSION=29.0.13113456
ARG FLUTTER_VERSION=3.47.1
ARG ANDROID_CMDLINE_TOOLS_VERSION=11076708

ENV ANDROID_HOME=/opt/android-sdk \
    ANDROID_SDK_ROOT=/opt/android-sdk \
    ANDROID_NDK_VERSION=${ANDROID_NDK_VERSION} \
    ANDROID_NDK_HOME=/opt/android-sdk/ndk/${ANDROID_NDK_VERSION} \
    ANDROID_NDK_ROOT=/opt/android-sdk/ndk/${ANDROID_NDK_VERSION} \
    CARGO_HOME=/opt/cargo \
    RUSTUP_HOME=/opt/rustup \
    PATH=/opt/flutter/bin:/opt/flutter/bin/cache/dart-sdk/bin:/opt/android-sdk/cmdline-tools/latest/bin:/opt/android-sdk/platform-tools:/opt/cargo/bin:/opt/rustup/bin:${PATH}

USER root

RUN apt-get update \
    && apt-get install --no-install-recommends -y \
        clang \
        cmake \
        curl \
        git \
        lib32stdc++6 \
        lib32z1 \
        libglu1-mesa-dev \
        libgtk-3-dev \
        libsecret-1-dev \
        liblzma-dev \
        ninja-build \
        openjdk-17-jdk \
        pkg-config \
        unzip \
        xz-utils \
        zip \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p "${ANDROID_SDK_ROOT}/cmdline-tools" \
    && curl --fail --silent --show-error --location \
        "https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_CMDLINE_TOOLS_VERSION}_latest.zip" \
        --output /tmp/android-command-line-tools.zip \
    && unzip -q /tmp/android-command-line-tools.zip -d "${ANDROID_SDK_ROOT}/cmdline-tools" \
    && mv "${ANDROID_SDK_ROOT}/cmdline-tools/cmdline-tools" "${ANDROID_SDK_ROOT}/cmdline-tools/latest" \
    && rm /tmp/android-command-line-tools.zip

RUN curl --fail --silent --show-error --location \
        "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz" \
        --output /tmp/flutter.tar.xz \
    && tar -xJf /tmp/flutter.tar.xz -C /opt \
    && git config --global --add safe.directory /opt/flutter \
    && rm /tmp/flutter.tar.xz

RUN curl --proto '=https' --tlsv1.2 --fail --silent --show-error https://sh.rustup.rs \
        | sh -s -- -y --default-toolchain stable \
    && rustup target add aarch64-linux-android \
    && cargo install --locked cargo-ndk \
    && cargo install --locked flutter_rust_bridge_codegen --version 2.13.0

RUN yes | sdkmanager --licenses >/dev/null \
    && sdkmanager \
        "platform-tools" \
        "platforms;android-37.2" \
        "build-tools;35.0.0" \
        "ndk;${ANDROID_NDK_VERSION}" \
    && flutter precache --android \
    && flutter doctor

ENV PATH=${CARGO_HOME}/bin:${RUSTUP_HOME}/bin:${PATH}

WORKDIR /workspace
ENTRYPOINT ["/bin/bash"]
