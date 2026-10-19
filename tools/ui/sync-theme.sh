#!/usr/bin/env bash
# Vendors the ACTIVATE platform's theme contract into a workflow app's web directory:
# the generated --theme-* tokens of @parallelworks/ui (github.com/parallelworks/foundation,
# packages/ui) and the Geist fonts the platform renders with. The app's own stylesheet
# then reads only those tokens, so it looks like the platform in light and dark.
#
#   bash tools/ui/sync-theme.sh workflows/<name>/app/web            # @parallelworks/ui at the pinned version
#   bash tools/ui/sync-theme.sh -v 0.70.0 workflows/<name>/app/web  # another version, or "latest"
#   bash tools/ui/sync-theme.sh -s ../foundation/packages/ui/src/styles workflows/<name>/app/web
#                                                                   # a local checkout of the foundation repo
#
# Writes theme.css (the token block only; the file's Tailwind utilities need a build),
# fonts.css and the two variable woff2 files into the directory. Idempotent.
set -euo pipefail

VERSION="0.68.0"
SOURCE=""
while getopts "v:s:h" opt; do
  case "${opt}" in
    v) VERSION="${OPTARG}" ;;
    s) SOURCE="${OPTARG}" ;;
    *) sed -n '2,13p' "$0"; exit 2 ;;
  esac
done
shift $((OPTIND - 1))
DEST="${1:-}"
if [ -z "${DEST}" ]; then
  sed -n '2,13p' "$0"
  exit 2
fi
mkdir -p "${DEST}"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

if [ -z "${SOURCE}" ]; then
  if [ "${VERSION}" = latest ]; then
    VERSION="$(curl -fsSL https://registry.npmjs.org/@parallelworks/ui/latest | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')"
    [ -n "${VERSION}" ] || { echo "could not resolve the latest version" >&2; exit 1; }
  fi
  echo "fetching @parallelworks/ui@${VERSION}"
  curl -fsSL "https://registry.npmjs.org/@parallelworks/ui/-/ui-${VERSION}.tgz" -o "${WORK}/ui.tgz"
  tar -xzf "${WORK}/ui.tgz" -C "${WORK}" package/dist/styles
  SOURCE="${WORK}/package/dist/styles"
  ORIGIN="@parallelworks/ui ${VERSION} (npm)"
else
  ORIGIN="@parallelworks/ui from ${SOURCE}"
  if [ -f "${SOURCE}/../../package.json" ]; then
    ORIGIN="@parallelworks/ui $(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "${SOURCE}/../../package.json" | head -1) (${SOURCE})"
  fi
fi

for f in theme.css fonts.css Geist-Variable.woff2 GeistMono-Variable.woff2; do
  [ -f "${SOURCE}/${f}" ] || { echo "missing ${SOURCE}/${f}" >&2; exit 1; }
done

{
  cat <<HEADER
/* The platform's theme contract: every color is one of these --theme-* tokens, generated
 * by @parallelworks/ui (github.com/parallelworks/foundation, packages/ui) from the default
 * theme's light and dark seeds. Each token pairs its modes with light-dark(), so it follows
 * the color-scheme the page sets. Do not edit: tools/ui/sync-theme.sh rewrites this file.
 * Source: ${ORIGIN}. */
HEADER
  sed -n '/generated:start/,/generated:end/p' "${SOURCE}/theme.css" | sed '1d;$d'
} > "${DEST}/theme.css"
cp "${SOURCE}/fonts.css" "${DEST}/fonts.css"
cp "${SOURCE}/Geist-Variable.woff2" "${SOURCE}/GeistMono-Variable.woff2" "${DEST}/"
echo "theme contract written to ${DEST} from ${ORIGIN}"
ls -la "${DEST}/theme.css" "${DEST}/fonts.css" "${DEST}/Geist-Variable.woff2" "${DEST}/GeistMono-Variable.woff2"
