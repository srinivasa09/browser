#!/usr/bin/env bash
# Publish code + artifacts to GitHub repo and create a Release
# Requirements:
#   - env GITHUB_TOKEN set with repo:write scope
#   - git and curl available (macOS default)
# Optional env:
#   - GITHUB_REPO (default: allthingssecurity/browser)
#   - GIT_AUTHOR_NAME / GIT_AUTHOR_EMAIL (or set below defaults)
#   - RELEASE_TAG (override auto tag)
#   - RELEASE_NAME (override auto name)

set -euo pipefail

APP_NAME="NativeMacBrowser"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"
DIST_DIR="$PROJECT_DIR/dist"
INFO_PLIST="$PROJECT_DIR/Info.plist"

REPO_SLUG="${GITHUB_REPO:-allthingssecurity/browser}"
GIT_NAME="${GIT_AUTHOR_NAME:-Release Bot}"
GIT_EMAIL="${GIT_AUTHOR_EMAIL:-releases@example.invalid}"

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  echo "Error: GITHUB_TOKEN not set. export GITHUB_TOKEN=..." >&2
  exit 1
fi

echo "==> Ensuring build artifacts exist"
if [[ ! -f "$DIST_DIR/$APP_NAME.dmg" ]]; then
  echo "Artifacts not found. Running build.sh ..."
  bash "$PROJECT_DIR/build.sh"
fi

if [[ ! -f "$DIST_DIR/$APP_NAME.dmg" ]]; then
  echo "Error: DMG not found at $DIST_DIR/$APP_NAME.dmg" >&2
  exit 1
fi

echo "==> Zipping .app for release"
APP_PATH="$DIST_DIR/$APP_NAME.app"
ZIP_PATH="$DIST_DIR/$APP_NAME.zip"
if [[ -d "$APP_PATH" ]]; then
  ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
else
  echo "Warning: .app not found at $APP_PATH (continuing with DMG only)"
fi

echo "==> Reading version from Info.plist"
PLIST_BUDDY="/usr/libexec/PlistBuddy"
VERSION="$($PLIST_BUDDY -c 'Print :CFBundleShortVersionString' "$INFO_PLIST" 2>/dev/null || echo 1.0)"
BUILD_NO="$($PLIST_BUDDY -c 'Print :CFBundleVersion' "$INFO_PLIST" 2>/dev/null || echo 1)"
DATE_TAG="$(date +%Y%m%d-%H%M%S)"

TAG_NAME="${RELEASE_TAG:-v${VERSION}-b${BUILD_NO}-${DATE_TAG}}"
RELEASE_NAME="${RELEASE_NAME:-$APP_NAME $VERSION (build $BUILD_NO)}"

echo "==> Preparing temporary workspace"
WORKDIR="$(mktemp -d)"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

cd "$WORKDIR"
echo "Cloning https://github.com/$REPO_SLUG.git"
git clone "https://github.com/$REPO_SLUG.git" repo
cd repo

# Configure author if missing
git config user.name "$GIT_NAME"
git config user.email "$GIT_EMAIL"

