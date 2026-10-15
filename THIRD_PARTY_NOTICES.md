# Third-party notices

## FluidAudio

FluidAudio 0.17.7, commit503b4bd1bbf7220882de39fe8ae6716aae4132da, by FluidInference and contributors, is used for local ASR. Source: https://github.com/FluidInference/FluidAudio/tree/v0.17.7 . SDK license: Apache License2.0. A copy is included in Resources/FluidAudio-LICENSE.txt and the packaged application resources. No NeMo text-processing features are enabled.

## Parakeet model weights

NVIDIA developed Parakeet TDT0.6B v3; FluidInference provides the CoreML conversion. Model card: https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml . The model-card metadata declares Creative Commons Attribution4.0 (https://creativecommons.org/licenses/by/4.0/). Its prose footer differs, so do not assume the SDK Apache license alone covers weights. Sotto does not alter the weights. The lightweight app/source ZIPs omit weights; locally prepared model files are maintained separately. Other variants have their own model cards and terms.

## Whisper

The optional local server integration uses the public whisper.cpp HTTP interface. whisper.cpp is maintained by ggml-org: https://github.com/ggml-org/whisper.cpp . No whisper.cpp executable or Whisper weights are included in Sotto's bundle.

## Benchmark audio

The public JFK fixture is provided by whisper.cpp at https://github.com/ggml-org/whisper.cpp/blob/master/samples/jfk.wav . Its provenance and digest are recorded in LOCAL_BENCHMARK.md. It contains historical speech, not user microphone audio.
