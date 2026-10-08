#!/usr/bin/env bash
# Builds the Pipewright launcher image from a Pipewright checkout and pushes it to this environment's images
# repository. Prints the image pinned by digest: set it as launcher_image in terraform.tfvars and apply again.
#
#   scripts/publish_launcher.sh <images repository> [<pipewright checkout>]
#
#   <images repository>   terraform output -raw images_repository
#   <pipewright checkout> default ../pipewright (git clone https://github.com/fluxorsoft/pipewright.git)
#
# Needs Docker, uv and gcloud (signed in). Behind a TLS-inspecting proxy, set PIP_CA=<ca-bundle.pem>: it is passed
# to the image build as a build secret and never stored in a layer.
set -euo pipefail

REPO="${1:?usage: $0 <images repository> [<pipewright checkout>]}"
CORE="$(cd "${2:-$(dirname "$0")/../../pipewright}" && pwd)"
[[ -f "${CORE}/images/launcher.Dockerfile" ]] || { echo "not a Pipewright checkout: ${CORE}" >&2; exit 1; }

VERSION="$(cd "${CORE}" && python3 -c 'import tomllib; print(tomllib.load(open("pyproject.toml", "rb"))["project"]["version"])' 2>/dev/null \
  || (cd "${CORE}" && python -c 'import tomllib; print(tomllib.load(open("pyproject.toml", "rb"))["project"]["version"])'))"
TAG="${REPO}/pipewright-launcher:${VERSION}-$(cd "${CORE}" && git rev-parse --short=12 HEAD 2>/dev/null || date +%Y%m%d%H%M%S)"

echo "building Pipewright ${VERSION} from ${CORE}" >&2
(cd "${CORE}" && rm -rf dist && uv build --wheel --out-dir dist >/dev/null)

SECRET=()
[[ -n "${PIP_CA:-}" ]] && SECRET=(--secret "id=pip_ca,src=${PIP_CA}")
DOCKER_BUILDKIT=1 docker build -q "${SECRET[@]}" -f "${CORE}/images/launcher.Dockerfile" --build-arg VERSION="${VERSION}" \
  -t "${TAG}" "${CORE}" >/dev/null

gcloud auth print-access-token | docker login -u oauth2accesstoken --password-stdin "https://${REPO%%/*}" >/dev/null
docker push -q "${TAG}" >/dev/null
DIGEST="$(docker inspect --format='{{index .RepoDigests 0}}' "${TAG}")"
echo "${DIGEST}"
