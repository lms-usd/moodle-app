#!/usr/bin/env bash
set -euo pipefail

IMAGE_TAG="${1:-moodle-local:5.3-lomp}"
echo "🔍 Running LOMP (OpenLiteSpeed + LSPHP) Unit & Hardening Tests against: ${IMAGE_TAG}"

# 1. Test Moodle File Ownership for Rootless Worker Execution (nobody)
echo "➡️ [Test 1/5] Verifying Moodle files are owned by non-root worker 'nobody'..."
FILE_OWNER=$(docker run --rm --entrypoint stat "${IMAGE_TAG}" -c '%U' /var/www/vhosts/localhost/html/public/install.php)
if [ "${FILE_OWNER}" != "nobody" ]; then
  echo "❌ FAIL: Moodle files owned by '${FILE_OWNER}', expected 'nobody'"
  exit 1
fi
echo "✅ PASS: Worker files owned by non-root user 'nobody'"

# 2. Test Distroless Hardening (apt-get must be removed)
echo "➡️ [Test 2/5] Verifying apt-get package manager is stripped..."
if docker run --rm --entrypoint sh "${IMAGE_TAG}" -c "command -v apt-get" >/dev/null 2>&1; then
  echo "❌ FAIL: 'apt-get' package manager is still present in the image!"
  exit 1
fi
echo "✅ PASS: 'apt-get' package manager is completely stripped"

# 3. Test Mandatory Moodle 5.3 LSPHP 8.3 Extensions
echo "➡️ [Test 3/5] Verifying required LSPHP 8.3 extensions..."
REQUIRED_EXTS=("exif" "gd" "intl" "mysqli" "Zend OPcache" "pdo_pgsql" "soap" "sodium" "zip")
LOADED_EXTS=$(docker run --rm --entrypoint /usr/local/lsws/lsphp83/bin/php "${IMAGE_TAG}" -m)

for ext in "${REQUIRED_EXTS[@]}"; do
  if ! echo "${LOADED_EXTS}" | grep -qi "^${ext}$"; then
    echo "❌ FAIL: Missing required LSPHP extension: ${ext}"
    exit 1
  fi
done
echo "✅ PASS: All ${#REQUIRED_EXTS[@]} mandatory Moodle 5.3 extensions loaded in LSPHP 8.3"

# 4. Test PHP Production Configuration (max_input_vars >= 5000)
echo "➡️ [Test 4/5] Verifying Moodle 5.3 LSPHP ini settings..."
MAX_VARS=$(docker run --rm --entrypoint /usr/local/lsws/lsphp83/bin/php "${IMAGE_TAG}" -r "echo ini_get('max_input_vars');")
if [ "${MAX_VARS}" -lt 5000 ]; then
  echo "❌ FAIL: max_input_vars is ${MAX_VARS}, Moodle 5.3 requires >= 5000"
  exit 1
fi
echo "✅ PASS: max_input_vars=${MAX_VARS}"

# 5. Test OpenLiteSpeed + LSAPI Live HTTP Response
echo "➡️ [Test 5/5] Testing OpenLiteSpeed -> LSAPI HTTP response on port 80..."
CONTAINER_ID=$(docker run -d -p 8083:80 "${IMAGE_TAG}")
trap 'docker rm -f "${CONTAINER_ID}" >/dev/null 2>&1 || true' EXIT

HTTP_CODE="000"
for i in {1..12}; do
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8083/install.php || echo "000")
  if [ "${HTTP_CODE}" = "200" ]; then
    break
  fi
  sleep 1
done

if [ "${HTTP_CODE}" != "200" ]; then
  echo "FAIL: OpenLiteSpeed did not return HTTP 200 on /install.php (Got HTTP ${HTTP_CODE})"
  docker logs "${CONTAINER_ID}"
  exit 1
fi
echo "PASS: OpenLiteSpeed + LSAPI responded with HTTP ${HTTP_CODE}"

echo "ALL LOMP CONTAINER UNIT TESTS PASSED!"