# Detect default branch
DEFAULT_REMOTE_HEAD=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD || true)
DEFAULT_BRANCH=${DEFAULT_REMOTE_HEAD#origin/}
if [[ -z "$DEFAULT_BRANCH" ]]; then DEFAULT_BRANCH="main"; fi

echo "==> Copying project into repo (branch: $DEFAULT_BRANCH)"
git checkout "$DEFAULT_BRANCH" || git checkout -b "$DEFAULT_BRANCH"
mkdir -p "$PWD/$APP_NAME"

# Copy source tree
rsync -a --delete "$PROJECT_DIR/" "$PWD/$APP_NAME/" 2>/dev/null || {
  echo "rsync not available; using cp -R";
  rm -rf "$PWD/$APP_NAME" && mkdir -p "$PWD/$APP_NAME";
  (cd "$PROJECT_DIR" && tar cf - .) | (cd "$PWD/$APP_NAME" && tar xf -);
}

# Optionally keep top-level releases folder for convenience
mkdir -p releases
cp -f "$DIST_DIR/$APP_NAME.dmg" releases/ 2>/dev/null || true
[[ -f "$ZIP_PATH" ]] && cp -f "$ZIP_PATH" releases/ || true

# Ensure authenticated remote for pushes
git remote set-url origin "https://$GITHUB_TOKEN@github.com/$REPO_SLUG.git"

echo "==> Committing code and artifacts"
git add "$APP_NAME" releases || true
if ! git diff --cached --quiet; then
  git commit -m "Add $APP_NAME app, build scripts, and release artifacts ($TAG_NAME)"
  git push origin "$DEFAULT_BRANCH"
else
  echo "No file changes to commit. Continuing."
fi

echo "==> Tagging $TAG_NAME"
git tag -a "$TAG_NAME" -m "Release $RELEASE_NAME"
git push origin "$TAG_NAME"

echo "==> Creating GitHub Release"
API_REPO="https://api.github.com/repos/$REPO_SLUG"
CREATE_JSON=$(cat <<JSON
{
  "tag_name": "$TAG_NAME",
  "name": "$RELEASE_NAME",
  "body": "Automated release for $APP_NAME $VERSION (build $BUILD_NO).\n\nAssets include .dmg and zipped .app.",
  "draft": false,
  "prerelease": false
}
JSON
)

RESP=$(curl -sS -X POST -H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github+json" -H "Content-Type: application/json" "$API_REPO/releases" -d "$CREATE_JSON")

# If release already exists, fallback to using the existing one
RELEASE_ID=$(python3 -c 'import sys,json; print(json.load(sys.stdin).get("id",""))' <<< "$RESP" 2>/dev/null || echo "")

if [[ -z "$RELEASE_ID" ]]; then
  # Likely a 422 (release already exists). Fetch by tag.
  echo "Release creation failed, attempting to fetch existing release by tag..."
  RESP=$(curl -sS -H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github+json" "$API_REPO/releases/tags/$TAG_NAME")
  RELEASE_ID=$(python3 -c 'import sys,json; print(json.load(sys.stdin).get("id",""))' <<< "$RESP" 2>/dev/null || echo "")
fi

if [[ -z "$RELEASE_ID" ]]; then
  echo "Error: Could not get a release ID. Response was:\n$RESP" >&2
  exit 1
fi

HTML_URL=$(python3 -c 'import sys,json; print(json.load(sys.stdin).get("html_url",""))' <<< "$RESP" 2>/dev/null || echo "")

echo "==> Uploading assets to release $RELEASE_ID"
UPLOAD_BASE="https://uploads.github.com/repos/$REPO_SLUG/releases/$RELEASE_ID/assets?name="

if [[ -f "$DIST_DIR/$APP_NAME.dmg" ]]; then
  echo "Uploading DMG..."
  curl -sS -X POST -H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github+json" -H "Content-Type: application/octet-stream" \
    --data-binary @"$DIST_DIR/$APP_NAME.dmg" \
    "$UPLOAD_BASE$(basename "$APP_NAME.dmg")" >/dev/null || true
fi

if [[ -f "$ZIP_PATH" ]]; then
  echo "Uploading ZIP (.app)..."
  curl -sS -X POST -H "Authorization: Bearer $GITHUB_TOKEN" -H "Accept: application/vnd.github+json" -H "Content-Type: application/octet-stream" \
    --data-binary @"$ZIP_PATH" \
    "$UPLOAD_BASE$(basename "$ZIP_PATH")" >/dev/null || true
fi

echo "\nPublish complete."
echo "Repo: https://github.com/$REPO_SLUG"
[[ -n "$HTML_URL" ]] && echo "Release: $HTML_URL" || true
