#!/bin/bash
set -e

# Default values
VPN_TYPE="easyconnect"
VERSION=""
ARCH="amd64"
FLAVOR="vnc"
CUSTOM_TAG=""
DRY_RUN=false
SKIP_BUILD_STAGE=false

# Help menu
usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  -t, --type <type>        Type of VPN: easyconnect (default), atrust
  -v, --version <version>  Version of VPN:
                             For easyconnect: 7.6.3, 7.6.7 (default)
                             For atrust: 2.2.16, 2.3.10.65, 2.3.10_sp3, 2.3.10_sp4, 2.4.10.50, 2.5.16.20 (default)
  -a, --arch <arch>        CPU Architecture: amd64 (default), arm64, i386, mips64le
  -f, --flavor <flavor>    Build flavor: vnc (default), vncless, cli
                             (Note: 'cli' is only supported for easyconnect on amd64)
  -n, --tag <tag>          Docker image tag name (default: auto-generated)
  -s, --skip-build-stage   Skip building the intermediate build image (docker-easyconnect:build)
  -d, --dry-run            Dry run: print docker commands instead of running them
  -h, --help               Show this help message

Examples:
  $0 -t easyconnect -v 7.6.7 -f vnc
  $0 -t atrust -v 2.5.16.20 -a arm64 -f vncless
  $0 -t easyconnect -f cli -d
EOF
    exit 0
}

# Parse options
while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--type)
            VPN_TYPE="$2"
            shift 2
            ;;
        -v|--version)
            VERSION="$2"
            shift 2
            ;;
        -a|--arch)
            ARCH="$2"
            shift 2
            ;;
        -f|--flavor)
            FLAVOR="$2"
            shift 2
            ;;
        -n|--tag)
            CUSTOM_TAG="$2"
            shift 2
            ;;
        -s|--skip-build-stage)
            SKIP_BUILD_STAGE=true
            shift 1
            ;;
        -d|--dry-run)
            DRY_RUN=true
            shift 1
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Error: Unknown option $1" >&2
            usage
            ;;
    esac
done

# Normalize inputs
VPN_TYPE=$(echo "$VPN_TYPE" | tr '[:upper:]' '[:lower:]')
FLAVOR=$(echo "$FLAVOR" | tr '[:upper:]' '[:lower:]')

# Validate VPN Type
if [[ "$VPN_TYPE" != "easyconnect" && "$VPN_TYPE" != "atrust" ]]; then
    echo "Error: Invalid VPN type '$VPN_TYPE'. Must be 'easyconnect' or 'atrust'." >&2
    exit 1
fi

# Set defaults for version based on VPN type
if [[ -z "$VERSION" ]]; then
    if [[ "$VPN_TYPE" == "easyconnect" ]]; then
        VERSION="7.6.7"
    else
        VERSION="2.5.16.20"
    fi
fi

# Validate Architecture
case "$ARCH" in
    amd64|arm64|i386|mips64le) ;;
    *)
        echo "Error: Invalid architecture '$ARCH'. Must be 'amd64', 'arm64', 'i386', or 'mips64le'." >&2
        exit 1
        ;;
esac

# Validate Flavor
if [[ "$FLAVOR" != "vnc" && "$FLAVOR" != "vncless" && "$FLAVOR" != "cli" ]]; then
    echo "Error: Invalid flavor '$FLAVOR'. Must be 'vnc', 'vncless', or 'cli'." >&2
    exit 1
fi

# Validate CLI restrictions
if [[ "$FLAVOR" == "cli" ]]; then
    if [[ "$VPN_TYPE" != "easyconnect" ]]; then
        echo "Error: 'cli' flavor is only supported for EasyConnect, not aTrust." >&2
        exit 1
    fi
    if [[ "$ARCH" != "amd64" ]]; then
        echo "Warning: EasyConnect CLI deb is only packaged for amd64. Building on '$ARCH' might fail or run under QEMU emulation." >&2
    fi
fi

# Locate build-args file
ARG_FILE=""
if [[ "$VPN_TYPE" == "easyconnect" ]]; then
    ARG_FILE="build-args/${VERSION}-${ARCH}.txt"
else
    # For aTrust, check if version-specific file exists, else fallback to standard atrust-<arch>.txt
    if [[ -f "build-args/atrust-${VERSION}-${ARCH}.txt" ]]; then
        ARG_FILE="build-args/atrust-${VERSION}-${ARCH}.txt"
    elif [[ -f "build-args/atrust-${ARCH}.txt" ]]; then
        ARG_FILE="build-args/atrust-${ARCH}.txt"
    fi
fi

if [[ -z "$ARG_FILE" || ! -f "$ARG_FILE" ]]; then
    echo "Error: Build arguments file for Type: $VPN_TYPE, Version: $VERSION, Arch: $ARCH not found!" >&2
    echo "Please check if the file exists under 'build-args/' directory." >&2
    exit 1
fi

