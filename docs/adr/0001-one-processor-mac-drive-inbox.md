# 1. One Processor Mac, a Drive Inbox as the queue, Git for code only

Date: 2026-10-25. Status: superseded by [0005](0005-event-driven-git-queue.md) (queue and triggers); the single Processor Mac still holds.

## Context
Five teammates, no always-on server, no paid subscriptions, everyone must be able to explain the system in a live demo. The agent must not run on Gil's machines.

## Decision
One teammate's Mac (Noah's) is the Processor Mac. It runs n8n, Ollama and the transcriber. Teammates put Sources in one shared Drive folder (the Inbox) from any device and install nothing. Whenever the Processor Mac is awake, a 5-minute schedule picks up everything waiting. A private Git repo holds the code, prompts and workflow export, never interview data.

## Rejected
- Every Mac runs the full stack: five installs, ~16 GB RAM each, version skew, cross-machine duplicate races.
- Git repo as the queue: every clone holds every recording, history never shrinks, GitHub rejects files over 100 MB, Git is hostile to non-technical teammates.
- n8n Cloud / hosted model: paid after trial; cannot reach local Ollama.

## Consequences
Sources wait while the Processor Mac sleeps. Only one machine processes, so concurrency is limited to overlapping runs on that machine (handled by the run ledger, ADR 0003).
