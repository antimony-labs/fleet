#!/usr/bin/env bash
set -euo pipefail

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run this updater as root." >&2
  exit 1
fi

require_cmd curl
require_cmd jq
require_cmd sha256sum
require_cmd tar
require_cmd install
require_cmd systemctl
require_cmd uname

arch="$(uname -m)"
case "${arch}" in
  x86_64)
    target_triple="x86_64-unknown-linux-musl"
    ;;
  aarch64|arm64)
    target_triple="aarch64-unknown-linux-musl"
    ;;
  *)
    echo "Unsupported architecture: ${arch}" >&2
    exit 1
    ;;
esac

REPO="${GH_RELEASE_REPO:-antimony-labs/fleet}"
BINARY_NAME="${FLEET_AGENT_BINARY_NAME:-fleet_agent}"
ASSET_NAME="${FLEET_AGENT_RELEASE_ASSET:-${BINARY_NAME}-${target_triple}.tar.gz}"
CHECKSUM_NAME="${ASSET_NAME}.sha256"
INSTALL_PATH="${FLEET_AGENT_INSTALL_PATH:-/usr/local/bin/${BINARY_NAME}}"
SERVICE_NAME="${FLEET_AGENT_SERVICE_NAME:-fleet-agent.service}"
STATE_DIR="${FLEET_AGENT_STATE_DIR:-/var/lib/antimony/fleet-agent}"
STATE_FILE="${STATE_DIR}/current-release"

api_headers=(
  -H "Accept: application/vnd.github+json"
  -H "X-GitHub-Api-Version: 2022-11-28"
)
asset_headers=(
  -H "Accept: application/octet-stream"
  -H "X-GitHub-Api-Version: 2022-11-28"
)

if [[ -n "${GH_RELEASE_TOKEN:-}" ]]; then
  api_headers+=(-H "Authorization: Bearer ${GH_RELEASE_TOKEN}")
  asset_headers+=(-H "Authorization: Bearer ${GH_RELEASE_TOKEN}")
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

release_json="$(curl -fsSL "${api_headers[@]}" "https://api.github.com/repos/${REPO}/releases/latest")"

release_tag="$(jq -r '.tag_name' <<<"${release_json}")"
asset_url="$(
  jq -r --arg asset "${ASSET_NAME}" '
    .assets[]
    | select(.name == $asset)
    | .url
  ' <<<"${release_json}"
)"
checksum_url="$(
  jq -r --arg asset "${CHECKSUM_NAME}" '
    .assets[]
    | select(.name == $asset)
    | .url
  ' <<<"${release_json}"
)"

if [[ -z "${release_tag}" || "${release_tag}" == "null" ]]; then
  echo "Unable to determine latest GitHub release tag for ${REPO}." >&2
  exit 1
fi

if [[ -z "${asset_url}" || "${asset_url}" == "null" ]]; then
  echo "Release asset not found: ${ASSET_NAME}" >&2
  exit 1
fi

if [[ -z "${checksum_url}" || "${checksum_url}" == "null" ]]; then
  echo "Checksum asset not found: ${CHECKSUM_NAME}" >&2
  exit 1
fi

mkdir -p "${STATE_DIR}"
if [[ -f "${STATE_FILE}" ]] && [[ "$(cat "${STATE_FILE}")" == "${release_tag}" ]]; then
  echo "Fleet agent already on ${release_tag}."
  exit 0
fi

echo "Fetching latest release ${release_tag} from ${REPO}."
echo "Downloading ${ASSET_NAME}."
curl -fsSL "${asset_headers[@]}" "${asset_url}" -o "${tmpdir}/${ASSET_NAME}"
echo "Downloading ${CHECKSUM_NAME}."
curl -fsSL "${asset_headers[@]}" "${checksum_url}" -o "${tmpdir}/${CHECKSUM_NAME}"

expected_sha="$(awk '{print $1}' "${tmpdir}/${CHECKSUM_NAME}")"
actual_sha="$(sha256sum "${tmpdir}/${ASSET_NAME}" | awk '{print $1}')"
if [[ "${expected_sha}" != "${actual_sha}" ]]; then
  echo "Checksum mismatch for ${ASSET_NAME}." >&2
  exit 1
fi
echo "Checksum verified for ${ASSET_NAME}."

release_dir="${STATE_DIR}/releases/${release_tag}"
mkdir -p "${release_dir}"
tar -xzf "${tmpdir}/${ASSET_NAME}" -C "${release_dir}"

candidate="${release_dir}/${BINARY_NAME}"
if [[ ! -x "${candidate}" ]]; then
  echo "Release asset did not contain ${BINARY_NAME}." >&2
  exit 1
fi

backup_path=""
if [[ -f "${INSTALL_PATH}" ]]; then
  backup_path="${tmpdir}/${BINARY_NAME}.bak"
  cp "${INSTALL_PATH}" "${backup_path}"
fi

install -m 0755 "${candidate}" "${INSTALL_PATH}.new"
mv "${INSTALL_PATH}.new" "${INSTALL_PATH}"
echo "Installed ${BINARY_NAME} to ${INSTALL_PATH}."

if ! systemctl restart "${SERVICE_NAME}"; then
  if [[ -n "${backup_path}" ]]; then
    install -m 0755 "${backup_path}" "${INSTALL_PATH}.new"
    mv "${INSTALL_PATH}.new" "${INSTALL_PATH}"
    systemctl restart "${SERVICE_NAME}" || true
  fi
  echo "Failed to restart ${SERVICE_NAME}; rolled binary back." >&2
  exit 1
fi
echo "Restarted ${SERVICE_NAME}."

if ! systemctl is-active --quiet "${SERVICE_NAME}"; then
  if [[ -n "${backup_path}" ]]; then
    install -m 0755 "${backup_path}" "${INSTALL_PATH}.new"
    mv "${INSTALL_PATH}.new" "${INSTALL_PATH}"
    systemctl restart "${SERVICE_NAME}" || true
  fi
  echo "${SERVICE_NAME} did not become healthy after restart." >&2
  exit 1
fi

printf '%s\n' "${release_tag}" > "${STATE_FILE}"
echo "Updated fleet agent to ${release_tag} for ${target_triple}."
