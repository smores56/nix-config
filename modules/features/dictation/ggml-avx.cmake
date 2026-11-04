# whisper-rs-sys forwards CMAKE_TOOLCHAIN_FILE to cmake, the only way to inject cache
# variables into the bundled whisper.cpp; unoptimised ggml decodes ~6x slower.
# GGML_NATIVE is off because it adds -march=native without defining GGML_AVX2/FMA/F16C,
# leaving the fast kernels disabled. Assumes AVX2 (Haswell, 2013+).
set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
set(GGML_AVX ON CACHE BOOL "" FORCE)
set(GGML_AVX2 ON CACHE BOOL "" FORCE)
set(GGML_FMA ON CACHE BOOL "" FORCE)
set(GGML_F16C ON CACHE BOOL "" FORCE)
