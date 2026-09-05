#!/bin/sh -e
#
# Cross-compile sms-gateway for the arm64 rootfs and stage it into dist/.
#
# sms-gateway embeds a React frontend (src/web) via go:embed, so the build
# first compiles the frontend (npm ci && npm run build) and then builds the
# Go binary for linux/arm64 with CGO disabled (the embedded SQLite driver,
# modernc.org/sqlite, is pure Go). The binary is staged as
# dist/usr/local/bin/sms-gateway and later copied into the rootfs image by
# scripts/build_images.sh (same mechanism as scripts/build_gt.sh).
#
# Needs Go >= 1.25 (per src/go.mod) and Node.js/npm on the build host.

SRCDIR=$(pwd)/src/sms-gateway
STAGEDIR=$(pwd)/dist
BINDIR=${STAGEDIR}/usr/local/bin
OUT=$(pwd)/build/sms-gateway.$$

command -v go >/dev/null 2>&1 || { echo "error: 'go' not found (need Go >= 1.25)" >&2; exit 1; }
command -v npm >/dev/null 2>&1 || { echo "error: 'npm' not found (need Node.js for the web UI)" >&2; exit 1; }

mkdir -p "${BINDIR}" build

# Build the React frontend that gets embedded in the binary.
(
    cd "${SRCDIR}/src/web"
    npm ci
    npm run build
)

# Cross-compile the static linux/arm64 binary.
(
    cd "${SRCDIR}/src"
    CGO_ENABLED=0 GOOS=linux GOARCH=arm64 \
        go build -trimpath -ldflags="-s -w" -o "${OUT}" ./cmd/sms-gateway
)

install -m 0755 "${OUT}" "${BINDIR}/sms-gateway"
rm -f "${OUT}"

echo "sms-gateway built: ${BINDIR}/sms-gateway"
