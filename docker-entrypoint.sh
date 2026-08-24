#!/bin/sh
#
# Applies migrations before starting the API, and only then.
#
# This image backs every process in the stack — the queue worker, the scheduler and each one-shot
# command run it with their own argument list — so migrating unconditionally here would mean three
# concurrent migrators on every `docker compose up`. Keying on the command confines it to the one
# container whose job is to serve.
#
# `migrate-locked` rather than Vapor's `migrate`: it takes a PostgreSQL advisory lock, so scaling
# the API past one replica makes the extra replicas wait rather than race. `migrate` stays the
# right command for a deliberate deployment step.
#
# `set -e` matters: a failed migration must stop the container rather than serve requests against
# a schema that does not match the binary.
set -e

if [ "$1" = "serve" ]; then
  ./Insights migrate-locked
fi

exec ./Insights "$@"