# Resolve Dockerfile
DOCKERFILE=""
if [[ "$FLAVOR" == "vnc" ]]; then
    DOCKERFILE="Dockerfile"
elif [[ "$FLAVOR" == "vncless" ]]; then
    DOCKERFILE="Dockerfile.vncless"
else
    DOCKERFILE="Dockerfile.cli"
fi

if [[ ! -f "$DOCKERFILE" ]]; then
    echo "Error: Dockerfile '$DOCKERFILE' not found!" >&2
    exit 1
fi

# Resolve Docker Platform parameter
DOCKER_PLATFORM=""
case "$ARCH" in
    amd64)   DOCKER_PLATFORM="linux/amd64" ;;
    i386)    DOCKER_PLATFORM="linux/386" ;;
    arm64)   DOCKER_PLATFORM="linux/arm64" ;;
    mips64le) DOCKER_PLATFORM="linux/mips64le" ;;
    *)       DOCKER_PLATFORM="linux/${ARCH}" ;;
esac

# Resolve Target Tag name
TARGET_TAG="$CUSTOM_TAG"
if [[ -z "$TARGET_TAG" ]]; then
    if [[ "$VPN_TYPE" == "easyconnect" ]]; then
        if [[ "$FLAVOR" == "vnc" ]]; then
            TARGET_TAG="hagb/docker-easyconnect:${VERSION}-${ARCH}"
        elif [[ "$FLAVOR" == "vncless" ]]; then
            TARGET_TAG="hagb/docker-easyconnect:vncless-${VERSION}-${ARCH}"
        else
            TARGET_TAG="hagb/docker-easyconnect:cli-${ARCH}"
        fi
    else
        if [[ "$FLAVOR" == "vnc" ]]; then
            TARGET_TAG="hagb/docker-atrust:${VERSION}-${ARCH}"
        else
            TARGET_TAG="hagb/docker-atrust:vncless-${VERSION}-${ARCH}"
        fi
    fi
fi

# Read build args from file
read -r -a BUILD_ARGS < "$ARG_FILE"

# Helper to run or print command
run_cmd() {
    if $DRY_RUN; then
        printf 'Dry-run:'
        printf ' %q' "$@"
        printf '\n'
    else
        printf 'Executing:'
        printf ' %q' "$@"
        printf '\n'
        "$@"
    fi
}

echo "=============================================="
echo "  Docker VPN Client Build Script"
echo "=============================================="
echo "Type:         $VPN_TYPE"
echo "Version:      $VERSION"
echo "Architecture: $ARCH (Platform: $DOCKER_PLATFORM)"
echo "Flavor:       $FLAVOR (Dockerfile: $DOCKERFILE)"
echo "Arguments:    $ARG_FILE"
echo "Target Tag:   $TARGET_TAG"
echo "Dry-Run:      $DRY_RUN"
echo "=============================================="

# 1. Build intermediate builder image if not skipped
if ! $SKIP_BUILD_STAGE; then
    echo "--- Step 1: Building intermediate build image (docker-easyconnect:build) ---"
    # Read build-args parameters for the builder image as well
    run_cmd docker build --platform "$DOCKER_PLATFORM" -t docker-easyconnect:build "${BUILD_ARGS[@]}" -f Dockerfile.build .
else
    echo "--- Step 1: Skipped intermediate build image stage ---"
fi

# 2. Build final target image
echo "--- Step 2: Building target image ($TARGET_TAG) ---"
run_cmd docker build --platform "$DOCKER_PLATFORM" -t "$TARGET_TAG" "${BUILD_ARGS[@]}" -f "$DOCKERFILE" .

echo "=============================================="
if $DRY_RUN; then
    echo "Dry run completed successfully!"
else
    echo "Build process completed successfully!"
    echo "To run your newly built image, use:"
    if [[ "$VPN_TYPE" == "easyconnect" ]]; then
        if [[ "$FLAVOR" == "cli" ]]; then
            echo "  docker run --rm --device /dev/net/tun --cap-add NET_ADMIN -ti -p 127.0.0.1:1080:1080 -p 127.0.0.1:8888:8888 $TARGET_TAG"
        else
            echo "  docker run --rm --device /dev/net/tun --cap-add NET_ADMIN -ti -p 127.0.0.1:5901:5901 -p 127.0.0.1:1080:1080 -p 127.0.0.1:8888:8888 -e PASSWORD=xxxx -e URLWIN=1 $TARGET_TAG"
        fi
    else
        echo "  docker run --rm --device /dev/net/tun --cap-add NET_ADMIN -ti -p 127.0.0.1:5901:5901 -p 127.0.0.1:1080:1080 -p 127.0.0.1:8888:8888 -p 127.0.0.1:54631:54631 --sysctl net.ipv4.conf.default.route_localnet=1 -e PASSWORD=xxxx -e URLWIN=1 $TARGET_TAG"
    fi
fi
echo "=============================================="
