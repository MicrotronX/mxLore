#!/bin/bash
# Build mxLore release ZIP
# Usage: bash build-release.sh [version]
# Example: bash build-release.sh 2.2.1

VERSION=${1:-"2.4.0"}
BASENAME="mxLore-v${VERSION}-win64"
OUTDIR="release/${BASENAME}"
ZIPFILE="release/${BASENAME}.zip"
SRCDIR="$(cd "$(dirname "$0")" && pwd)"

echo "Building ${BASENAME}..."

# Clean
rm -rf "release/${BASENAME}" "${ZIPFILE}"
mkdir -p "${OUTDIR}/sql" "${OUTDIR}/admin/www/js" "${OUTDIR}/admin/www/css" "${OUTDIR}/lib" "${OUTDIR}/claude-setup/proxy"

# Server EXEs
cp "${SRCDIR}/mxLoreMCP.exe"     "${OUTDIR}/"
cp "${SRCDIR}/mxLoreMCPGui.exe"  "${OUTDIR}/"

# Proxy
cp "${SRCDIR}/claude-setup/proxy/mxMCPProxy.exe" "${OUTDIR}/"

# Config
cp "${SRCDIR}/mxLoreMCP.ini.example" "${OUTDIR}/"

# SQL
cp "${SRCDIR}/sql/setup.sql" "${OUTDIR}/sql/"
cp "${SRCDIR}/sql/043-embedding-vector.sql" "${OUTDIR}/sql/"
cp "${SRCDIR}/sql/044-tool-call-log.sql" "${OUTDIR}/sql/"

# Admin UI
cp "${SRCDIR}/admin/www/index.html"    "${OUTDIR}/admin/www/"
cp "${SRCDIR}/admin/www/connect.html"  "${OUTDIR}/admin/www/"
cp "${SRCDIR}/admin/www/css/style.css"   "${OUTDIR}/admin/www/css/"
cp "${SRCDIR}/admin/www/css/connect.css" "${OUTDIR}/admin/www/css/"
cp "${SRCDIR}/admin/www/js/app.js"     "${OUTDIR}/admin/www/js/"
cp "${SRCDIR}/admin/www/js/api.js"     "${OUTDIR}/admin/www/js/"
cp "${SRCDIR}/admin/www/js/icons.js"   "${OUTDIR}/admin/www/js/"
cp "${SRCDIR}/admin/www/js/connect.js" "${OUTDIR}/admin/www/js/"

# claude-setup (skills, hooks, reference — served by mx_onboard_developer)
cp -r "${SRCDIR}/claude-setup/skills" "${OUTDIR}/claude-setup/skills"
cp -r "${SRCDIR}/claude-setup/hooks" "${OUTDIR}/claude-setup/hooks"
cp -r "${SRCDIR}/claude-setup/reference" "${OUTDIR}/claude-setup/reference"
cp "${SRCDIR}/claude-setup/proxy/mxMCPProxy.ini" "${OUTDIR}/claude-setup/proxy/mxMCPProxy.ini"
cp "${SRCDIR}/claude-setup/CLAUDE.md" "${OUTDIR}/claude-setup/CLAUDE.md"
# Remove any EXEs that slipped in
find "${OUTDIR}/claude-setup" -name "*.exe" -delete 2>/dev/null

# Docs
cp "${SRCDIR}/LICENSE.txt" "${OUTDIR}/"
cp "${SRCDIR}/README.md"   "${OUTDIR}/"
mkdir -p "${OUTDIR}/docs"
cp "${SRCDIR}/docs/installation.md"    "${OUTDIR}/docs/"
cp "${SRCDIR}/docs/troubleshooting.md" "${OUTDIR}/docs/"
cp "${SRCDIR}/docs/team-onboarding.md" "${OUTDIR}/docs/"

# IIS reverse proxy config (optional, for WAN deployments)
cp "${SRCDIR}/iis-url-rewrite-rule.xml" "${OUTDIR}/"

# Note: libmariadb32.dll is NOT bundled (LGPL).
# The server auto-detects it from your MariaDB installation.
# If auto-detection fails, copy lib/libmariadb32.dll from your MariaDB to lib/.

echo ""
echo "Release directory: ${OUTDIR}"
echo ""
echo "Contents:"
find "${OUTDIR}" -type f | sort | while read f; do
  size=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null)
  echo "  $(echo "$f" | sed "s|${OUTDIR}/||")  (${size} bytes)"
done

# Create ZIP
if command -v 7z &>/dev/null; then
  cd release && 7z a -tzip "../${ZIPFILE}" "${BASENAME}" && cd ..
  echo ""
  echo "ZIP created: ${ZIPFILE}"
elif command -v zip &>/dev/null; then
  cd release && zip -r "../${ZIPFILE}" "${BASENAME}" && cd ..
  echo ""
  echo "ZIP created: ${ZIPFILE}"
else
  echo ""
  echo "No zip tool found. Manual ZIP: compress release/${BASENAME}/"
  echo "Tools: 7z, zip, or Windows Explorer right-click > Send to > Compressed folder"
fi

echo ""
echo "Done. Test the release on a clean machine with:"
echo "  1. Extract ZIP"
echo "  2. Copy mxLoreMCP.ini.example -> mxLoreMCP.ini"
echo "  3. Set Password= in INI"
echo "  4. Run mxLoreMCP.exe"
echo "  5. Open http://localhost:8081"
