# 4. Extraction runs on local Ollama

Date: 2026-10-25. Status: accepted.

## Decision
The extraction model runs in Ollama on the Processor Mac (default `qwen3:8b`, configurable), with a JSON schema as the required output format and temperature 0. No interview text leaves the team's own Mac and Google account, so the model-provider disclosure is "none: local model".

## Consequences
An 8B model will sometimes misquote or misattribute. The processor checks every excerpt against the source text and drops or flags what it cannot find; calculated values are computed in code, never by the model. If testing shows long interviews extract poorly, the fallback is chunking, then a hosted model with Noah's agreement.
