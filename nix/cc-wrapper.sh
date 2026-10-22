#!/usr/bin/env bash
# Runs a compiler for the build with two adjustments that keep what the
# compiler records independent of the host. The flags that name build
# directories (path remaps, SDK overlays) arrive through DNIX_CC_ARGS, one
# per line, instead of CFLAGS, so a build that copies its C flags into the
# output (OpenSSL's build info, for one) copies nothing host-specific. And
# a -D macro (or cl's /D) whose value mentions DNIX_BUILD_ROOT is
# rewritten to say /build, which is what the Linux sandbox calls that directory, so an
# install prefix compiled into a library is the same everywhere.
#
#   cc-wrapper.sh <compiler> [fixed arguments...] -- [arguments...]
set -u
command=()
while [ $# -gt 0 ]; do
  if [ "$1" = -- ]; then shift; break; fi
  command+=("$1")
  shift
done
# A `--` from the caller ends the options (the cc crate puts one before the
# source file for clang-cl); the added flags go before it.
arguments=()
inputs=()
ended=
for argument in "$@"; do
  if [ -n "$ended" ]; then inputs+=("$argument"); continue; fi
  case "$argument" in
    --) ended=1; continue ;;
    -D*|/D*) if [ -n "${DNIX_BUILD_ROOT:-}" ]; then argument=${argument//"$DNIX_BUILD_ROOT"//build}; fi ;;
  esac
  arguments+=("$argument")
done
if [ -n "${DNIX_CC_ARGS:-}" ]; then
  while IFS= read -r line; do
    if [ -n "$line" ]; then arguments+=("$line"); fi
  done <<< "$DNIX_CC_ARGS"
fi
if [ -n "$ended" ]; then arguments+=(-- ${inputs[@]+"${inputs[@]}"}); fi
exec "${command[@]}" ${arguments[@]+"${arguments[@]}"}
