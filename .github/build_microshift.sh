#!/usr/bin/env bash
# Require root shell
set -x -e -o pipefail

# Get latest version
VERSION=${VERSION:-"4.13.0-rc-8"}


install_build_deps() {
    sudo apt -y install build-essential curl libgpgme-dev pkg-config libseccomp-dev
    # Install golang
    wget https://golang.org/dl/go1.19.1.linux-amd64.tar.gz
    rm -rf /usr/local/go && tar -C /usr/local -xzf go1.19.1.linux-amd64.tar.gz
    rm -f go1.19.1.linux-amd64.tar.gz
    export PATH=$PATH:/usr/local/go/bin
    export GOPATH=/root/go
    cat >> /root/.bashrc <<<"
    export PATH=$PATH:/usr/local/go/bin
    export GOPATH=/root/go"
    mkdir $GOPATH
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
    make
    mv microshift /usr/local/bin/microshift
}

check_release_available
install_build_deps
build_microshift
