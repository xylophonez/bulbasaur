#!/usr/bin/env sh
set -eu
cd "$(dirname "$0")/.."
exec rebar3 shell --apps hackney --eval 'file:script("scripts/start-bulbasaur.erl").'
