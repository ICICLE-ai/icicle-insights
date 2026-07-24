set dotenv-load
set export

default:
    @just --list

run:
    swift run

migrate:
    swift run Insights migrate

revert:
    swift run Insights migrate --revert

# Serial: every suite shares the `test` database and runs its own migrate/revert,
# so they must not run in parallel.
test:
    swift test --no-parallel

fmt:
    swiftformat Sources Tests Package.swift

fmt-check:
    swiftformat Sources Tests Package.swift --lint

build:
    container  build --tag icicle-insights --file Dockerfile .

start: build
    container run --env-file .env --name icicle-insights --detach --rm icicle-insights
stop:
    container stop icicle-insights
