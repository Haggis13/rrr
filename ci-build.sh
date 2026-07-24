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

echo "=== Verify exact source chunks ==="
echo "fa0e646d7d3cf215ef11fcb81f36c3239c647d8fc319482009f051d9d5769bd7  exact.part00" | sha256sum -c -
fail_step $? "exact.part00 checksum"
echo "614319ad834038210a0f7c91d0003d1f145fdd0f60cd0ed7fd8f8859475fc126  exact.part01" | sha256sum -c -
fail_step $? "exact.part01 checksum"
echo "5c2e0934fb0bafece25e37cfe1bcdb8fc31760fdb0b4be2c03906c3c2d4a217c  exact.part02" | sha256sum -c -
fail_step $? "exact.part02 checksum"
echo "2d594e76288b76412ac7bcc7a26c1a9a63e650736e5ad9c0a60842811da906b0  exact.part03" | sha256sum -c -
fail_step $? "exact.part03 checksum"
echo "39397ba4a56c3da50a76fa819403faabcb49c08e8a255d0aed28dd0649f8a581  exact.part04" | sha256sum -c -
fail_step $? "exact.part04 checksum"
echo "8902f7e6a1a6333853c0ee44393ab99ec19be8ac6350d5ee11b68a7ee7feb811  exact.part05" | sha256sum -c -
fail_step $? "exact.part05 checksum"

echo "=== Reconstruct source ==="
if [ "$STATUS" -eq 0 ]; then
  cat exact.part00 exact.part01 exact.part02 exact.part03 exact.part04 exact.part05 \
    | base64 --decode > /tmp/t90-source.tgz
  fail_step $? "base64 decode"
fi
if [ "$STATUS" -eq 0 ]; then
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
git commit -m "[ci exact chunks] T90 Cockpit build status $STATUS" || true
git push origin HEAD:build/t90-cockpit-1.0.0
exit "$STATUS"
