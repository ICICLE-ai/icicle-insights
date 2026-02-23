# https://just.systems
# CMake build system

CONAN_DEPS_DIR := "build/conan"
BUILD_DIR := "build"
OPENSSL_ROOT := if os() == "macos" { `brew --prefix openssl@3` } else { "/usr" }

set dotenv-load := true
set export := true

default:
    @just --list

# Install dependencies with Conan
deps:
    conan install . --build=missing --output-folder={{ CONAN_DEPS_DIR }} -s compiler.cppstd=gnu23

# Configure CMake build
setup:
    cmake -B {{ BUILD_DIR }} \
          -DCMAKE_TOOLCHAIN_FILE={{ CONAN_DEPS_DIR }}/conan_toolchain.cmake \
          -DCMAKE_BUILD_TYPE=Release \
          -G Ninja

# Build the project
build:
    cmake --build {{ BUILD_DIR }}

# Full build from scratch
full-build: deps setup build

# Clean and rebuild
clean-build:
    rm -rf build
    just full-build

# Run the application
run:
    {{ BUILD_DIR }}/icicle-insights

docker-build:
  docker buildx build --platform linux/amd64 -t ghcr.io/icicle-ai/insights:latest .

docker-run:
  docker run -itd -p 3000:3000 --env-file=.env --name insights ghcr.io/icicle-ai/insights:latest

act-build:
  act -j docker \
        --container-architecture linux/amd64 \
        -P ubuntu-24.04=ghcr.io/catthehacker/ubuntu:act-24.04 \
        --secret GITHUB_TOKEN="$(gh auth token)" \
        --env SSL_CERT_FILE= \
        --env CURL_CA_BUNDLE= \
        --env REQUESTS_CA_BUNDLE=

act-linux:
  act -j linux \
        --container-architecture linux/amd64 \
        -P ubuntu-24.04=ghcr.io/catthehacker/ubuntu:act-24.04 \
        --secret GITHUB_TOKEN="$(gh auth token)" \
        --env SSL_CERT_FILE= \
        --env CURL_CA_BUNDLE= \
        --env REQUESTS_CA_BUNDLE=
