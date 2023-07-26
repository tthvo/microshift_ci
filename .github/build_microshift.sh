#!/usr/bin/env bash
# Require root shell
set -x -e -o pipefail

# Get latest version
VERSION=${VERSION:-"4.13.0-rc-8"}


install_build_deps() {
    sudo apt -y install build-essential curl libgpgme-dev pkg-config libseccomp-dev
}

check_release_available() {
    curl -Ls https://api.github.com/repos/redhat-et/microshift/releases | jq .[].tag_name | grep $VERSION
    if [ $? != 0 ]; then
        echo "MicroShift version ${VERSION} is unavailable" && exit 1
    fi
}

build_microshift() {
    local artifact_url=$(curl -Ls https://api.github.com/repos/redhat-et/microshift/releases | jq -r .[].tarball_url | grep $VERSION)
    curl -Lo "$VERSION.tar"  $artifact_url && tar -xf "$VERSION.tar"
    cd $(ls | grep microshift)
    go mod tidy
    make clean
    GO_REQUIRED_MIN_VERSION="" make
    sudo mv ./_output/bin/microshift /usr/local/bin/microshift
}

check_release_available
install_build_deps

TMP_DIR=$(mktemp -d)
pushd $TMP_DIR
build_microshift
popd
rm -rf $TMP_DIR
