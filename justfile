set dotenv-load
set export

import 'justfiles/apple-container.just'

default:
    @just --list

run:
    swift run

migrate:
    swift run Insights migrate --yes

revert:
    swift run Insights migrate --revert --yes

# Serial: every suite shares the `test` database and runs its own migrate/revert,
# so they must not run in parallel.
test:
    swift test --no-parallel

fmt:
    swift-format format -i -r -p Sources Tests Package.swift

fmt-check:
    swift-format lint -r -p Sources Tests Package.swift
