# 2. Audio is in v1: Parakeet Ultra + offline diarization via FluidAudio

Date: 2026-10-25. Status: accepted. Overrides spec section 3 ("audio out of scope"), agreed with Noah.

## Decision
Audio Sources are transcribed on the Processor Mac by a small Swift tool built on FluidAudio 0.17.5 (the speech library behind the Seal Speak captioning app): Parakeet Ultra speech-to-text (the most accurate of the on-device engines compared in Seal Speak's internal testing) plus FluidAudio's offline diarizer for speaker labels. Output is a raw, timestamped, speaker-labelled Transcript. It depends on FluidAudio only, so it runs on macOS 14+ (15+ recommended: FluidAudio documents a macOS 14 diarizer crash).

The Transcript is never cleaned up or rewritten by a model. Evidence must quote it exactly, and a rewrite would make that impossible to check.

## Consequences
- Needs an Apple Silicon Mac. First run downloads the Ultra model (~555 MB, CC BY 4.0, attribution in NOTICE).
- Recording a Respondent needs their consent; teammates ask before recording.
