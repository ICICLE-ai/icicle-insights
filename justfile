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
