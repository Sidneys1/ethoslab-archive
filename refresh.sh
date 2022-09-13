#!/usr/bin/env bash

set -eu

BLUE=$(echo -ne "\e[36m")
RED=$(echo -ne "\e[91m")
DGREEN=$(echo -ne "\e[32m")
DIM=$(echo -ne "\e[90m")
# REVERSE=$(echo -ne "\e[7m")
RESET=$(echo -ne "\e[0m")
ITALIC=$(echo -ne "\e[3m")
CLEAR_TO_END_OF_LINE=$(echo -ne "\e[J")

WIDTH=$(tput cols)

IN_PREFIX="   ${BLUE}info${RESET} │ "
DE_PREFIX="  ${DIM}${ITALIC}debug${RESET} │ "
ER_PREFIX="  ${RED}error${RESET} │ "

# Establish the location of our current script.
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)

# Create a temp file for holding subcommand output
STDOUT="$(mktemp)"

# Debug (verbose output) enabled?
DEBUG=false
# Whether to refresh the list of all videos.
REFRESH_PLAYLISTS=true

# Handle command-line.
while [ $# -gt 0 ]; do
  case $1 in
  "-v" | "--verbose")
    DEBUG=true
    shift
    ;;
  "--no-refresh-playlists")
    REFRESH_PLAYLISTS=false
    shift
    ;;
  *)
    echo "Unknown parameter: '$1'."
    exit 1
    ;;
  esac
done

# Functions to handle logging and subcommand output.
subcommand() (if $DEBUG; then tee "$1"; else cat >"$1"; fi)
debug() (if $DEBUG; then echo "${DE_PREFIX}${DIM}${ITALIC}$*${RESET}" 1>&2; fi)
error() (echo "${ER_PREFIX}$*" 1>&2)
info() (echo "${IN_PREFIX}$*" 1>&2)

single-line() (
  if $DEBUG; then
    xargs -L1 -I '{}' -d$'\n' echo -ne "$1{}\n"
  else
    sed -uE "s/(.{$((WIDTH - (${#1} + 10)))}).*$/\1.../" \
      | sed -uE '/^[[:space:]]*$/d' \
      | xargs --no-run-if-empty -L1 -I '{}' -d$'\n' echo -ne "\r$1{}${RESET}${CLEAR_TO_END_OF_LINE}" \
      && echo
  fi
)

# Make sure we know where the IPFS archive is stored.
ARCHIVE_DIR="/home/ipfs/etho/"
debug "ARCHIVE_DIR=${ARCHIVE_DIR}"

yt_dlp() (
#  debug $'\t\t' \
    yt-dlp \
    --no-overwrites \
    --merge-output-format mp4 \
    --download-archive archive.txt \
    --output '%(playlist_index)s-%(title)s-%(id)s.%(ext)s' \
    --external-downloader aria2c \
    --external-downloader-args "--console-log-level=error -j15 -x15 -k1M -m10 --max-overall-download-limit=10M --console-log-level=error --summary-interval=1" \
    "$1" 2>&1 \
      | tee "${STDOUT}" \
      | single-line " ${DGREEN}yt-dlp${RESET} │ "
  return $?
)

download_series() (
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

get_new_series() (
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
    ipfs add -t -r -s=size-1048576 --pin --nocopy "${PLAYLIST_NAME}"/ \
      | tee "${STDOUT}"

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

get_new_episodes() (
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

  (
    cd "${ARCHIVE_DIR}" || (
      error "Failed to enter series folder '$ARCHIVE_DIR'."
      return 1
    )

    for VIDEO in "${VIDEOS[@]}"; do
      MP4="${VIDEO//.info.json/.mp4}"

      info "Adding file '${MP4}' to IPFS."
      ipfs add -t -r -s=size-1048576 --pin --nocopy "${PLAYLIST_NAME}/${MP4}" \
        | tee "${STDOUT}"

      IPFS="$(tac "${STDOUT}" | grep -oPm1 'added \K(\w+)')"
      ipfs pin add "${IPFS}"
      ipfs files cp "/ipfs/${IPFS}" "/etho/${PLAYLIST_NAME}/${MP4}"

      (
        cd "${SCRIPT_DIR}"
        info "Tracking file in Git."
        git add "${PLAYLIST_NAME}/${VIDEO}"
      )
    done

    info "Adding file 'archive.txt' to IPFS."
    ipfs add -t -r -s=size-1048576 --pin --nocopy "${PLAYLIST_NAME}/archive.txt" \
      | tee "${STDOUT}"

    IPFS="$(tac "${STDOUT}" | grep -oPm1 'added \K(\w+)')"
    ipfs pin add "${IPFS}"
    ipfs files rm "/etho/${PLAYLIST_NAME}/archive.txt" \
      && ipfs files cp "/ipfs/${IPFS}" "/etho/${PLAYLIST_NAME}/archive.txt"
  )

  git commit -m "Added ${#VIDEOS[@]} new videos to playlist '${PLAYLIST_NAME}'."
)

(# Subshell so we can ensure we're in the correct location.
  cd "${SCRIPT_DIR}" || (
    error "Failed to enter directory ''."
    exit 1
  )

  if $REFRESH_PLAYLISTS; then
    info "Refreshing playlists..."
    if ! yt-dlp \
        --no-download \
        --write-info-json \
        --output "%(playlist)s/%(playlist_index)s-%(title)s-%(id)s.%(ext)s" \
        --download-archive all.txt \
        --force-download-archive \
        'https://www.youtube.com/channel/UC8myOLsYDH1vqYtjFhimrqQ/playlists' 2>&1 | tee "${STDOUT}" | single-line " ${DGREEN}yt-dlp${RESET} │ "; then
      error "An error occurred: yt-dlp exited with ${?}. See '${STDOUT}' for more info. tail of output:"
      tail "${STDOUT}"
      exit 1
    fi
  fi

  info "Checking for untracked files..."

  ANY=false
  NEW_EPISODES=()
  CURRENT_SERIES=""
  while IFS= read -r -d $'\0' CHANGE; do
    if [[ "$CHANGE" != \?\?* ]]; then continue; fi
    CHANGE_PATH="$(cut -d' ' -f2- <<<"${CHANGE}")"
    if [[ "${CHANGE_PATH}" == */ ]]; then
      get_new_series "${CHANGE_PATH}"
      ANY=true
    else
      SERIES_NAME="$(cut -d'/' -f1 <<<"${CHANGE_PATH}")"
      if [ "${CURRENT_SERIES}" != "${SERIES_NAME}" ]; then
        if [ ${#NEW_EPISODES[@]} -gt 0 ]; then
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
    git push
    ipfs name publish -k etho "$(ipfs files ls -l | grep -m1 'etho/' | cut -f2)" || (
      echo "Failed to 'ipfs name publish ...'."
      exit 1
    )
  else
    info "No new videos found."
  fi
)
