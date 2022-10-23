#!/bin/bash
set -e

KUBECTL_VERSION=v1.20.2
MINIKUBE_VERSION=v1.20.0
PORTS="8080/tcp 8443/tcp 10248/tcp 10250/tcp"

MESSAGE=$(cat <<EOF
INSTALL MINIKUBE ON A RHEL/CENTOS/FEDORA DISTRIBUTION
=====================================================
This script installs and starts a minikube cluster.
The user can skip any step, if needed.

Due to the requirements of the initial project, I used 
minikube, kubeadm and kubectl version v1.20. This was done 
because I needed docker which is not supported by current
kubernetes versions anymore.

There may be a better way to achieve this as my method was
based on trial and error only. However, the installation
was successful every time I ran the script.

Other minikube, kubectl and kubeadm versions that may work
(but I did not test):

minikube    kubeadm & kubectl
========    =================
1.23.2      v1.25.3
1.23.1      v1.24.7
1.23.0      v1.23.13
1.22.0      v1.22.15
1.21.0      v1.20.2
1.20.0


This script runs on Centos/RHEL/Rocky 8.x
EOF
)

function check_user(){  
    local user_id message

    message="\nYou need to be root or use sudo to run this script.\nPlease try again.\n"
    user_id=$(id -u)
    if [[ $user_id != 0 ]]
    then
        echo -e "$message"
        exit 1
    fi
}

function check_gum(){
    [[ $(command -v gum) ]] || install_gum
}

function install_gum(){
    local host_type
    host_type=deb
    echo "Please wait... Installing gum (prerequisite)..."
    [[ $(command -v apt) ]] || host_type=rpm
    curl -q --progress -Lo gum.rpm \
    https://github.com/charmbracelet/gum/releases/download/v0.8.0/gum_0.8.0_linux_amd64.$host_type 
    case "$host_type" in
    deb)
        apt install gum."$host_type" -y ;;
    rpm)
        dnf install $(pwd)/gum."$host_type" -y ;;
    esac  
}

function show_message(){
    gum style --border normal --margin "1" --padding "1 2" --border-foreground 220 "$MESSAGE"
    gum confirm "Do you want to continue?" \
    --prompt.foreground="220" --selected.background="220" --selected.foreground="0"
}

function check_os(){
    local checker=''

    command -v apt || checker='OK'
    if [[ -z "$checker" ]]
    then
        gum style --border normal --margin "1" --padding "1 2" --border-foreground 220 "This OS is not supported, try a rhel,centos,fedora distribution."
        exit 1
    fi
}

function selector(){
    local executor=''
    local description="Select the desired answer:"
    local chooser="Yes Skip Exit"
    
    [[ -z "$1" ]] || description=$1
    [[ -z "$2" ]] || executor=$2
    gum style --foreground 220  "$description"  
    SELECTION=$(gum choose $chooser --cursor.foreground="220" --selected.foreground="220")
    if [[ $SELECTION = "Exit" ]]; then exit 1; fi
    if [[ $SELECTION = "Yes" ]]; then $executor ; fi
}

function remove_old_docker(){
    local docker_mod_list="containerd.io \
                            docker-ce \
                            docker-ce-cli \
                            docker-ce-rootless-extras \
                            docker-compose-plugin \
                            docker-scan-plugin"

    for docker_mod in $docker_mod_list
    do
        dnf remove $docker_mod -y || gum style --foreground 1 "failed to remove $docker_mod"
     done
    gum style --foreground 220 "Done!"
}


function install_docker(){
    [[ -f "/etc/yum.repos.d/docker-ce.repo" ]] || yes | dnf config-manager \
    --add-repo https://download.docker.com/linux/centos/docker-ce.repo

    dnf install -y \
        docker-ce docker-ce-cli \
        containerd.io \
        docker-compose-plugin
    systemctl enable docker --now
    docker --version
}

