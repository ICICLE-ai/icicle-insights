# ADR 003: Provider-neutral credential service

**Status:** Accepted

Jobs and controllers access credentials through `SecretProvider`, while `configure.swift`
selects a concrete adapter. Tapis Vault provides the first implementation. This boundary keeps
backend configuration and error translation inside adapters and gives future secret managers a
stable integration point.

#icicle-insights# #architecture-decision# #secret-providers# #protocols#
