#!/bin/sh
# Build the pinned Spark-X2.5 + TurboQuant llama.cpp combination for Phoenix.
set -eu

TURBO_REPO=https://github.com/TheTom/llama-cpp-turboquant.git
TURBO_COMMIT=4a54c52074e6b1a0c585ebd7ee98cb0555ef060d
SPARK_REPO=https://github.com/XHToken/llama.cpp.git
OUTPUT=${1:-"$PWD/llama-spark-turboquant-aarch64.tar.gz"}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/phoenix-llama.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM

git clone --filter=blob:none --no-checkout "$TURBO_REPO" "$WORK/src"
git -C "$WORK/src" checkout --detach "$TURBO_COMMIT"
git -C "$WORK/src" fetch "$SPARK_REPO" master
git -C "$WORK/src" config user.name phoenix-builder
git -C "$WORK/src" config user.email phoenix-builder@localhost

set +e
git -C "$WORK/src" cherry-pick 6498507f5
status=$?
set -e
if [ "$status" -ne 0 ]; then
	# Both forks add declarations at the same end-of-file position. Keep the
	# TurboQuant declarations and append Spark's complete class declaration.
	git -C "$WORK/src" checkout --ours src/models/models.h
	git -C "$WORK/src" show 6498507f5:src/models/models.h | awk '
		/struct llama_model_spark3/ { copy=1 }
		copy { print }
		copy && /build_arch_graph/ { getline; print; exit }
	' >>"$WORK/src/src/models/models.h"
	git -C "$WORK/src" add src/models/models.h
	git -C "$WORK/src" cherry-pick --continue
fi

for commit in e265bd24c 49a7b3057 f637e4ff3 ee643aa6b 6b0e7ddde ae75169ae; do
	git -C "$WORK/src" cherry-pick "$commit"
done

docker run --rm --platform linux/arm64 \
	-v "$WORK/src:/src" -w /src alpine:edge sh -lc '
		apk add --no-cache build-base cmake ninja openblas-dev linux-headers git binutils
		cmake -S . -B build-phoenix -G Ninja \
			-DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON \
			-DGGML_BLAS=ON -DGGML_BLAS_VENDOR=OpenBLAS \
			-DGGML_NATIVE=OFF \
			-DGGML_CPU_ARM_ARCH=armv8.2-a+dotprod+fp16+crypto+crc \
			-DGGML_VULKAN=OFF -DLLAMA_CURL=OFF \
			-DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF
		cmake --build build-phoenix --target llama-server llama-cli llama-bench -j6
		find build-phoenix/bin -maxdepth 1 -type f \
			\( -name "llama-*" -o -name "lib*.so*" \) \
			-exec strip --strip-unneeded {} + 2>/dev/null || true
	'

tar -C "$WORK/src/build-phoenix" -czf "$OUTPUT" bin
echo "Built $OUTPUT"
echo "TurboQuant base: $TURBO_COMMIT"
echo "Spark source: XHToken/llama.cpp through ae75169ae"
