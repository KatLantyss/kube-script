#!/bin/bash
# Tested on Kubernetes 1.26, 1.27

VERSION="v0.0.1"

colorful() {
    local color_tag=$1 && shift
    local style_tag=$1 && shift
    local text=$@

    declare -A color
    declare -A style
    
    NC='\e[0m'
    
    color["black"]="0m"
    color["red"]="1m"
    color["green"]="2m"
    color["yellow"]="3m"
    color["blue"]="4m"
    color["purple"]="5m"
    color["cyan"]="6m"
    color["white"]="7m"
    
    style["regular"]="0;3"
    style["bold"]="1;3"
    style["faded"]="2;3"
    style["italics"]="3;3"
    style["underline"]="4;3"
    style["blink"]="5;3"

    echo -e "\e[${style[$style_tag]}${color[$color_tag]}$text${NC}"
}

usage(){
  printf "Usage: k8s [options]\n"
  printf "Commands:\n"
  printf "  kill                           Terminate the Kubernetes Cluster\n"
  printf "  init                           Initialize a new Kubernetes Cluster\n"
  printf "  reset                          Reset and restart the Kubernetes Cluster\n\n"

  printf "  load                           Load Docker Images to Kubernetes.\n\n"

  printf "  list                           list Kubernetes Applications that can be installed\n"
  printf "  install                        Install Kubernetes Applications\n"
  printf "  uninstall                      Uninstall Kubernetes Applicaions\n\n"

  printf "  watch                          Watch Pod running status\n\n"

  printf "Options:\n"
  printf "  --cni [calico | flannel]       Specify the Container Network Interface (CNI) plugin (Calico as default)\n"
  printf "  --subnet [8/16/24/32]          Specify the CNI subnet (16 as default)\n"
  printf "  --gpu                          Configure for GPU environment (require nvidia-container-toolkit be installed)\n\n"

  printf "Examples:\n"
  printf "  k8s init  --cni=flannel        Initialize pods and use Flannel as CNI\n"
  printf "  k8s reset --gpu                Reset the cluster with GPU environment configuration\n"
  printf "  k8s install metric             Install matric API on cluster\n"
  printf "  k8s watch                      Watch Pod running status\n"
  printf "  k8s load local/my-image        Load local/my-image in Docker to Kubernetes\n"
  exit 1
}

watch_cluster(){
  watch -n 0 -t -c "echo \"\e[1;36m********************************** Kubernetes Simple Monitor **********************************\e[0m\n\" && kubectl get pods -A && echo \"\n\e[1;31mPress Ctrl C to exit.\e[0m\n\""
}

cni_address() {
    if [[ $CNI == "flannel" ]]; then
      echo "10.244.0.0/$SUBNET"
    elif [[ $CNI == "calico" ]]; then
      echo "192.168.0.0/$SUBNET"
    fi
}

gpu_time_slice() {
  cat << EOF | kubectl create -f -
  apiVersion: v1
  kind: ConfigMap
  metadata:
    name: time-slicing-config
    namespace: nvidia-system
  data:
    default: |-
      version: v1
      flags:
        migStrategy: none
      sharing:
        timeSlicing:
          renameByDefault: false
          failRequestsGreaterThanOne: false
          resources:
            - name: nvidia.com/gpu
              replicas: $1
EOF
}

######### Combine commands #########
kubeadm_reset() {
  colorful red bold "* Kill Kubernetes Cluster" 
  echo "y" | sudo kubeadm reset
  echo ""

  colorful red bold "* Clean CRIO container"
  sudo crictl rm --all
  echo ""  

  colorful red bold "* Remove Kubernetes Config Files"
  sudo rm -rf ~/.kube
  sudo rm -rf /etc/cni/net.d
  echo ""
}

kubeadm_init() {
  colorful cyan bold "* Initialize Kubernetes Cluster"
  sudo kubeadm init --pod-network-cidr=$(cni_address)
  echo ""

  colorful cyan bold "* Procress Kubernetes Config File"
  mkdir -p $HOME/.kube
  sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
  sudo chown $(id -u):$(id -g) $HOME/.kube/config
  echo ""

  colorful yellow bold "* Untaint Control Plane"
  kubectl taint nodes --all node-role.kubernetes.io/control-plane-
  echo ""

  colorful cyan bold "* Install CNI"
  if [[ $CNI == "flannel" ]]; then
    curl -sL https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml \
    | sed "s/10.244.0.0\/16/10.244.0.0\/$SUBNET/g" \
    | kubectl apply -f -
  elif [[ $CNI == "calico" ]]; then
    kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.26.4/manifests/tigera-operator.yaml
    curl -sL https://raw.githubusercontent.com/projectcalico/calico/v3.26.4/manifests/custom-resources.yaml \
    | sed "s/192.168.0.0\/16/192.168.0.0\/$SUBNET/g" \
    | kubectl create -f -
  fi
  echo ""

  watch_cluster
}

