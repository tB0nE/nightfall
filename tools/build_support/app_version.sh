#!/usr/bin/env bash
# Works out the Android versionName and versionCode for a build kind, from
# the release tags (vMAJOR.MINOR.PATCH). Sourced by build_android.sh.
#
#   release  The version being released: NIGHTFALL_VERSION if set, else the
#            tag on HEAD. Refuses to guess, since a release's code must be
#            higher than every earlier one.
#   dev      The last release's code, so dev builds always replace each other
#            and the release they follow, and the next release replaces them.
#            The name says which commit it is: 0.7.11-dev+60fffb1.
#   debug    As dev, named 0.7.11-debug+60fffb1.
#
# versionCode is MAJOR*1000000 + MINOR*10000 + PATCH*100 + BUILD (0.9.1 ->
# 90100), so MINOR, PATCH and BUILD must stay below 100. BUILD (default 0)
# lets the same version be uploaded to the Meta store again: every upload needs
# a higher code. Codes before 0.9.1 used MAJOR*10000 + MINOR*100 + PATCH (901
# at most), so every new code is higher than every old one.
#
#   nightfall_version_code VERSION [BUILD]

nightfall_version_code() {
  local major minor patch build="${2:-0}"
  if [[ ! "$build" =~ ^[0-9]{1,2}$ ]]; then
    echo "Error: build number '$build' must be 0-99" >&2
    return 1
  fi
  if [[ ! "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]]; then
    echo "Error: invalid version '$1'" >&2
    return 1
  fi
  # Preview and stable APKs share a numeric code for in-place updates.
  IFS=. read -r major minor patch <<<"${1%%-*}"
  if [[ ! "$major" =~ ^[0-9]+$ || ! "$minor" =~ ^[0-9]+$ || ! "$patch" =~ ^[0-9]+$ ]] \
      || ((10#$minor > 99 || 10#$patch > 99)); then
    echo "Error: version '$1' is not MAJOR.MINOR.PATCH with MINOR and PATCH below 100" >&2
    return 1
  fi
  echo $((10#$major * 1000000 + 10#$minor * 10000 + 10#$patch * 100 + 10#$build))
}

# Sets NIGHTFALL_VERSION_NAME and NIGHTFALL_VERSION_CODE. Release builds take
# their build number from NIGHTFALL_BUILD_NUMBER (default 0); dev and debug
# builds always use 0.
nightfall_resolve_version() {
  local kind="$1" root="$2" version suffix
  case "$kind" in
    release)
      version="${NIGHTFALL_VERSION:-}"
      if [[ -z "$version" ]]; then
        version="$(git -C "$root" describe --tags --exact-match --match 'v[0-9]*' HEAD 2>/dev/null || true)"
      fi
      version="${version#v}"
      if [[ -z "$version" ]]; then
        echo "Error: a release build needs its version: tag HEAD (git tag v0.7.12) or pass --version 0.7.12." >&2
        echo "For testing, use ./build.sh --dev instead." >&2
        return 1
      fi
      NIGHTFALL_VERSION_NAME="$version"
      ;;
    dev | debug)
      version="$(git -C "$root" describe --tags --abbrev=0 --match 'v[0-9]*' HEAD 2>/dev/null || echo v0.0.0)"
      version="${version#v}"
      suffix="$(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo unknown)"
      if ! git -C "$root" diff --quiet HEAD -- 2>/dev/null; then
        suffix+="-dirty"
      fi
      NIGHTFALL_VERSION_NAME="$version-$kind+$suffix"
      ;;
    *)
      echo "Error: unknown build kind '$kind'" >&2
      return 1
      ;;
  esac
  local build=0
  if [[ "$kind" == release ]]; then
    build="${NIGHTFALL_BUILD_NUMBER:-0}"
  fi
  NIGHTFALL_VERSION_CODE="$(nightfall_version_code "$version" "$build")" || return 1
}
