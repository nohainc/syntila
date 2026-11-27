#!/usr/bin/env bash
# Verify that Pages serves the exact signed repository we just built.
verify_apt_publication() {
  local base="$1" repo="$2" version="$3" attempt path arch local_hash remote_hash matched
  for attempt in $(seq 1 24); do
    matched=1
    for path in dists/stable/Release dists/stable/InRelease dists/stable/main/binary-amd64/Packages dists/stable/main/binary-arm64/Packages; do
      local_hash=$(shasum -a 256 "$repo/$path" | awk '{print $1}') || return 1
      remote_hash=$(curl -fsSL --max-time 10 -H 'Cache-Control: no-cache' "$base/$path" | shasum -a 256 | awk '{print $1}') || { matched=0; break; }
      [ "$local_hash" = "$remote_hash" ] || { matched=0; break; }
    done
    if [ "$matched" = 1 ]; then
      for arch in amd64 arm64; do
        path="pool/main/s/syntila-connect/syntila-connect_${version}_${arch}.deb"
        local_hash=$(shasum -a 256 "$repo/$path" | awk '{print $1}') || return 1
        remote_hash=$(curl -fsSL --max-time 30 -H 'Cache-Control: no-cache' "$base/$path" | shasum -a 256 | awk '{print $1}') || return 1
        [ "$local_hash" = "$remote_hash" ] || { echo "Published package checksum mismatch: $path" >&2; return 1; }
      done
      echo "Verified signed APT indexes and Connect $version packages at $base"
      return 0
    fi
    [ "$attempt" = 24 ] || sleep 5
  done
  echo "APT branch was pushed, but Pages did not serve the new signed indexes at $base within two minutes. Check Pages deployment and retry the publish." >&2
  return 1
}
