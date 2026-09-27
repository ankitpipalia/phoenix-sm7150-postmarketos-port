#!/bin/bash
# Build the Project Silicium (Mu) UEFI for Xiaomi phoenix from a pinned commit.
#
# Mirrors upstream CI (ubuntu-24.04 amd64, `setup_env.sh -p apt`) inside Docker,
# because macOS is not a supported build host and upstream's toolchain setup
# pulls x86-64 Linux binaries.  phoenix is an *inactive* target that upstream CI
# never builds, so a pinned, logged build is the only provenance available.
#
# Output (in artifacts/windows/ by default):
#   Mu-phoenix-1-RELEASE.img, Mu-phoenix-1-DEBUG.img  Android boot images
#   provenance.txt                                    exact source revisions
#   build-*.log, SHA256SUMS
#
# The images are meant for a tethered RAM boot (`fastboot boot`), which writes
# nothing to the phone: UEFI variables are RAM-emulated in this build.
set -euo pipefail

PIN=${MU_SILICIUM_COMMIT:-d19ae66c49fa47e47fd56a28e0e4db58b3638968}
MODEL=${MU_PHOENIX_MODEL:-1}          # 0 = Redmi K30 SMBIOS strings, 1 = POCO X2
OUT=${1:-"$(cd "$(dirname "$0")/.." && pwd)/artifacts/windows"}
VOLUME=${MU_SILICIUM_VOLUME:-mu-silicium-src}
NAME=mu-phoenix-build

command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "docker daemon is not running" >&2; exit 1; }
mkdir -p "$OUT"
docker volume create "$VOLUME" >/dev/null

inner=$(mktemp)
trap 'rm -f "$inner"' EXIT
cat > "$inner" <<EOF
#!/bin/bash
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq sudo git ca-certificates >/dev/null
git config --global advice.detachedHead false
cd /work
[ -d Mu-Silicium/.git ] || git clone --quiet https://github.com/Project-Silicium/Mu-Silicium.git
cd Mu-Silicium
git fetch --quiet origin
git checkout --quiet --detach "$PIN"
git submodule sync --recursive --quiet
git submodule update --init --recursive --jobs 8
bash ./setup_env.sh -p apt
{
  echo "superproject \$(git rev-parse HEAD)"
  git submodule status --recursive
  echo; echo "toolchain:"; clang --version | head -1; ld.lld --version | head -1; python3 --version
} > /out/provenance.txt
for target in RELEASE DEBUG; do
  python3 build_uefi.py -d phoenix -m "$MODEL" -r "\$target" 2>&1 | tail -40 | tee "/out/build-\$target.log"
  img=\$(ls -1 Mu-phoenix*.img 2>/dev/null | head -1 || true)
  [ -n "\$img" ] || { echo "no image produced for \$target" >&2; exit 1; }
  cp "\$img" "/out/Mu-phoenix-$MODEL-\$target.img"; rm -f "\$img"
done
cd /out && sha256sum Mu-phoenix-*.img > SHA256SUMS
EOF

docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run --rm --name "$NAME" --platform linux/amd64 \
	-v "$VOLUME":/work -v "$OUT":/out -v "$inner":/build.sh:ro \
	ubuntu:24.04 bash /build.sh

echo
echo "Built images in $OUT:"
cat "$OUT/SHA256SUMS"
