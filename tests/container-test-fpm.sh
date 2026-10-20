#!/usr/bin/env bash
set -euo pipefail

IMAGE_TAG="${1:-moodle-local:5.3-fpm}"
echo "🔍 Running FastCGI (PHP-FPM) Unit & Hardening Tests against: ${IMAGE_TAG}"

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

# 4. Test PHP Production Configuration & FPM Syntax
echo "➡️ [Test 4/5] Verifying Moodle 5.3 PHP ini settings & php-fpm config..."
MAX_VARS=$(docker run --rm "${IMAGE_TAG}" php -r "echo ini_get('max_input_vars');")
if [ "${MAX_VARS}" -lt 5000 ]; then
  echo "❌ FAIL: max_input_vars is ${MAX_VARS}, Moodle 5.3 requires >= 5000"
  exit 1
fi
docker run --rm "${IMAGE_TAG}" php-fpm -t >/dev/null 2>&1
echo "✅ PASS: max_input_vars=${MAX_VARS} and php-fpm configuration syntax is valid"

# 5. Test FastCGI Protocol Round-Trip with Nginx Sidecar
echo "➡️ [Test 5/5] Testing Nginx Sidecar -> FastCGI (:9000) response..."
TEST_VOL="moodle-fpm-test-vol-$$"
NGINX_CONF=$(mktemp)

cat <<'EOF' >"${NGINX_CONF}"
server {
    listen 8080;
    root /var/www/html/public;
    index index.php;
    location ~ [^/]\.php(/|$) {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass 127.0.0.1:9000;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
    }
}
EOF

docker volume create "${TEST_VOL}" >/dev/null
FPM_ID=$(docker run -d -p 8082:8080 -v "${TEST_VOL}:/var/www/html" "${IMAGE_TAG}")
NGINX_ID=$(docker run -d --network "container:${FPM_ID}" \
  -v "${TEST_VOL}:/var/www/html:ro" \
  -v "${NGINX_CONF}:/etc/nginx/conf.d/default.conf:ro" \
  nginx:alpine)

trap 'docker rm -f "${NGINX_ID}" "${FPM_ID}" >/dev/null 2>&1 || true; docker volume rm -f "${TEST_VOL}" >/dev/null 2>&1 || true; rm -f "${NGINX_CONF}"' EXIT

HTTP_CODE="000"
for i in {1..10}; do
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8082/install.php || echo "000")
  if [ "${HTTP_CODE}" = "200" ] || [ "${HTTP_CODE}" = "303" ]; then
    break
  fi
  sleep 1
done

if [ "${HTTP_CODE}" != "200" ] && [ "${HTTP_CODE}" != "303" ]; then
  echo "❌ FAIL: FastCGI + Nginx sidecar did not return HTTP 200/303 (Got HTTP ${HTTP_CODE})"
  docker logs "${FPM_ID}"
  exit 1
fi
echo "✅ PASS: Nginx -> FastCGI (:9000) responded with HTTP ${HTTP_CODE}"

echo "ALL FASTCGI CONTAINER UNIT TESTS PASSED!"
