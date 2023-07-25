#!/usr/bin/env bash
# Require root shell
set -x -e -o pipefail

# Function to get Linux distribution
get_distro() {
    DISTRO=$(egrep '^(ID)=' /etc/os-release| sed 's/"//g' | cut -f2 -d"=")
    if [[ $DISTRO != @(rhel|fedora|centos|ubuntu) ]]
    then
      echo "This Linux distro is not supported by the install script"
      exit 1
    fi
}

# Function to get system architecture
get_arch() {
    ARCH=$(uname -m | sed "s/x86_64/amd64/" | sed "s/aarch64/arm64/")
    if [[ $ARCH != @(amd64|arm64) ]]
    then
        printf "arch %s unsupported" "$ARCH" >&2
        exit 1
    fi
}

# Function to get OS version
get_os_version() {
    OS_VERSION=$(egrep '^(VERSION_ID)=' /etc/os-release | sed 's/"//g' | cut -f2 -d"=")
}

# Function to check system prerequisites
pre-check-installation(){
    mem_threshold='1024'
    disk_threshold='2048'
    numCPU_threshold='2'
    
    numCPU=$(nproc --all)
    if [ $numCPU -lt $numCPU_threshold ]; then
        echo "Warning: Pre-Install check number of CPUs cores less than recommended number: $numCPU_threshold"
        #uncomment this line to exit on error. By now informative only
        #exit 1
    fi

    mem_free=$(free -m | grep "Mem" | awk '{print $4+$6}')
    if [ $mem_free -lt $mem_threshold ]
    then
        echo "Warning: Pre-Install check MEM usage less than recommended number: $mem_threshold"
        #uncomment this line to exit on error. By now informative only
        #exit 1
    fi

    disk_free=$(df -m | grep /$ | grep -v -E '(tmp|boot)' | awk '{print $4}')
    if [ $disk_free -lt $disk_threshold ]
    then
        echo "Warning: Pre-Install check DISK usage less than recommended number: $disk_threshold"
        #uncomment this line to exit on error. By now informative only
        #exit 1
    fi
}

# Install dependencies
install_dependencies() {
    apt-get install -y \
            policycoreutils-python-utils \
            conntrack \
            firewalld 
}

# Establish Iptables rules
establish_firewall () {
    systemctl enable firewalld --now
    firewall-cmd --zone=public --permanent --add-port=6443/tcp
    firewall-cmd --zone=public --permanent --add-port=30000-32767/tcp
    firewall-cmd --zone=public --permanent --add-port=2379-2380/tcp
    firewall-cmd --zone=public --add-masquerade --permanent
    firewall-cmd --zone=public --add-port=80/tcp --permanent
    firewall-cmd --zone=public --add-port=443/tcp --permanent
    firewall-cmd --zone=public --add-port=10250/tcp --permanent
    firewall-cmd --zone=public --add-port=10251/tcp --permanent
    firewall-cmd --permanent --zone=trusted --add-source=10.42.0.0/16
    firewall-cmd --reload
}


# Install CRI-O depending on the distro
install_crio() {
    CRIOVERSION=1.21

    OS=xUbuntu_$OS_VERSION
    KEYRINGS_DIR=/usr/share/keyrings
    echo "deb [signed-by=$KEYRINGS_DIR/libcontainers-archive-keyring.gpg] https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/$OS/ /" | tee /etc/apt/sources.list.d/devel:kubic:libcontainers:stable.list > /dev/null
    echo "deb [signed-by=$KEYRINGS_DIR/libcontainers-crio-archive-keyring.gpg] http://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable:/cri-o:/$CRIOVERSION/$OS/ /" | tee /etc/apt/sources.list.d/devel:kubic:libcontainers:stable:cri-o:$CRIOVERSION.list > /dev/null

    mkdir -p $KEYRINGS_DIR
    curl -L https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable/$OS/Release.key | gpg --dearmor -o $KEYRINGS_DIR/libcontainers-archive-keyring.gpg
    curl -L https://download.opensuse.org/repositories/devel:/kubic:/libcontainers:/stable:/cri-o:/$CRIOVERSION/$OS/Release.key | gpg --dearmor -o $KEYRINGS_DIR/libcontainers-crio-archive-keyring.gpg

    apt-get update -y
    # Vagrant Ubuntu VMs don't provide containernetworking-plugins by default
    apt-get install -y cri-o cri-o-runc cri-tools containernetworking-plugins
}


# CRI-O config to match MicroShift networking values
crio_conf() {
    sh -c 'cat << EOF > /etc/cni/net.d/100-crio-bridge.conf
{
    "cniVersion": "0.4.0",
    "name": "crio",
    "type": "bridge",
    "bridge": "cni0",
    "isGateway": true,
    "ipMasq": true,
    "hairpinMode": true,
    "ipam": {
        "type": "host-local",
        "routes": [
            { "dst": "0.0.0.0/0" }
        ],
        "ranges": [
            [{ "subnet": "10.42.0.0/24" }]
        ]
    }
}
EOF'
}

# Download and install microshift
microshift_conf() {
    cat << EOF | tee /usr/lib/systemd/system/microshift.service
[Unit]
Description=MicroShift
After=crio.service

[Service]
WorkingDirectory=/usr/local/bin/
ExecStart=microshift run
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF
}

# Locate kubeadmin configuration to default kubeconfig location
prepare_kubeconfig() {
    mkdir -p $HOME/.kube
    if [ -f $HOME/.kube/config ]; then
        mv $HOME/.kube/config $HOME/.kube/config.orig
    fi
    KUBECONFIG=/var/lib/microshift/resources/kubeadmin/kubeconfig:$HOME/.kube/config.orig /usr/local/bin/kubectl config view --flatten > $HOME/.kube/config
}

# validation checks for deployment 
validation_check(){
    echo $HOSTNAME | grep -P '(?=^.{1,254}$)(^(?>(?!\d+\.)[a-zA-Z0-9_\-]{1,63}\.?)+(?:[a-zA-Z]{2,})$)' && echo "Correct"
    if [ $? != 0 ];
    then
        echo "======================================================================"
        echo "!!! WARNING !!!"
        echo "The hostname $HOSTNAME does not follow FQDN, which might cause problems while operating the cluster."
        echo "See: https://github.com/redhat-et/microshift/issues/176"
        echo
        echo "If you face a problem or want to avoid them, please update your hostname and try again."
        echo "Example: 'sudo hostnamectl set-hostname $HOSTNAME.example.com'"
        echo "======================================================================"
    else
        echo "$HOSTNAME is a valid machine name continuing installation"
    fi
}

# Script execution
get_distro
get_arch
get_os_version
pre-check-installation
validation_check
install_dependencies
install_crio
crio_conf
establish_firewall

verify_crio
systemctl enable crio --now

if [ -f /usr/local/bin/microshift ];
then
    microshift_conf
    systemctl enable microshift.service --now

    until systemctl --no-pager status microshift.service && test -f /var/lib/microshift/resources/kubeadmin/kubeconfig
    do
        journalctl -u microshift -f
        sleep 30s
    done
    prepare_kubeconfig
else
    echo "No MicroShift binary found" && exit 1
fi