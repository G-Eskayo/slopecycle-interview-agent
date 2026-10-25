# slope-transcribe

The audio step of the interview analyst. Takes one recorded interview, writes a timestamped, speaker-labelled transcript as JSON. Speech-to-text is Parakeet Ultra and speaker labels come from FluidAudio's offline diarizer, both running locally on Core ML. Why this design: [ADR 0002](../docs/adr/0002-audio-in-v1-parakeet-ultra.md).

Needs an Apple Silicon Mac, macOS 14 or later. Use 15 or later if you can, because FluidAudio documents a macOS 14 bug that can crash the diarizer.

## Build

```sh
swift build -c release      # binary: .build/release/slope-transcribe
swift test                  # unit tests for the word/speaker merge logic
```

The only dependency is FluidAudio, pinned to `exact: "0.17.5"`.

## Usage

```sh
slope-transcribe <audio-file> [--out FILE] [--models-dir DIR] [--asr-dir DIR] [--no-diarize]
```

- `<audio-file>`: anything AVFoundation can read, at any sample rate, mono or stereo. Tested with wav (16 kHz mono) and m4a/AAC (44.1 kHz stereo).
- `--out FILE`: write the JSON here. Without it, the JSON goes to stdout.
- `--models-dir DIR`: model cache. Defaults to `~/Library/Application Support/slope-transcribe/models`. The ASR model goes in `DIR/parakeet-ultra` (about 555 MB, downloaded on first run) and the diarizer models go in `DIR/speaker-diarization`.
- `--asr-dir DIR`: load a Parakeet Ultra build from this folder and skip the download. The folder must hold `Preprocessor`, `Encoder`, `Decoder` and `JointDecisionv3` `.mlmodelc` bundles plus `parakeet_vocab.json`.
- `--no-diarize`: skip speaker labelling. All speech is labelled `S1`.

stdout carries only the JSON. Progress and logs go to stderr. Exit codes:

- `0`: success.
- `1`: failure, such as a missing file, unreadable audio, a model that won't load or failed transcription. The last stderr line is `slope-transcribe: <reason>`.
- `2`: bad arguments.

If diarization fails, the run still succeeds. Every word is labelled `S1` and the reason is added to `warnings`.

## Output

```json
{
  "diarized": true,
  "duration_seconds": 21.4,
  "engine": "parakeet-ultra",
  "fluidaudio": "0.17.5",
  "segments": [
    {"end": 5.68, "speaker": "S1", "start": 0, "text": "Thanks for joining me today. ..."},
    {"end": 12.48, "speaker": "S2", "start": 5.68, "text": "Sure, I mostly use a paper map ..."}
  ],
  "warnings": []
}
```

- Keys are sorted, and times are in seconds, rounded to milliseconds.
- A segment is one turn: consecutive words from one speaker. Each word goes to the diarizer speaker whose segments overlap it most. A word that falls in a gap goes to the nearest segment.
- Speakers are numbered `S1`, `S2`, ... in the order they first speak.
- Segment text is the raw ASR output with no model clean-up, so quotes can be checked against it exactly.
- Silent audio gives `"segments": []` and a warning.

## Models and credit

- Speech-to-text: **Parakeet Ultra** ([moondream/parakeet-ultra](https://huggingface.co/moondream/parakeet-ultra)), licensed CC BY 4.0. This tool uses the Core ML conversion [FluidInference/parakeet-ultra-coreml](https://huggingface.co/FluidInference/parakeet-ultra-coreml).
- Diarization: FluidAudio's offline VBx pipeline (`OfflineDiarizerManager`, pyannote-style segmentation, WeSpeaker embeddings, VBx clustering). Its models are downloaded by FluidAudio on first use.
- Runtime: [FluidAudio](https://github.com/FluidInference/FluidAudio) 0.17.5.
