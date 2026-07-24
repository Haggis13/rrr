#!/usr/bin/env bash
set +e
STATUS=0
mkdir -p dist
rm -f dist/build.log dist/build-status.txt dist/T90-Cockpit-1.0.0.apk \
  dist/T90-Cockpit-1.0.0.apk.sha256 dist/apk.part* dist/apk-parts.txt
exec > >(tee dist/build.log) 2>&1

fail_step() {
  local rc="$1"
  local label="$2"
  if [ "$rc" -ne 0 ] && [ "$STATUS" -eq 0 ]; then
    STATUS="$rc"
    echo "FAILED STEP: $label (exit $rc)"
  fi
}

echo "=== Locate and verify source segments ==="
python3 - <<'PY'
from pathlib import Path
import hashlib
import sys

specs = [
    ("project.part00", 7000, "90133f936e91eaafaca537115b4ac64c68e7b8ba4654deaabd8973254712d71d"),
    ("project.part01", 7000, "15bd0f9e9eea3bf8290f09eae7d91ec6792430910ae80e835c3906e9d3a02d67"),
    ("project.part02", 7000, "96de0b4766742e70d63442b89ce1dd6107b2f07e97e05573899ba4debeb676e5"),
    ("project.part03", 1412, "3ab801275fe1e67ed7c2eb693b11c4a4364b056b5928e0aeae0398d93f1f77d1"),
]
for index, (name, wanted_len, wanted_hash) in enumerate(specs):
    data = Path(name).read_bytes()
    print(f"{name}: stored={len(data)}, wanted={wanted_len}, target={wanted_hash}")
    found = None
    found_offset = None
    if len(data) >= wanted_len:
        for offset in range(len(data) - wanted_len + 1):
            candidate = data[offset:offset + wanted_len]
            if hashlib.sha256(candidate).hexdigest() == wanted_hash:
                found = candidate
                found_offset = offset
                break
    if found is None:
        print(f"ERROR: verified segment not found in {name}")
        sys.exit(21 + index)
    output = Path(f"/tmp/t90-part{index:02d}")
    output.write_bytes(found)
    print(f"VERIFIED: {name} offset={found_offset}, sha256={hashlib.sha256(found).hexdigest()}")
PY
fail_step $? "source segment verification"

echo "=== Reconstruct source ==="
if [ "$STATUS" -eq 0 ]; then
  cat /tmp/t90-part00 /tmp/t90-part01 /tmp/t90-part02 /tmp/t90-part03 \
    | base64 --decode > /tmp/t90-source.tgz
  fail_step $? "base64 decode"
fi
if [ "$STATUS" -eq 0 ]; then
  echo "Expected archive SHA-256: 9939f329560c0018bd29c0dd98e82c0e40c631cddf8f082bee1c40ebdfeb23d9"
  sha256sum /tmp/t90-source.tgz
  echo "9939f329560c0018bd29c0dd98e82c0e40c631cddf8f082bee1c40ebdfeb23d9  /tmp/t90-source.tgz" | sha256sum -c -
  fail_step $? "archive checksum"
fi
if [ "$STATUS" -eq 0 ]; then
  tar -xzf /tmp/t90-source.tgz
  fail_step $? "source extraction"
fi

echo "=== Java and Android SDK ==="
export JAVA_HOME="${JAVA_HOME_17_X64:-$JAVA_HOME}"
export PATH="$JAVA_HOME/bin:$PATH"
java -version
fail_step $? "Java 17"
if [ "$STATUS" -eq 0 ]; then
  yes | sdkmanager --licenses >/dev/null || true
  sdkmanager "platforms;android-35" "build-tools;35.0.0"
  fail_step $? "Android SDK install"
fi

echo "=== Gradle ==="
if [ "$STATUS" -eq 0 ]; then
  curl -fL --retry 3 --retry-delay 3 \
    -o /tmp/gradle.zip \
    https://services.gradle.org/distributions/gradle-8.11.1-bin.zip
  fail_step $? "Gradle download"
fi
if [ "$STATUS" -eq 0 ]; then
  rm -rf /tmp/gradle-8.11.1
  unzip -q /tmp/gradle.zip -d /tmp
  fail_step $? "Gradle extraction"
fi

echo "=== Release key ==="
if [ "$STATUS" -eq 0 ]; then
  mkdir -p keystore
  rm -f keystore/t90-release.jks
  keytool -genkeypair -v \
    -keystore keystore/t90-release.jks \
    -storepass T90Cockpit2026 \
    -keypass T90Cockpit2026 \
    -alias t90cockpit \
    -keyalg RSA -keysize 3072 -validity 10000 \
    -dname "CN=T90 Cockpit, OU=Local Build, O=THK1304, L=Norway, C=NO"
  fail_step $? "release key generation"
fi

echo "=== Unit tests and APK build ==="
if [ "$STATUS" -eq 0 ]; then
  /tmp/gradle-8.11.1/bin/gradle --no-daemon clean testReleaseUnitTest assembleRelease
  fail_step $? "Gradle test/build"
fi

echo "=== APK signature verification ==="
if [ "$STATUS" -eq 0 ]; then
  "$ANDROID_HOME/build-tools/35.0.0/apksigner" verify --verbose --print-certs \
    app/build/outputs/apk/release/app-release.apk
  fail_step $? "APK signature verification"
fi

if [ "$STATUS" -eq 0 ]; then
  cp app/build/outputs/apk/release/app-release.apk dist/T90-Cockpit-1.0.0.apk
  sha256sum dist/T90-Cockpit-1.0.0.apk > dist/T90-Cockpit-1.0.0.apk.sha256
  base64 -w0 dist/T90-Cockpit-1.0.0.apk | split -b 20000 -d -a 2 - dist/apk.part
  find dist -maxdepth 1 -type f -name 'apk.part*' -printf '%f\n' | sort > dist/apk-parts.txt
  echo SUCCESS > dist/build-status.txt
else
  echo "FAILED:$STATUS" > dist/build-status.txt
fi

echo "=== Publish result ==="
git config user.name github-actions[bot]
git config user.email 41898282+github-actions[bot]@users.noreply.github.com
git add -f dist/build.log dist/build-status.txt
if [ -f dist/T90-Cockpit-1.0.0.apk ]; then
  git add -f dist/T90-Cockpit-1.0.0.apk \
    dist/T90-Cockpit-1.0.0.apk.sha256 dist/apk.part* dist/apk-parts.txt
fi
git commit -m "[ci verified segments] T90 Cockpit build status $STATUS" || true
git push origin HEAD:build/t90-cockpit-1.0.0
exit "$STATUS"
