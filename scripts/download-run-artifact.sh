#!/usr/bin/env bash

set -Eeuo pipefail

_download_run_artifact_usage() {
  printf '%s\n' \
    'Usage: scripts/download-run-artifact.sh RUN_ID ARTIFACT_NAME DEST_DIR' \
    '' \
    'Download one artifact from workflow run RUN_ID in GITHUB_REPOSITORY and' \
    'extract it into DEST_DIR. The zip is written to disk first, so a stalled or' \
    'interrupted transfer resumes from the bytes already downloaded. The zip must' \
    'match the artifact digest before it is extracted.' \
    '' \
    'Environment:' \
    '  GH_TOKEN or GITHUB_TOKEN        token with actions:read on the repository' \
    '  GITHUB_REPOSITORY               OWNER/REPO that owns the run' \
    '  GITHUB_API_URL                  default: https://api.github.com' \
    '  ARTIFACT_DOWNLOAD_ATTEMPTS      default: 10' \
    '  ARTIFACT_DOWNLOAD_RETRY_DELAY   seconds before the first retry, doubled' \
    '                                  up to 60 (default: 5)' \
    '  ARTIFACT_DOWNLOAD_SPEED_LIMIT   bytes per second; an attempt slower than' \
    '                                  this for ARTIFACT_DOWNLOAD_SPEED_TIME' \
    '                                  seconds is aborted and resumed' \
    '                                  (default: 262144)' \
    '  ARTIFACT_DOWNLOAD_SPEED_TIME    default: 60'
}

_download_run_artifact_log() {
  printf '==> %s\n' "$*"
}

_download_run_artifact_die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

_download_run_artifact_require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    _download_run_artifact_die "missing required tool: $1"
  fi
}

_download_run_artifact_require_uint() {
  case "$2" in
    '' | *[!0-9]*)
      _download_run_artifact_die "$1 must be a non-negative integer: $2"
      ;;
  esac
}

_download_run_artifact_api() {
  curl --fail --silent --show-error \
    --connect-timeout 30 --max-time 120 \
    --retry 5 --retry-all-errors --retry-delay 5 \
    --header "Authorization: Bearer $_download_run_artifact_token" \
    --header 'Accept: application/vnd.github+json' \
    --header 'X-GitHub-Api-Version: 2022-11-28' \
    "$@"
}

_download_run_artifact_file_size() {
  if [ -f "$1" ]; then
    wc -c < "$1" | tr -d ' '
  else
    printf '0\n'
  fi
}

_download_run_artifact_sha256() {
  python3 -c '
import hashlib
import sys

digest = hashlib.sha256()
with open(sys.argv[1], "rb") as handle:
    for chunk in iter(lambda: handle.read(1 << 20), b""):
        digest.update(chunk)
print(digest.hexdigest())
' "$1"
}

_download_run_artifact_verify() {
  local actual expected

  expected="$1"
  if [ -z "$expected" ]; then
    _download_run_artifact_log "Artifact has no digest; checking zip CRCs instead"
    python3 -c '
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as archive:
    sys.exit(archive.testzip() is not None)
' "$_download_run_artifact_zip"
    return
  fi

  actual="sha256:$(_download_run_artifact_sha256 "$_download_run_artifact_zip")"
  if [ "$actual" != "$expected" ]; then
    printf 'warning: downloaded zip digest %s does not match %s\n' "$actual" "$expected" >&2
    return 1
  fi
}

_download_run_artifact_cleanup() {
  if [ -n "${_download_run_artifact_zip:-}" ]; then
    rm -f "$_download_run_artifact_zip"
  fi
}

