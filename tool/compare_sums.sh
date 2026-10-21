#!/usr/bin/env bash
# Compares the SHA256SUMS files that different hosts produced for the same
# targets. Every path that appears in more than one file must have the same
# hash. Usage:
#
#   compare_sums.sh <directory containing <host>/SHA256SUMS...>
#
# Exits non-zero on any mismatch. Paths present on a single host only are
# listed but cannot be compared.
set -euo pipefail

root=${1:?usage: compare_sums.sh <artifacts-dir>}
combined=$(mktemp)
trap 'rm -f "$combined"' EXIT

# The host label is the first directory under the root, whatever the depth
# the files were extracted at.
root=${root%/}
while IFS= read -r sums; do
  host=${sums#"$root"/}
  host=${host%%/*}
  awk -v host="$host" 'NF == 2 { print $2 "\t" $1 "\t" host }' "$sums"
done < <(find "$root" -type f -name 'SHA256SUMS*' | sort) | sort > "$combined"

if [ ! -s "$combined" ]; then
  echo "No SHA256SUMS files found under $root" >&2
  exit 2
fi

awk -F'\t' '
  {
    path = $1; hash = $2; host = $3
    if (!(path in hosts)) order[++count] = path
    hosts[path] = hosts[path] " " host
    if (index(hashes[path], hash) == 0) { hashes[path] = hashes[path] " " hash; distinct[path]++ }
  }
  END {
    bad = 0
    for (i = 1; i <= count; i++) {
      path = order[i]
      if (distinct[path] > 1) {
        bad = 1
        printf "MISMATCH %s\n    hosts:%s\n    hashes:%s\n", path, hosts[path], hashes[path]
      } else if (split(hosts[path], parts, " ") > 1) {
        printf "MATCH    %s  %s  (%s hosts:%s)\n", substr(hashes[path], 2, 16), path, split(hosts[path], parts, " "), hosts[path]
      } else {
        printf "single   %s  %s  (host:%s)\n", substr(hashes[path], 2, 16), path, hosts[path]
      }
    }
    exit bad
  }
' "$combined"
