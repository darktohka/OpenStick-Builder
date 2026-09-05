#!/bin/sh -e
#
# Cross-compile frpc for the arm64 rootfs and stage it into dist/.
#
# frp (https://github.com/fatedier/frp) is pinned as the src/frp git submodule
# at the v0.71.0 tag. Only the client (./cmd/frpc) is needed on the OpenStick;
# frps runs on a public server. The binary is staged as
# dist/usr/local/bin/frpc and later copied into the rootfs image by
# scripts/build_images.sh (same mechanism as scripts/build_gt.sh).
#
# frpc is built with the `noweb` build tag (same as upstream `make frpc` from a
# clean tree): the embedded admin web dashboard is left out, which keeps the
# binary small and skips a Node.js build. The frpc admin API and all proxy
# functionality are unaffected -- only the optional browser UI is missing.
#
# Needs Go >= 1.25 (per src/frp/go.mod). frp has no CGO deps, so the result is
# a static linux/arm64 binary.

SRCDIR=$(pwd)/src/frp
STAGEDIR=$(pwd)/dist
BINDIR=${STAGEDIR}/usr/local/bin
OUT=$(pwd)/build/frpc.$$

command -v go >/dev/null 2>&1 || { echo "error: 'go' not found (need Go >= 1.25)" >&2; exit 1; }

mkdir -p "${BINDIR}" build

# Cross-compile the static linux/arm64 binary.
(
    cd "${SRCDIR}"
    CGO_ENABLED=0 GOOS=linux GOARCH=arm64 \
        go build -trimpath -tags="frpc,noweb" -ldflags="-s -w" -o "${OUT}" ./cmd/frpc
)

install -m 0755 "${OUT}" "${BINDIR}/frpc"
rm -f "${OUT}"

echo "frpc built: ${BINDIR}/frpc"