_download_run_artifact_main() {
  local api_url artifact_id artifact_json artifact_name attempt attempts blob_url \
    delay dest_dir digest encoded_name have http_code matches repo run_id size \
    speed_limit speed_time status

  case "${1:-}" in
    --help | -h)
      _download_run_artifact_usage
      exit 0
      ;;
  esac

  if [ "$#" -ne 3 ]; then
    _download_run_artifact_usage >&2
    _download_run_artifact_die "expected RUN_ID, ARTIFACT_NAME, and DEST_DIR"
  fi

  run_id="$1"
  artifact_name="$2"
  dest_dir="$3"
  repo="${GITHUB_REPOSITORY:-}"
  api_url="${GITHUB_API_URL:-https://api.github.com}"
  attempts="${ARTIFACT_DOWNLOAD_ATTEMPTS:-10}"
  delay="${ARTIFACT_DOWNLOAD_RETRY_DELAY:-5}"
  speed_limit="${ARTIFACT_DOWNLOAD_SPEED_LIMIT:-262144}"
  speed_time="${ARTIFACT_DOWNLOAD_SPEED_TIME:-60}"
  _download_run_artifact_token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

  case "$run_id" in
    '' | *[!0-9]* | 0)
      _download_run_artifact_die "RUN_ID must be a positive numeric workflow run ID: $run_id"
      ;;
  esac
  [ -n "$artifact_name" ] || _download_run_artifact_die "ARTIFACT_NAME must not be empty"
  [ -n "$repo" ] || _download_run_artifact_die "GITHUB_REPOSITORY must be set"
  [ -n "$_download_run_artifact_token" ] || _download_run_artifact_die "GH_TOKEN or GITHUB_TOKEN must be set"
  _download_run_artifact_require_uint ARTIFACT_DOWNLOAD_ATTEMPTS "$attempts"
  _download_run_artifact_require_uint ARTIFACT_DOWNLOAD_RETRY_DELAY "$delay"
  _download_run_artifact_require_uint ARTIFACT_DOWNLOAD_SPEED_LIMIT "$speed_limit"
  _download_run_artifact_require_uint ARTIFACT_DOWNLOAD_SPEED_TIME "$speed_time"
  [ "$attempts" -gt 0 ] || _download_run_artifact_die "ARTIFACT_DOWNLOAD_ATTEMPTS must be at least 1"

  _download_run_artifact_require_cmd curl
  _download_run_artifact_require_cmd jq
  _download_run_artifact_require_cmd python3

  encoded_name="$(jq -rn --arg value "$artifact_name" '$value | @uri')"
  artifact_json="$(
    _download_run_artifact_api \
      "$api_url/repos/$repo/actions/runs/$run_id/artifacts?name=$encoded_name&per_page=100"
  )"
  matches="$(
    jq -c --arg name "$artifact_name" \
      '[.artifacts[]? | select(.name == $name and (.expired | not))]' <<< "$artifact_json"
  )"
  case "$(jq 'length' <<< "$matches")" in
    1) ;;
    0) _download_run_artifact_die "run $run_id has no unexpired artifact named $artifact_name" ;;
    *) _download_run_artifact_die "run $run_id has more than one artifact named $artifact_name" ;;
  esac
  artifact_id="$(jq -r '.[0].id' <<< "$matches")"
  size="$(jq -r '.[0].size_in_bytes' <<< "$matches")"
  digest="$(jq -r '.[0].digest // ""' <<< "$matches")"

  mkdir -p "$dest_dir"
  _download_run_artifact_zip="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/artifact-$artifact_id.zip"
  rm -f "$_download_run_artifact_zip"
  trap _download_run_artifact_cleanup EXIT

  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if [ "$attempt" -gt 1 ]; then
      sleep "$delay"
      delay=$((delay * 2 > 60 ? 60 : delay * 2))
    fi

    # The API answers with a short-lived signed blob URL. Resolve a fresh one
    # for every attempt and never send the token to the blob host.
    if ! blob_url="$(
      _download_run_artifact_api --output /dev/null --write-out '%{redirect_url}' \
        "$api_url/repos/$repo/actions/artifacts/$artifact_id/zip"
    )" || [ -z "$blob_url" ]; then
      printf 'warning: attempt %s/%s could not resolve the download URL\n' "$attempt" "$attempts" >&2
      continue
    fi

    have="$(_download_run_artifact_file_size "$_download_run_artifact_zip")"
    _download_run_artifact_log "Attempt $attempt/$attempts: downloading $artifact_name ($artifact_id) from byte $have of $size"
    status=0
    http_code="$(
      curl --fail --silent --show-error --location \
        --connect-timeout 30 \
        --speed-limit "$speed_limit" --speed-time "$speed_time" \
        --continue-at - \
        --output "$_download_run_artifact_zip" \
        --write-out '%{http_code}' \
        "$blob_url"
    )" || status=$?

    # 416 means the zip on disk already covers the whole range.
    if [ "$status" -eq 0 ] || [ "$http_code" = 416 ]; then
      if _download_run_artifact_verify "$digest"; then
        _download_run_artifact_log "Extracting $artifact_name into $dest_dir"
        python3 -m zipfile -e "$_download_run_artifact_zip" "$dest_dir"
        return 0
      fi
      rm -f "$_download_run_artifact_zip"
      continue
    fi

    # 33 means the server ignored the range request, so the partial zip is useless.
    if [ "$status" -eq 33 ]; then
      rm -f "$_download_run_artifact_zip"
    fi
    printf 'warning: attempt %s/%s failed with curl exit %s (HTTP %s) at byte %s\n' \
      "$attempt" "$attempts" "$status" "${http_code:-000}" \
      "$(_download_run_artifact_file_size "$_download_run_artifact_zip")" >&2
  done

  _download_run_artifact_die "could not download $artifact_name from run $run_id after $attempts attempts"
}

_download_run_artifact_main "$@"
