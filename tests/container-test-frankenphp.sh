#!/usr/bin/env bash
set -euo pipefail

IMAGE_TAG="${1:-moodle-local:5.3}"
echo "🔍 Running Unit & Hardening Tests against image: ${IMAGE_TAG}"

# 1. Test Non-Root Execution
echo "➡️ [Test 1/5] Verifying rootless execution (www-data)..."
CURRENT_USER=$(docker run --rm "${IMAGE_TAG}" whoami)
if [ "${CURRENT_USER}" != "www-data" ]; then
  echo "❌ FAIL: Container is running as '${CURRENT_USER}', expected 'www-data'"
  exit 1
fi
echo "✅ PASS: Running as non-root user 'www-data'"

# 2. Test Distroless Hardening (apk must be removed)
echo "➡️ [Test 2/5] Verifying apk package manager is stripped..."
if docker run --rm "${IMAGE_TAG}" sh -c "command -v apk" >/dev/null 2>&1; then
  echo "❌ FAIL: 'apk' package manager is still present in the image!"
  exit 1
fi
echo "✅ PASS: 'apk' package manager is completely stripped"

# 3. Test Mandatory Moodle 5.3 PHP Extensions
echo "➡️ [Test 3/5] Verifying required PHP 8.3 extensions..."
REQUIRED_EXTS=("exif" "gd" "intl" "mysqli" "Zend OPcache" "pdo_pgsql" "soap" "sodium" "zip")
LOADED_EXTS=$(docker run --rm "${IMAGE_TAG}" php -m)

for ext in "${REQUIRED_EXTS[@]}"; do
  if ! echo "${LOADED_EXTS}" | grep -qi "^${ext}$"; then
    echo "❌ FAIL: Missing required PHP extension: ${ext}"
    exit 1
  fi
done
echo "✅ PASS: All ${#REQUIRED_EXTS[@]} mandatory Moodle 5.3 extensions loaded"

# 4. Test PHP Production Configuration (max_input_vars >= 5000)
echo "➡️ [Test 4/5] Verifying Moodle 5.3 PHP ini settings..."
MAX_VARS=$(docker run --rm "${IMAGE_TAG}" php -r "echo ini_get('max_input_vars');")
if [ "${MAX_VARS}" -lt 5000 ]; then
  echo "❌ FAIL: max_input_vars is ${MAX_VARS}, Moodle 5.3 requires >= 5000"
  exit 1
fi
echo "✅ PASS: max_input_vars=${MAX_VARS}"

# 5. Test FrankenPHP Web Server Boot & Moodle Core Files
echo "➡️ [Test 5/5] Testing FrankenPHP HTTP server response on port 8080..."
CONTAINER_ID=$(docker run -d -p 8080:8080 "${IMAGE_TAG}")
trap 'docker rm -f "${CONTAINER_ID}" >/dev/null 2>&1 || true' EXIT

# Wait up to 10 seconds for FrankenPHP to listen on :8080
HTTP_CODE="000"
for i in {1..10}; do
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/install.php || echo "000")
  if [ "${HTTP_CODE}" = "200" ] || [ "${HTTP_CODE}" = "303" ]; then
    break
  fi
  sleep 1
done

if [ "${HTTP_CODE}" != "200" ] && [ "${HTTP_CODE}" != "303" ]; then
  echo "❌ FAIL: FrankenPHP did not return HTTP 200/303 on /install.php (Got HTTP ${HTTP_CODE})"
  docker logs "${CONTAINER_ID}"
  exit 1
fi
echo "✅ PASS: FrankenPHP HTTP server responded with HTTP ${HTTP_CODE} on :8080"

echo "ALL CONTAINER UNIT TESTS PASSED!"
