# Local Parakeet verification

Measured 15 October 2026 on Apple Silicon. Sotto's actual `LocalTranscriptionService` and FluidAudio **0.17.7**, commit `503b4bd1bbf7220882de39fe8ae6716aae4132da`, were compiled in debug mode and run as an isolated native process. No microphone, private audio, or paid API was used.

The model was **Parakeet v3**, default CPU + Apple Neural Engine placement. The single downloaded model directory occupies approximately 469 MiB in `.benchmark/models`. Inference uses `AsrModels.loadLocal`, so warm-up and dictation never initiate model downloads. Only explicit preparation may download.

| Measurement | Time |
|---|---:|
| First download, CoreML compilation, loading and warm-up | 45.966 s |
| Fresh-process offline loading and warm-up of cached model | 0.205 s |
| First transcription after that offline warm-up, 11 s audio | 87.6 ms |
| Second transcription, same warm manager | 74.6 ms |
| Third transcription, same warm manager | 72.5 ms |

An earlier post-download process measured 83.2 / 76.8 / 75.9 ms. These times cover local file conversion and ASR, excluding recording, optional cloud polishing, and paste dispatch.

The input was whisper.cpp's [public JFK fixture](https://github.com/ggml-org/whisper.cpp/blob/master/samples/jfk.wav), an 11-second 16 kHz mono WAV with SHA-256 `59dfb9a4acb36fe2a2affc14bacbee2920ff435cb13cc314a08c13f66ba7860e`. Every completed pass returned:

> And so, my fellow Americans, ask not what your country can do for you, ask what you can do for your country.

Against that 22-word reference, lowercasing and removing punctuation gives **0 substitutions, insertions or deletions: 0% normalized WER**. This is one clean English fixture, not a general accuracy estimate for conversational speech, other languages, accents, microphones, or noise.

A separate check cancelled an active inference after 5 ms. It returned `CancellationError`; the next queued session returned the same correct transcript. Each recording receives fresh decoder state, while model weights and the manager remain warm.

The restricted tool sandbox emitted CoreML/IOSurface access failures and measured about 438 ms. The measurements in the table use approved native execution, matching this app's runtime without App Sandbox. They are not a promise for other hardware or deployment environments.

Raw evidence is retained in ignored `.benchmark/results.json`, `parakeet-v3.log`, `parakeet-v3-offline-native.log`, and `parakeet-v3-cancellation.log`.

## Reproduce with the opt-in test

From the project directory, using the existing downloaded model and fixture:

```sh
SOTTO_RUN_LOCAL_BENCHMARK=1 \
SOTTO_BENCHMARK_MODEL_DIR="$PWD/.benchmark/models" \
SOTTO_BENCHMARK_AUDIO="$PWD/.benchmark/jfk.wav" \
SOTTO_BENCHMARK_VARIANT=v3 \
swift test --disable-sandbox --filter LocalParakeetTests/testParakeetFixtureBenchmark
```

Normal tests skip the real benchmark and never download model weights. The opt-in benchmark explicitly calls preparation; missing weights may therefore download to the supplied directory.

FluidAudio's SDK is [Apache-2.0](https://github.com/FluidInference/FluidAudio/blob/v0.17.7/LICENSE). Its [v3 model card](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml) declares CC-BY-4.0 in metadata and identifies NVIDIA's original model plus FluidInference's CoreML conversion; model weights must not be described as covered solely by the SDK license.
