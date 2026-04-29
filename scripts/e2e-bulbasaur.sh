#!/usr/bin/env sh
set -eu
cd "$(dirname "$0")/.."
exec rebar3 as genesis_wasm shell --apps hackney --eval 'case catch bulbasaur_e2e:run() of ok -> init:stop(); {'\''EXIT'\'', Reason} -> io:format("~p~n", [Reason]), init:stop(1); Error -> io:format("~p~n", [Error]), init:stop(1) end.'
