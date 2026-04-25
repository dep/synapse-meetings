<!-- Project-specific override. Adapted from VoxCommit's flow for an XcodeGen + xcodebuild project. -->

# Export Signed App (Synapse Meetings)

## Description

Build, sign, notarize, and release a new version of Synapse Meetings with Sparkle auto-update support.

The project uses XcodeGen + xcodebuild (not pure SPM), so Sparkle.framework is embedded automatically by `xcodebuild archive`. Code signing of Sparkle's nested helpers is handled by Xcode's "Sign to Run Locally"/Developer ID build phase, but we re-verify after export.

## Prerequisites

- Developer ID Application certificate in login keychain
- `notarytool` keychain profile (see Setup)
- Sparkle EdDSA private key in keychain (already generated — public key is committed in `Info.plist` as `SUPublicEDKey`)
- `create-dmg` installed: `brew install create-dmg`
- `xcodegen` installed: `brew install xcodegen`
- Sparkle tools in `/tmp/sparkle-bin/bin/` (see Setup)

## Setup: Store Notarization Credentials (one-time)

```bash
source .env && xcrun notarytool store-credentials "notarytool" \
  --apple-id "$APPLE_EMAIL" \
  --team-id "299R8V27FZ" \
  --password "$APPLE_APP_PASSWORD"
```

## Setup: Sparkle Tools (one-time)

```bash
mkdir -p /tmp/sparkle-bin && cd /tmp/sparkle-bin && \
curl -sL "https://github.com/sparkle-project/Sparkle/releases/download/2.6.4/Sparkle-2.6.4.tar.xz" -o sparkle.tar.xz && \
tar -xf sparkle.tar.xz
```

## Step-by-Step

### 0. Bump the version

Edit `project.yml`:

```yaml
properties:
  CFBundleShortVersionString: "x.y.z"
  CFBundleVersion: "N"   # increment
```

Then regenerate the Xcode project:

```bash
xcodegen generate
```

### 1. Switch to Developer ID signing for the release archive

The committed `project.yml` ships with ad-hoc signing for local dev (`CODE_SIGN_IDENTITY: "-"`, `CODE_SIGNING_ALLOWED: NO`, `ENABLE_HARDENED_RUNTIME: NO`). For a release archive, override these on the `xcodebuild` command line so we don't have to keep mutating `project.yml`:

```bash
IDENTITY="Developer ID Application: Danny Peck (299R8V27FZ)"
TEAM_ID="299R8V27FZ"

rm -rf build && \
xcodebuild -project SynapseMeetings.xcodeproj \
  -scheme SynapseMeetings \
  -configuration Release \
  -archivePath build/SynapseMeetings.xcarchive \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGNING_ALLOWED=YES \
  ENABLE_HARDENED_RUNTIME=YES \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  OTHER_CODE_SIGN_FLAGS="--timestamp --options runtime" \
  archive
```

### 2. Export the .app from the archive

```bash
cat > build/ExportOptions.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>manual</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
</dict>
</plist>
EOF

xcodebuild -exportArchive \
  -archivePath build/SynapseMeetings.xcarchive \
  -exportPath build/export \
  -exportOptionsPlist build/ExportOptions.plist
```

The exported app is `build/export/SynapseMeetings.app`.

### 3. Verify the signature (Sparkle inside-out)

```bash
codesign --verify --deep --strict --verbose=2 build/export/SynapseMeetings.app
```

Should be silent. If Sparkle's nested XPC helpers aren't signed, re-sign manually (rare with proper archive flow):

```bash
APP="build/export/SynapseMeetings.app"
codesign --force --timestamp --options runtime --sign "$IDENTITY" \
  "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc" 2>/dev/null || true
codesign --force --timestamp --options runtime --sign "$IDENTITY" \
  "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc" 2>/dev/null || true
codesign --force --timestamp --options runtime --sign "$IDENTITY" \
  "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate" 2>/dev/null || true
codesign --force --timestamp --options runtime --sign "$IDENTITY" \
  "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app" 2>/dev/null || true
codesign --force --timestamp --options runtime --sign "$IDENTITY" \
  "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --deep --timestamp --options runtime \
  --entitlements SynapseMeetings/SynapseMeetings.entitlements \
  --sign "$IDENTITY" "$APP"
```

### 4. Notarize + staple

