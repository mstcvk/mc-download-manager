#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test_build=$(mktemp -d)
trap 'rm -rf "$test_build"' EXIT
swiftc App/Sources/DownloadManager/Models/Models.swift \
  App/Sources/DownloadManager/Engine/TorrentDownloader.swift tests/torrent/main.swift \
  -o "$test_build/test-torrent"
"$test_build/test-torrent"
set -- App/Sources/DownloadManager/App.swift
for source in App/Sources/DownloadManager/*/*.swift; do
  case "$source" in */DownloadDetailView.swift) continue ;; esac
  set -- "$@" "$source"
done
swiftc -swift-version 5 -target "$(uname -m)-apple-macos13.0" "$@" \
  tests/torrent-store/main.swift -o "$test_build/test-torrent-store"
"$test_build/test-torrent-store"