function install_kubectl_kubeadm(){
    local kubectl_latest_version

    kubectl_latest_version=$(curl -q --progress -L -s https://dl.k8s.io/release/stable.txt)
    gum style --foreground 220 "WARNING: Newest kubectl,kubeadm version is $kubectl_latest_version but we install $KUBECTL_VERSION"

    curl -q --progress -L --remote-name-all "https://dl.k8s.io/release/$KUBECTL_VERSION"/bin/linux/amd64/{kubectl,kubeadm}
    install -o root -g root -m 0755 kubectl /usr/sbin/kubectl
    install -o root -g root -m 0755 kubeadm /usr/sbin/kubeadm
}

function install_minikube(){

    gum style --foreground 220 "WARNING: Installing minikube version $MINIKUBE_VERSION"
    curl -q --progress -LO https://storage.googleapis.com/minikube/releases/$MINIKUBE_VERSION/minikube-linux-amd64
    chmod +x minikube-linux-amd64
    install -m 755 -o root -g root minikube-linux-amd64 /usr/sbin/minikube
    minikube version
}

function start_kubernetes_cluster(){
    local kube_user

    # selinux does not work with minikube
    setenforce 0
    sed -i 's/=enforcing/=disabled/' /etc/selinux/config
    echo
    systemctl enable kubelet.service --now
    # select the user to run minikube as:
    gum style --foreground 220 "Select the minikube user:"
    kube_user=$(gum choose $(cat /etc/passwd | grep '/home/' | awk -F':' '{print $1}') --cursor.foreground="010" --selected.foreground="220")
    usermod -aG docker $kube_user
    sudo -u $kube_user bash -c 'minikube start --vm-driver=none '
    kubectl config view
}

function install_cri_ctl(){
    local cri_ctl_url=$(curl -q --progress https://api.github.com/repos/kubernetes-sigs/cri-tools/releases/latest | jq -r .assets[].browser_download_url | grep -v 'sha' | grep 'crictl' | grep 'linux-amd64')
    local cri_ctl_name=$(basename $cri_ctl_url)
    curl -q --progress -LO $cri_ctl_url
    tar -xzf $cri_ctl_name
    install -o root -g root -m0755 crictl /usr/sbin/crictl
}

function install_cri_dockerd(){
    local cri_dockerd_url=$(curl -q --progress https://api.github.com/repos/Mirantis/cri-dockerd/releases/latest | jq -r .assets[].browser_download_url | grep 'el8.x86_64.rpm')
    local cri_dockerd_name=$(basename $cri_dockerd_url)
    curl -q --progress -LO $cri_dockerd_url
    dnf install -y $(pwd)/$cri_dockerd_name
    systemctl enable cri-docker --now
}

function open_ports(){
    local open_ports="$(firewall-cmd --list-ports)" 

    for PORT in $PORTS
    do
        [[ "$open_ports" =~ "$PORT" ]] || gum style --foreground '010'  "Adding port $PORT: $(firewall-cmd --add-port "$PORT" --permanent)"
    done

    gum style --foreground '010' "reloading firewall config: $(firewall-cmd --reload)"
}

function install_prerequisites(){
    command -v socat || dnf install -y socat
    command -v tc || dnf install -y iproute-tc
    command -v conntrack || dnf install conntrack -y
    command -v nmap-ncat || dnf install nmap-ncat -y
    command -v jq || dnf install jq -y
}

function disable_swap(){
    local swap_string

    swap_string=$(cat /etc/fstab | grep swap | awk '{print $1}')
    sed -i 's|^\('"$swap_string"'\)|#\1|' /etc/fstab
}

function main(){
    check_user
    check_gum
    show_message
    check_os
    install_prerequisites
    open_ports
    disable_swap
    selector "Do you want to remove old docker installations?" "remove_old_docker"
    selector "Do you want to install docker?" "install_docker"
    selector "Do you want to install kubectl and kubeadm?" "install_kubectl_kubeadm"
    selector "Do you want to install minikube?" "install_minikube"
    selector "Do you want to install cri-dockerd?" "install_cri_dockerd"
    selector "Do you want to install cri-ctl?" "install_cri_ctl"
    selector "Do you want to start the kubernetes cluster?" "start_kubernetes_cluster"
}

main