containerd_restart() { 
  colorful green bold "* Initialize Containerd"
  sudo bash -c "containerd config default > /etc/containerd/config.toml"
  sudo sed -i 's/            SystemdCgroup = false/            SystemdCgroup = true/' /etc/containerd/config.toml
  echo ""

  if [[ $NEED_GPU == true ]]; then
    colorful green bold "* Enable GPU Enviroment..."
    sudo nvidia-ctk runtime configure --runtime=containerd
    sudo sed -i 's/      default_runtime_name = \"runc\"/      default_runtime_name = \"nvidia\"/' /etc/containerd/config.toml
    echo ""
  fi

  colorful green bold "* Restart Containerd"
  sudo systemctl restart containerd
  echo ""

  sudo crictl config runtime-endpoint unix:///var/run/containerd/containerd.sock
}

kubelet_restart() {
  colorful green bold "* Restart Kubelet\n"
  sudo swapoff -a
  sudo systemctl restart kubelet
}
####################################



########## Parse argument ##########
parse_argument() {
  CNI="calico"
  SUBNET="16"
  NEED_GPU=false

  ARGS=$(getopt -o "" -l cni:,subnet:,gpu -n "k8s" -- "$@")
  if [[ $? -ne 0 ]]; then usage; fi
  eval set -- "$ARGS"

  while [ $# -gt 0 ]
    do
      case $1 in
        --cni)
          if [[ "$2" == "calico" || "$2" == "flannel" ]]; then
            CNI="${2#*=}"
          else
            usage
          fi
          shift 2;;
        --subnet)
          if [[ "$2" == "8" || "$2" == "16" || "$2" == "24" || "$2" == "32" ]]; then
            SUBNET=$2
          else
            usage
          fi
          shift 2;;
        --gpu)
          NEED_GPU=true
          shift;;
        --)
          shift
          break;;
      esac
  done
  if [[ $# -ne 0 ]]; then usage; fi
}
####################################

############# Commands #############
kube_reset() {
  parse_argument "$@"

  colorful cyan bold "***** Reset cluster with ${CNI} [$(cni_address)] *****\n"

  kubeadm_reset
  containerd_restart
  kubelet_restart
  kubeadm_init
}

kube_kill() {
  kubeadm_reset
  containerd_restart
}

kube_init() {
  parse_argument "$@"

  colorful cyan bold "***** Init cluster with ${CNI} [$(cni_address)] *****\n"

  containerd_restart
  kubelet_restart
  kubeadm_init
}

kube_load() {
  if [[ $# -eq 0 ]]; then docker images --format '{{.Repository}}:{{.Tag}}' && exit; fi

  if [[ -z $(docker images --format  {{.Repository}}:{{.Tag}} | grep -w $1) ]]; then docker images --format '{{.Repository}}:{{.Tag}}' && exit; fi

  sudo crictl rmi --prune > /dev/null

  colorful cyan bold "* [Docker] Save image..."
  docker save -o /tmp/temp_image.tar $1
  colorful cyan bold "* [Containerd] Load image..."
  sudo ctr -n k8s.io image import /tmp/temp_image.tar
  sudo rm /tmp/temp_image.tar
  colorful cyan bold "* [CRIO] List image..."
  sudo crictl images
}

kube_manage() { 
  if [[ $# -eq 0 ]]; then usage; fi
  while [ $# -gt 0 ]
    do
      case $1 in
        yunikorn)
          if [[ $COMMAND == "install" ]]; then
            helm repo add yunikorn https://apache.github.io/yunikorn-release
            helm repo update
            helm install yunikorn yunikorn/yunikorn --namespace yunikorn --create-namespace
          elif [[ $COMMAND == "uninstall" ]]; then
            helm uninstall yunikorn -n yunikorn
          fi
          shift;;
        prometheus)
          if [[ $COMMAND == "install" ]]; then
            helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
            helm repo update
            helm install prometheus prometheus-community/kube-prometheus-stack -n prometheus --create-namespace
          elif [[ $COMMAND == "uninstall" ]]; then
            helm uninstall prometheus -n prometheus
          fi
          shift;;
        metric)
          if [[ $COMMAND == "install" ]]; then
            curl -sL https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml \
            | sed '/      - args:/a \        - --kubelet-insecure-tls' \
            | kubectl create -f -
          elif [[ $COMMAND == "uninstall" ]]; then
            curl -sL https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml \
            | sed '/      - args:/a \        - --kubelet-insecure-tls' \
            | kubectl delete -f -
          fi
          shift;;
        kwok)
          local KWOK_LATEST_RELEASE=$(curl -s "https://api.github.com/repos/kubernetes-sigs/kwok/releases/latest" | jq -r '.tag_name')
          if [[ $COMMAND == "install" ]]; then
            kubectl create -f "https://github.com/kubernetes-sigs/kwok/releases/download/${KWOK_LATEST_RELEASE}/kwok.yaml"
            kubectl create -f "https://github.com/kubernetes-sigs/kwok/releases/download/${KWOK_LATEST_RELEASE}/stage-fast.yaml"
          elif [[ $COMMAND == "uninstall" ]]; then
            kubectl delete -f "https://github.com/kubernetes-sigs/kwok/releases/download/${KWOK_LATEST_RELEASE}/stage-fast.yaml"
            kubectl delete -f "https://github.com/kubernetes-sigs/kwok/releases/download/${KWOK_LATEST_RELEASE}/kwok.yaml"
          fi 
          shift;;
        nvidia:* | nvidia)
          if [[ $COMMAND == "install" ]]; then
            helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
            helm repo update
            helm install nvidia-operator nvidia/gpu-operator -n nvidia-system --create-namespace
          elif [[ $COMMAND == "uninstall" ]]; then
            helm uninstall nvidia-operator -n nvidia-system            
          fi

          if [[ ${1%:*} != ${1#*:} ]]; then
            colorful yellow "Setting GPU time slice to ${1#*:}"
            gpu_time_slice ${1#*:}

            kubectl patch clusterpolicy/cluster-policy \
            -n nvidia-system --type merge \
            -p '{"spec": {"devicePlugin": {"config": {"name": "time-slicing-config"}}}}'

            local node_name=$(kubectl describe node | grep Name: | awk '{print $2}')

            kubectl label node $node_name nvidia.com/device-plugin.config=default
          fi
          shift;;
        k9s)
          if [[ $COMMAND == "install" ]]; then
            local K9S_LATEST_RELEASE=$(curl -s "https://api.github.com/repos/derailed/k9s/releases/latest" | jq -r '.tag_name')
            curl -fsSL -o k9s_Linux_amd64.tar.gz https://github.com/derailed/k9s/releases/download/${K9S_LATEST_RELEASE}/k9s_Linux_amd64.tar.gz
            sudo tar -xzvf k9s_Linux_amd64.tar.gz -C /usr/local/bin k9s && rm -f k9s_Linux_amd64.tar.gz
          elif [[ $COMMAND == "uninstall" ]]; then
            sudo rm -rf /usr/local/bin/k9s
          fi
          shift;;
        *)
          colorful red "Application Not Found: ${1}"
          shift;;
      esac
  done
}

kube_list() {
  printf "Applications:\n"
  printf " - metric          Metrics Server is a scalable, efficient source of container resource metrics for Kubernetes built-in autoscaling pipelines\n"
  printf " - kwok            KWOK is a toolkit that enables setting up a cluster of thousands of Nodes in seconds\n"
  printf " - yunikorn        Unleash the power of resource scheduling for running Big Data & ML on Kubernetes\n"
  printf " - nvidia          NVIDIA GPU Operator uses the operator framework within Kubernetes to automate the management of all NVIDIA software components needed to provision GPU\n"
  printf " - prometheus      Power your metrics and alerting with the leading open-source monitoring solution\n"
  printf " - k9s             K9s is a terminal based UI to interact with your Kubernetes clusters\n"
}
####################################

############### Main ###############
if [ $# -lt 1 ]; then usage; fi

COMMAND=$1
shift

case $COMMAND in
  reset)
    kube_reset "$@"
    ;;
  kill)
    kube_kill
    ;;
  init)
    kube_init "$@"
    ;;
  load)
    kube_load "$@"
    ;;
  install | uninstall)
    kube_manage "$@"
    ;;
  list)
    kube_list
    ;;
  watch)
    watch_cluster
    ;;
  version)
    echo $VERSION
    ;;
  *)
    usage
    ;;
esac
####################################