#!/usr/bin/env bash


yt-dlp --no-download --write-info-json -o "%(playlist)s/%(playlist_index)s-%(title)s-%(id)s.%(ext)s" --download-archive all.txt --force-download-archive 'https://www.youtube.com/channel/UC8myOLsYDH1vqYtjFhimrqQ/playlists'
