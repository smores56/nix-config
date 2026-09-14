# whisper-rs-sys forwards CMAKE_TOOLCHAIN_FILE to its cmake invocation, which is
# the only reliable way to inject cache variables into the bundled whisper.cpp
# build. Upstream's plain buildRustPackage compiles ggml unoptimised, so every
# phrase decode is ~6x slower than native whisper.cpp (measured 12.5s vs 2.1s
# for one 11.2s phrase) and whisrs' phrase-level streaming degenerates into
# something that only lands when you stop recording.
#
# GGML_NATIVE is off so the SIMD set is explicit rather than host-detected; every
# host this config covers is AVX2-capable, and a fixed baseline keeps the build
# reproducible.
set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
set(GGML_AVX ON CACHE BOOL "" FORCE)
set(GGML_AVX2 ON CACHE BOOL "" FORCE)
set(GGML_FMA ON CACHE BOOL "" FORCE)
set(GGML_F16C ON CACHE BOOL "" FORCE)
