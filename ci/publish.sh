#!/bin/sh
# Pushes build/results to the ci-results branch and puts the .ipa on the "dev" pre-release.
set -u
R=build/results
[ -d "$R" ] || exit 0
REMOTE="https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
# Builds of main go to ci-results and the "dev" release people download; trial builds of other
# branches only to ci-results-<branch>, so they never replace the .ipa being installed.
BRANCH="${GITHUB_REF_NAME:-main}"
if [ "$BRANCH" = "main" ]; then RESULTS=ci-results; else RESULTS="ci-results-$BRANCH"; fi
(
  cd "$R"
  git init -q
  git checkout -q -b "$RESULTS"
  git add -A
  git -c user.name="HayDocs CI" -c user.email="ci@users.noreply.github.com" commit -qm "Results of run ${GITHUB_RUN_NUMBER} ($BRANCH)"
  git push -q -f "$REMOTE" "$RESULTS"
) || echo "push of results failed"
if [ "$BRANCH" = "main" ] && [ -f build/HayDocs.ipa ]; then
  gh release delete dev -y --cleanup-tag -R "$GITHUB_REPOSITORY" >/dev/null 2>&1 || true
  gh release create dev build/HayDocs.ipa -R "$GITHUB_REPOSITORY" --prerelease --target "$GITHUB_SHA" \
    --title "HayDocs, сборка ${GITHUB_RUN_NUMBER}" \
    --notes "Неподписанный HayDocs.ipa: установите его через Sideloadly со своим Apple ID." || echo "release failed"
fi