```bash
APP="build/export/SynapseMeetings.app"
rm -f /tmp/SynapseMeetings-notarize.zip && \
ditto -c -k --keepParent "$APP" /tmp/SynapseMeetings-notarize.zip && \
xcrun notarytool submit /tmp/SynapseMeetings-notarize.zip --keychain-profile "notarytool" --wait && \
xcrun stapler staple "$APP" && \
spctl --assess --type execute --verbose "$APP"
```

### 5. Package as DMG

Replace `<version>` with the new version (e.g. `0.1.0`):

```bash
APP="build/export/SynapseMeetings.app"
rm -rf /tmp/SynapseMeetings-dmg-src && mkdir -p /tmp/SynapseMeetings-dmg-src && \
cp -R "$APP" /tmp/SynapseMeetings-dmg-src/ && \
rm -f ~/Desktop/SynapseMeetings-<version>.dmg && \
create-dmg \
  --volname "Synapse Meetings" \
  --window-pos 200 120 --window-size 660 400 --icon-size 160 \
  --icon "SynapseMeetings.app" 180 170 --hide-extension "SynapseMeetings.app" \
  --app-drop-link 480 170 \
  ~/Desktop/SynapseMeetings-<version>.dmg \
  /tmp/SynapseMeetings-dmg-src/
```

### 6. Sign the DMG for Sparkle

```bash
SIG=$(/tmp/sparkle-bin/bin/sign_update ~/Desktop/SynapseMeetings-<version>.dmg)
echo "$SIG"
# Captures: sparkle:edSignature="..." length="..."
```

### 7. Update appcast.xml

Prepend a new `<item>` to `appcast.xml` at the repo root. Use the signature from step 6:

```xml
<item>
  <title>Version <version></title>
  <pubDate>Mon, 24 Apr 2026 19:00:00 +0000</pubDate>
  <sparkle:version><build-number></sparkle:version>
  <sparkle:shortVersionString><version></sparkle:shortVersionString>
  <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
  <description><![CDATA[<release notes HTML>]]></description>
  <enclosure
    url="https://github.com/dep/synapse-meetings/releases/download/<version>/SynapseMeetings-<version>.dmg"
    sparkle:edSignature="<edSignature from sign_update>"
    length="<length from sign_update>"
    type="application/octet-stream" />
</item>
```

Use `date -u "+%a, %d %b %Y %H:%M:%S +0000"` for `pubDate`.

### 8. Commit, push, release

```bash
git add project.yml SynapseMeetings/Info.plist appcast.xml && \
git commit -m "bump version to <version>" && \
git push

gh release create <version> --title "<version>" --notes "<release notes>" && \
gh release upload <version> ~/Desktop/SynapseMeetings-<version>.dmg
```

**CRITICAL:** `appcast.xml` must be pushed to `main` — Sparkle fetches it from the raw GitHub URL configured in Info.plist (`SUFeedURL = https://raw.githubusercontent.com/dep/synapse-meetings/main/appcast.xml`). The DMG URL in the appcast must match the GitHub release asset URL.

## First-Release Checklist

For the very first release (no `appcast.xml` exists yet):

1. Create `appcast.xml` at repo root with the standard Sparkle wrapper:
   ```xml
   <?xml version="1.0" encoding="utf-8"?>
   <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
     <channel>
       <title>Synapse Meetings</title>
       <link>https://raw.githubusercontent.com/dep/synapse-meetings/main/appcast.xml</link>
       <description>Most recent changes with links to updates.</description>
       <language>en</language>
       <!-- items go here, newest first -->
     </channel>
   </rss>
   ```
2. Confirm the Sparkle public key in `Info.plist` matches the private key in your keychain:
   ```bash
   /tmp/sparkle-bin/bin/generate_keys -p
   # should print: Tnoq0NNryfeGcjS0eQ2xfuOuvqf4dRoa3wF86ljVZh4=
   ```

## Expected Output

- `notarytool`: `status: Accepted`
- `spctl`: `accepted / source=Notarized Developer ID`
- `codesign --verify --deep`: no output (silent success)

## Artifacts

- Notarized app: `build/export/SynapseMeetings.app`
- DMG: `~/Desktop/SynapseMeetings-<version>.dmg`
- Appcast: `appcast.xml` (committed to main)
- GitHub release with DMG attached
