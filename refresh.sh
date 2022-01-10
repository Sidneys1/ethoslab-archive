#!/usr/bin/env bash

set -eu -o pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)

STDOUT="$(mktemp)"

function debug() (echo "debug | $*")
function info() (echo " info | $*")
function error() (echo "error | $*")

ARCHIVE_DIR="/home/ipfs/etho/"
debug "ARCHIVE_DIR=${ARCHIVE_DIR}"

function yt_dlp() (
  debug $'\t\t' \
    yt-dlp \
    --no-overwrites \
    --merge-output-format mp4 \
    --download-archive archive.txt \
    --output '%(playlist_index)s-%(title)s-%(id)s.%(ext)s' \
    --external-downloader aria2c \
    --external-downloader-args "--console-log-level=error -j15 -x15 -k1M -m10 --lowest-speed-limit=400K --max-overall-download-limit=10M --console-log-level=error --summary-interval=0" \
    "$1" 2>&1 | tee "${STDOUT}"
  return $?
)

function download_series() (
  PLAYLIST_NAME="$1"
  PLAYLIST_URL="$2"

  FOLDER="${ARCHIVE_DIR}/${PLAYLIST_NAME}"
  (# New subshell to protect CWD
    cd "${FOLDER}" || (
      error "Failed to enter series folder '$FOLDER'."
      return 1
    )
    declare -i RETRIES=0
    until yt_dlp "${PLAYLIST_URL}"; do
      error "yt-dlp failed with exit code ${?}. Retrying."
      ((RETRIES++))
      if [ "${RETRIES}" -gt 5 ]; then
        error "Too many retries."
        return 1
      fi
      sleep 1
    done
  )
)

function get_new_series() (
  PLAYLIST_NAME="$(cut -d'/' -f1 <<<"$1")"
  info "New series: '${PLAYLIST_NAME}'!"

  # Let's get the URL:
  INFO_FILE="$(find "${PLAYLIST_NAME}" -type f -name "0-*.info.json" | head -1)"
  PLAYLIST_URL="$(jq -r .webpage_url "${INFO_FILE}")"
  debug $'\t'"Webpage: ${PLAYLIST_URL}"

  ARCHIVE_FOLDER="${ARCHIVE_DIR}/${PLAYLIST_NAME}"
  debug $'\t'"Making folder ${ARCHIVE_FOLDER}"
  mkdir -p "${ARCHIVE_FOLDER}"
  info "Downloading series..."
  if ! download_series "${PLAYLIST_NAME}" "${PLAYLIST_URL}"; then
    error "Failed to download series."
    return 1
  fi

  (
    cd "${ARCHIVE_DIR}" || (
      error "Failed to enter series folder '$ARCHIVE_DIR'."
      return 1
    )

    # debug "Stopping IPFSd...";
    # sudo service ipfs stop;

    info "Adding file to IPFS."
    ipfs add -t -r -s=size-1048576 --pin --nocopy "$PLAYLIST_NAME"/ | tee "${STDOUT}"

    # debug "Starting IPFSd...";
    # sudo service ipfs start;
    # termdown 60 -T "Wait for IPFSd to start..." --no-figlet;

    IPFS="$(tac "${STDOUT}" | grep -oPm1 'added \K(\w+)')"
    ipfs pin add "${IPFS}"

    ipfs files cp "/ipfs/${IPFS}" "/etho/${PLAYLIST_NAME}"
  )

  info "Tracking file in Git."
  git add "${PLAYLIST_NAME}/"
  git commit -m "Added new playlist '${PLAYLIST_NAME}'."
)

function get_new_episodes() (
  PLAYLIST_NAME="$(cut -d'/' -f1 <<<"$1")"
  shift
  info "New episodes of existing series: '${PLAYLIST_NAME}'"
  VIDEOS=("$@")
  for EPISODE in "${VIDEOS[@]}"; do
    info $'\t'"* ${EPISODE}"
    # debug $'\t\t'"* ${EPISODE//.info.json/.mp4}"
  done

  # Let's get the URL:
  INFO_FILE="$(find "${PLAYLIST_NAME}" -type f -name "0-*.info.json" | head -1)"
  PLAYLIST_URL="$(jq -r .webpage_url "${INFO_FILE}")"
  debug $'\t'"Webpage: ${PLAYLIST_URL}"

  ARCHIVE_FOLDER="${ARCHIVE_DIR}/${PLAYLIST_NAME}"
  if ! download_series "${PLAYLIST_NAME}" "${PLAYLIST_URL}"; then
    error "Failed to download series."
    return 1
  fi
)

(# Subshell so we can ensure we're in the correct location.
  cd "${SCRIPT_DIR}" || (
    error "Failed to enter directory ''."
    exit 1
  )

  info "Refreshing playlists..."
  if ! yt-dlp --no-download --write-info-json -o "%(playlist)s/%(playlist_index)s-%(title)s-%(id)s.%(ext)s" --download-archive all.txt --force-download-archive 'https://www.youtube.com/channel/UC8myOLsYDH1vqYtjFhimrqQ/playlists' 2>&1 | tee "${STDOUT}"; then
    error "An error occurred: yt-dlp exited with ${?}. See '${STDOUT}' for more info. tail of output:"
    tail "${STDOUT}"
    exit 1
  fi

  info "Checking for untracked files..."

  ANY=false
  NEW_EPISODES=()
  CURRENT_SERIES=""
  while IFS= read -r -d $'\0' CHANGE; do
    if [[ "$CHANGE" != \?\?* ]]; then continue; fi
    CHANGE_PATH="$(cut -d' ' -f2- <<<"${CHANGE}")"
    # echo "DEBUG: |${CHANGE_PATH}|"
    if [[ "${CHANGE_PATH}" == */ ]]; then
      get_new_series "${CHANGE_PATH}"
      ANY=true
    else
      SERIES_NAME="$(cut -d'/' -f1 <<<"${CHANGE_PATH}")"
      if [ "${CURRENT_SERIES}" != "${SERIES_NAME}" ]; then
        if [ ${#NEW_EPISODES[@]} -gt 0 ]; then
          # echo "New episodes of ${CURRENT_SERIES}: ${NEW_EPISODES[*]}";
          get_new_episodes "${CURRENT_SERIES}" "${NEW_EPISODES[@]}"
          ANY=true
        fi
        NEW_EPISODES=()
        CURRENT_SERIES="${SERIES_NAME}"
      fi
      EPISODE="$(cut -d'/' -f2- <<<"${CHANGE_PATH}")"
      NEW_EPISODES+=("${EPISODE}")
    fi
  done < <(git status -z | sort -z)

  if [ ${#NEW_EPISODES[@]} -gt 0 ]; then
    get_new_episodes "${CURRENT_SERIES}" "${NEW_EPISODES[@]}"
    ANY=true
  fi

  if $ANY; then
    git add all.txt
    git commit -m 'Updating all.txt.'
    ipfs name publish -k etho "$(ipfs files ls -l | grep -m1 'etho/' | cut -f2)" || (
      echo "Failed to 'ipfs name publish ...'."
      exit 1
    )
  fi
)
