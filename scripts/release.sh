#!/bin/zsh
# Builds, notarizes and packages a Cantator release for Sparkle updates.
#
#   scripts/release.sh <version> [notes.md] [--publish]
#
# Without --publish it stops after writing build/releases/<version>/, so the app can be tried
# first. With --publish it tags the commit and creates the GitHub release that the app's
# update feed points at.
#
# Needs: a clean tree, the Developer ID certificate (CODESIGN_IDENTITY) and Sparkle's update
# key (account "cantator") in the login keychain, and a notarytool profile (NOTARY_PROFILE,
# default "cantator"). Publishing also needs the commit pushed to origin and `gh` signed in.
set -euo pipefail

version=${1:?"usage: scripts/release.sh <version> [notes.md] [--publish]"}
shift
notes=""
publish=false
for arg in "$@"; do
    case $arg in
        --publish) publish=true ;;
        *) notes=${arg:A} ;;
    esac
done

repo=PRC-Atlanta/cantator
profile=${NOTARY_PROFILE:-cantator}
identity=${CODESIGN_IDENTITY:-"Developer ID Application: ANDREI GERMAN (6RHHE8NEYA)"}
tag=v$version
root=${0:A:h:h}
cd "$root"

[[ -z $(git status --porcelain) ]] || { echo "Commit or set aside your changes first."; exit 1; }
[[ -n $notes && ! -f $notes ]] && { echo "No notes file at $notes."; exit 1; }
git rev-parse -q --verify "refs/tags/$tag" >/dev/null && { echo "$tag already exists."; exit 1; }

# Sparkle compares build numbers, so each release needs a higher one. The commit count only grows.
build=$(git rev-list --count HEAD)
derived=build/dd
app=$derived/Build/Products/Release/Cantator.app
out=build/releases/$version
zip=$out/Cantator-$version.zip

echo "Building $version ($build)…"
log=$(xcodebuild -project Cantor.xcodeproj -scheme Cantor -configuration Release -derivedDataPath $derived \
    MARKETING_VERSION=$version CURRENT_PROJECT_VERSION=$build build 2>&1) || { print -r -- $log | grep "error:"; exit 1; }
# Xcode signs Sparkle.framework but not the helpers inside it, which keep Sparkle's own signature.
# Notarization needs every one on our Developer ID with the hardened runtime and a timestamp, inside out.
sign() { codesign -f -s $identity -o runtime --timestamp "$@" }
sparkle=$app/Contents/Frameworks/Sparkle.framework/Versions/B
sign $sparkle/XPCServices/Installer.xpc
sign --preserve-metadata=entitlements $sparkle/XPCServices/Downloader.xpc
sign $sparkle/Autoupdate
sign $sparkle/Updater.app
sign $app/Contents/Frameworks/Sparkle.framework
sign $app
codesign --verify --strict --deep $app
# Every piece must carry our team, not just a valid signature.
for part in $sparkle/XPCServices/*.xpc $sparkle/Autoupdate $sparkle/Updater.app $app; do
    [[ $(codesign -dv $part 2>&1) == *"TeamIdentifier=6RHHE8NEYA"* ]] || { echo "$part is not signed with our Developer ID."; exit 1; }
done

rm -rf $out
mkdir -p $out
echo "Notarizing…"
ditto -c -k --keepParent $app $zip
xcrun notarytool submit $zip --keychain-profile $profile --wait | tail -2
xcrun stapler staple $app
spctl --assess --type execute $app
# The zip people download must hold the stapled app.
rm $zip
ditto -c -k --keepParent $app $zip

echo "Writing the update feed…"
[[ -n $notes ]] && cp $notes $out/Cantor-$version.md
tools=$(find $derived/SourcePackages/artifacts -path "*Sparkle/bin" -type d | head -1)
# The feed lists only this release: Sparkle needs just the newest, and older zips stay on their own releases.
$tools/generate_appcast --account cantator --maximum-deltas 0 --embed-release-notes \
    --download-url-prefix "https://github.com/$repo/releases/download/$tag/" \
    --link "https://github.com/$repo/releases" $out
rm -f $out/Cantor-$version.md

echo "Ready in $out"
if ! $publish; then
    echo "Try it, then run again with --publish to release it."
    exit 0
fi

git branch -r --contains HEAD | grep -q "origin/" || { echo "Push this commit to origin first."; exit 1; }
git tag -a $tag -m "Cantator $version"
git push origin $tag
gh release create $tag $zip $out/appcast.xml --repo $repo --title "Cantator $version" \
    ${notes:+--notes-file} ${notes:-"--generate-notes"}
echo "Published $tag. Installed copies will offer it on their next check."
