#!/usr/bin/env bash
# Puts the Pipewright launcher image into this environment's images repository and prints it pinned by digest: set
# it as launcher_image in terraform.tfvars and apply again.
#
#   scripts/publish_launcher.sh <images repository>                                   copy the 1.4.4 release (default)
#   scripts/publish_launcher.sh <images repository> --from <image>@sha256:...         copy another release
#   scripts/publish_launcher.sh <images repository> --build [<pipewright checkout>]   build from source
#
#   <images repository>    terraform output -raw images_repository
#   --from                 a released launcher image, pinned by digest (each release's notes on GitHub give it)
#   --build                build from a Pipewright checkout, default ../pipewright
#                          (git clone https://github.com/fluxorsoft/pipewright.git); needs uv as well
#
# Needs Docker (with buildx, part of Docker 23 and later) and gcloud (signed in). A copied release is copied registry to
# registry, so it keeps its digest, and the script fails if it does not: the image that was released is the image that
# runs. Behind a TLS-inspecting proxy, a build takes PIP_CA=<ca-bundle.pem>
# as a build secret, never stored in a layer.
set -euo pipefail

RELEASE="ghcr.io/fluxorsoft/pipewright-launcher@sha256:9118ec478b9b435cb0cd1f5c10bd82c3ed6b9e11c85bef127441cd8f321d7cf8"   # 1.4.5
REPO="${1:?usage: $0 <images repository> [--from <image>@sha256:... | --build [<pipewright checkout>]]}"
MODE="${2:---from}"
IMAGE="${REPO}/pipewright-launcher"

case "${MODE}" in
  --from)
    SRC="${3:-${RELEASE}}"
    [[ "${SRC}" == *@sha256:* ]] || { echo "pin the released image by digest: ${SRC}" >&2; exit 2; }
    echo "copying ${SRC}" >&2
    docker pull -q "${SRC}" >/dev/null
    COMPONENT="$(docker inspect --format '{{ index .Config.Labels "dev.pipewright.component" }}' "${SRC}")"
    [[ "${COMPONENT}" == "launcher" ]] || { echo "${SRC} is not a Pipewright launcher image" >&2; exit 2; }
    VERSION="$(docker inspect --format '{{ index .Config.Labels "dev.pipewright.version" }}' "${SRC}")"
    TAG="${IMAGE}:${VERSION}"
    ;;
  --build)
    CORE="$(cd "${3:-$(dirname "$0")/../../pipewright}" && pwd)"
    [[ -f "${CORE}/images/launcher.Dockerfile" ]] || { echo "not a Pipewright checkout: ${CORE}" >&2; exit 1; }
    VERSION="$(cd "${CORE}" && python3 -c 'import tomllib; print(tomllib.load(open("pyproject.toml", "rb"))["project"]["version"])' 2>/dev/null \
      || (cd "${CORE}" && python -c 'import tomllib; print(tomllib.load(open("pyproject.toml", "rb"))["project"]["version"])'))"
    TAG="${IMAGE}:${VERSION}-$(cd "${CORE}" && git rev-parse --short=12 HEAD 2>/dev/null || date +%Y%m%d%H%M%S)"
    echo "building Pipewright ${VERSION} from ${CORE}" >&2
    (cd "${CORE}" && rm -rf dist && uv build --wheel --out-dir dist >/dev/null)
    SECRET=()
    [[ -n "${PIP_CA:-}" ]] && SECRET=(--secret "id=pip_ca,src=${PIP_CA}")
    DOCKER_BUILDKIT=1 docker build -q "${SECRET[@]}" -f "${CORE}/images/launcher.Dockerfile" --build-arg VERSION="${VERSION}" \
      -t "${TAG}" "${CORE}" >/dev/null
    ;;
  *) echo "unknown option ${MODE}: use --from <image>@sha256:... or --build [<pipewright checkout>]" >&2; exit 2 ;;
esac

gcloud auth print-access-token | docker login -u oauth2accesstoken --password-stdin "https://${REPO%%/*}" >/dev/null
if [[ "${MODE}" == "--from" ]]; then
  # Registry to registry: the manifests are copied as they are, so the stored digest is the released one. A pull, tag
  # and push re-encodes the image on Docker Desktop's containerd image store and changes the digest (found 2026-11-14).
  docker buildx version >/dev/null 2>&1 || { echo "needs docker buildx (part of Docker 23 and later)" >&2; exit 1; }
  docker buildx imagetools create -t "${TAG}" "${SRC}" >/dev/null 2>&1     || { echo "could not copy ${SRC} to ${TAG}" >&2; exit 1; }
  STORED="$(docker buildx imagetools inspect "${TAG}" | awk '/^Digest:/ {print $2; exit}')"
  DIGEST="${IMAGE}@${STORED}"
  if [[ "${STORED}" != "${SRC#*@}" ]]; then
    echo "digest changed in transit: released ${SRC#*@}, stored ${STORED}" >&2; exit 1
  fi
else
  docker push -q "${TAG}" >/dev/null
  DIGEST="$(docker inspect --format='{{range .RepoDigests}}{{println .}}{{end}}' "${TAG}" | grep "^${IMAGE}@" | head -1)"
fi
echo "${DIGEST}"
