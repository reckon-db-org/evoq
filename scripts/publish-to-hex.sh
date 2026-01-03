#!/usr/bin/env bash
set -euo pipefail

# Publish evoq to hex.pm
# Usage: ./scripts/publish-to-hex.sh

cd "$(dirname "$0")/.."

echo "==> Building evoq..."
rebar3 compile

echo "==> Running tests..."
rebar3 eunit

echo "==> Building docs..."
rebar3 ex_doc

echo "==> Publishing to hex.pm..."
rebar3 hex publish

echo "==> Done! evoq published to hex.pm"
