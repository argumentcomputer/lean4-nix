#!/usr/bin/env bash

set -euo pipefail

VERSION=${1:-}
LABEL_VERSION=${2:-}

if [ -z "$VERSION" ]; then
	echo "Usage: toolchain-fetch VERSION [LABEL_VERSION]" >&2
	echo "  LABEL_VERSION addresses upstream tag mismatches (e.g. v4.20.1 ships lean-4.20.0-* assets)" >&2
	exit 1
fi

DATA=${TOOLCHAINS_JSON:-data/toolchains.json}

if [ ! -f "$DATA" ]; then
	echo "$DATA not found; run from the repository root or set TOOLCHAINS_JSON" >&2
	exit 1
fi

declare -A targets=(
	[x86_64-linux]=linux
	[aarch64-linux]=linux_aarch64
	[x86_64-darwin]=darwin
	[aarch64-darwin]=darwin_aarch64
)

entry="{}"

for target in "${!targets[@]}"; do
	target_name=${targets[$target]}
	url=https://github.com/leanprover/lean4/releases/download/v$VERSION/lean-${LABEL_VERSION:-$VERSION}-$target_name.tar.zst
	hash=$(nix --extra-experimental-features nix-command store prefetch-file \
		--json --hash-type sha256 "$url" | jq -r '.hash')
	# The URL is only recorded when it cannot be derived from the tag, keeping
	# the common case terse.
	if [ -n "$LABEL_VERSION" ]; then
		entry=$(jq --arg t "$target" --arg h "$hash" --arg u "$url" \
			'.[$t] = {hash: $h, url: $u}' <<<"$entry")
	else
		entry=$(jq --arg t "$target" --arg h "$hash" \
			'.[$t] = {hash: $h}' <<<"$entry")
	fi
done

tmp=$(mktemp)
jq -S --arg tag "v$VERSION" --argjson entry "$entry" \
	'.[$tag] = $entry' "$DATA" >"$tmp"
mv "$tmp" "$DATA"

echo "Wrote v$VERSION to $DATA"
