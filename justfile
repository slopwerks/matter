set shell := ["bash", "-euo", "pipefail", "-c"]

image := "localhost/matter-devcontainer"
podman := env_var_or_default("PODMAN", "podman")

default: build-image

# Build the development image.
build-image:
    {{podman}} build --tag {{image}} --file Containerfile .

# Open a shell with the repository mounted in the development image.
shell: build-image
    {{podman}} run --rm -it \
        --userns=keep-id \
        --volume "$PWD:/workspace:Z" \
        --volume matter-pub-cache:/root/.pub-cache \
        --volume matter-cargo-cache:/opt/cargo \
        --volume matter-rustup-cache:/opt/rustup \
        --volume /dev/bus/usb:/dev/bus/usb \
        --workdir /workspace \
        {{image}}

build-release-apk: build-image
    mkdir -p build
    {{podman}} run --rm \
        --userns=keep-id \
        --volume "$PWD:/workspace:Z" \
        --volume matter-pub-cache:/root/.pub-cache \
        --volume matter-cargo-cache:/opt/cargo \
        --volume matter-rustup-cache:/opt/rustup \
        --workdir /workspace \
        {{image}} \
        -lc 'flutter pub get && flutter_rust_bridge_codegen generate && flutter build apk --release --target-platform android-arm64'

build-profile-apk: build-image
    mkdir -p build
    {{podman}} run --rm \
        --userns=keep-id \
        --volume "$PWD:/workspace:Z" \
        --volume matter-pub-cache:/root/.pub-cache \
        --volume matter-cargo-cache:/opt/cargo \
        --volume matter-rustup-cache:/opt/rustup \
        --workdir /workspace \
        {{image}} \
        -lc 'flutter pub get && flutter_rust_bridge_codegen generate && flutter build apk --profile --target-platform android-arm64'

build-debug-apk: build-image
    mkdir -p build
    {{podman}} run --rm \
        --userns=keep-id \
        --volume "$PWD:/workspace:Z" \
        --volume matter-pub-cache:/root/.pub-cache \
        --volume matter-cargo-cache:/opt/cargo \
        --volume matter-rustup-cache:/opt/rustup \
        --workdir /workspace \
        {{image}} \
        -lc 'flutter pub get && flutter_rust_bridge_codegen generate && flutter build apk --debug --target-platform android-arm64'

# Run profile app on device
profile: build-image
    mkdir -p build
    {{podman}} run --rm \
        --userns=keep-id \
        --volume "$PWD:/workspace:Z" \
        --volume matter-pub-cache:/root/.pub-cache \
        --volume matter-cargo-cache:/opt/cargo \
        --volume matter-rustup-cache:/opt/rustup \
        --volume /dev/bus/usb:/dev/bus/usb \
        --workdir /workspace \
        {{image}} \
        -lc 'flutter pub get && flutter_rust_bridge_codegen generate && flutter run --profile'
