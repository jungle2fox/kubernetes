#k8smaster节点安装脚本，请先部署harbor镜像仓库，修改下面的几个变量，pod不要和内网已有集群冲突
#! /bin/bash
REGISTRIES=192.168.1.11 #docker仓库地址
DOCKER_VERSION=20.10.17
KUB_VERSION=1.22.13
SCP_USER=scp
SCP_PASS=xxx
POD_NET=10.244.0.0/16
SERVICE_NET=10.96.0.0/12
APISERVER_PORT=6443

echo "1、同步主机时间"
systemctl status chronyd
systemctl start chronyd
systemctl enable chronyd

echo "2、关闭防火墙"
systemctl stop firewalld iptables
systemctl disable firewalld iptables

echo "3、关闭selinux"
setenforce 0
cp /etc/selinux/config /etc/selinux/config.bak
sed -i 's/SELINUX=[^"]*/SELINUX=disabled/g' /etc/selinux/config 

echo "4、关闭swap"
swapoff -a && sysctl -w vm.swappiness=0
cp /etc/fstab /etc/fstab.bak
sed -i 's/[^"]*swap/#&/g' /etc/fstab

echo "5、修改文件打开数限制"
cat << EOF >> /etc/security/limits.conf
* soft nofile 65536
* hard nofile 65536
* soft nproc 65535
* hard nproc 65535
EOF

echo "6、安装指定版本docker"
EXISTES_DOCKER=$(rpm -qa|grep docker|grep $DOCKER_VERSION)
if [ ! -n "$EXISTES_DOCKER" ];then
  yum install -y yum-utils device-mapper-persistent-data lvm2 rsync wget net-tools nfs-utils
  yum-config-manager --add-repo http://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo 
  yum-config-manager --enable docker-ce-test
  yum-config-manager --disable docker-ce-edge
  yum makecache fast
  yum install -y docker-ce-$DOCKER_VERSION &&
  systemctl enable docker
  systemctl start docker
  systemctl stop docker
  mkdir -p /home/docker/lib
  rsync -avzP /var/lib/docker/* /home/docker/ &&
  DOCKER_MIG=$(grep "\-\-data\-root" /lib/systemd/system/docker.service)
  if [ ! -n "$DOCKER_MIG" ];then
    sed -i 's/containerd.sock/& --data-root=\/home\/docker\/g' /lib/systemd/system/docker.service 
  fi
fi

echo "7、允许http方式推送镜像..."
cat << EOF > /etc/docker/daemon.json
{
  "registry-mirrors": ["https://v16stybc.mirror.aliyuncs.com"],
  "exec-opts": ["native.cgroupdriver=systemd"],
  "insecure-registries":["$REGISTRIES"]
}
EOF
systemctl daemon-reload
systemctl restart docker

echo "8、安装kubernetes（kubectl kubeadm kubelet）"
cat << EOF > /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://mirrors.aliyun.com/kubernetes/yum/repos/kubernetes-el7-x86_64
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://mirrors.aliyun.com/kubernetes/yum/doc/yum-key.gpg https://mirrors.aliyun.com/kubernetes/yum/doc/rpm-package-key.gpg
EOF
yum makecache
echo y|yum install -y kubelet-$KUB_VERSION --disableexcludes=kubernetes
echo y|yum install -y kubeadm-$KUB_VERSION --disableexcludes=kubernetes
echo y|yum install -y kubectl-$KUB_VERSION --disableexcludes=kubernetes
systemctl enable kubelet
systemctl start kubelet
sleep 10

echo "9、初始化Master节点"
for i in `kubeadm config images list  --kubernetes-version=v$KUB_VERSION`; do
  #镜像版本需核对
  imageName=${i#k8s.gcr.io/}
  docker pull $REGISTRIES/library/k8s.gcr.io/$imageName
  docker tag $REGISTRIES/library/k8s.gcr.io/$imageName k8s.gcr.io/$imageName
  docker rmi $REGISTRIES/library/k8s.gcr.io/$imageName
done;
docker images
sleep 10

kubeadm init \
  --kubernetes-version=v$KUB_VERSION \
  --pod-network-cidr=$POD_NET \
  --service-cidr=$SERVICE_NET \
  --ignore-preflight-errors=all \
  --apiserver-bind-port=$APISERVER_PORT
  
sed -i '/image:/i\    - --runtime-config=apps\/v1beta1=true,apps\/v1beta2=true,extensions\/v1beta1\/deployments=true' /etc/kubernetes/manifests/kube-apiserver.yaml
sed -i '/image:/i\    - --service-node-port-range=20000-65000' /etc/kubernetes/manifests/kube-apiserver.yaml
sleep 10


echo "10、初始化成功后生成永不过期的token，用于Worker节点加入的命令"
kubeadm token create --ttl 0 --print-join-command
chmod 644 /etc/kubernetes/admin.conf
mkdir -p $HOME/.kube
yes| cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config

echo "11、初始化flannel网络"
mkdir -p /opt/kubernetes/flannel/
cd /opt/kubernetes/flannel/
cat << EOF >> kube-flannel.yml
---
kind: Namespace
apiVersion: v1
metadata:
  name: kube-flannel
  labels:
    k8s-app: flannel
    pod-security.kubernetes.io/enforce: privileged
---
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  labels:
    k8s-app: flannel
  name: flannel
rules:
- apiGroups:
  - ""
  resources:
  - pods
  verbs:
  - get
- apiGroups:
  - ""
  resources:
  - nodes
  verbs:
  - get
  - list
  - watch
- apiGroups:
  - ""
  resources:
  - nodes/status
  verbs:
  - patch
---
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  labels:
    k8s-app: flannel
  name: flannel
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: flannel
subjects:
- kind: ServiceAccount
  name: flannel
  namespace: kube-flannel
---
apiVersion: v1
kind: ServiceAccount
metadata:
  labels:
    k8s-app: flannel
  name: flannel
  namespace: kube-flannel
---
kind: ConfigMap
apiVersion: v1
metadata:
  name: kube-flannel-cfg
  namespace: kube-flannel
  labels:
    tier: node
    k8s-app: flannel
    app: flannel
data:
  cni-conf.json: |
    {
      "name": "cbr0",
      "cniVersion": "0.3.1",
      "plugins": [
        {
          "type": "flannel",
          "delegate": {
            "hairpinMode": true,
            "isDefaultGateway": true
          }
        },
        {
          "type": "portmap",
          "capabilities": {
            "portMappings": true
          }
        }
      ]
    }
  net-conf.json: |
    {
      "Network": "10.244.0.0/16",
      "EnableNFTables": false,
      "Backend": {
        "Type": "vxlan"
      }
    }
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: kube-flannel-ds
  namespace: kube-flannel
  labels:
    tier: node
    app: flannel
    k8s-app: flannel
spec:
  selector:
    matchLabels:
      app: flannel
  template:
    metadata:
      labels:
        tier: node
        app: flannel
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: kubernetes.io/os
                operator: In
                values:
                - linux
      hostNetwork: true
      priorityClassName: system-node-critical
      tolerations:
      - operator: Exists
        effect: NoSchedule
      serviceAccountName: flannel
      initContainers:
      - name: install-cni-plugin
        image: $REGISTRIES/library/docker.io/flannel/flannel-cni-plugin:v1.5.1-flannel2
        command:
        - cp
        args:
        - -f
        - /flannel
        - /opt/cni/bin/flannel
        volumeMounts:
        - name: cni-plugin
          mountPath: /opt/cni/bin
      - name: install-cni
        image: $REGISTRIES/library/docker.io/flannel/flannel:v0.25.7
        command:
        - cp
        args:
        - -f
        - /etc/kube-flannel/cni-conf.json
        - /etc/cni/net.d/10-flannel.conflist
        volumeMounts:
        - name: cni
          mountPath: /etc/cni/net.d
        - name: flannel-cfg
          mountPath: /etc/kube-flannel/
      containers:
      - name: kube-flannel
        image: $REGISTRIES/library/docker.io/flannel/flannel:v0.25.7
        command:
        - /opt/bin/flanneld
        args:
        - --ip-masq
        - --kube-subnet-mgr
        resources:
          requests:
            cpu: "100m"
            memory: "50Mi"
        securityContext:
          privileged: false
          capabilities:
            add: ["NET_ADMIN", "NET_RAW"]
        env:
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: POD_NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        - name: EVENT_QUEUE_DEPTH
          value: "5000"
        volumeMounts:
        - name: run
          mountPath: /run/flannel
        - name: flannel-cfg
          mountPath: /etc/kube-flannel/
        - name: xtables-lock
          mountPath: /run/xtables.lock
      volumes:
      - name: run
        hostPath:
          path: /run/flannel
      - name: cni-plugin
        hostPath:
          path: /opt/cni/bin
      - name: cni
        hostPath:
          path: /etc/cni/net.d
      - name: flannel-cfg
        configMap:
          name: kube-flannel-cfg
      - name: xtables-lock
        hostPath:
          path: /run/xtables.lock
          type: FileOrCreate
EOF
#替换最后的网段为新的子网，不与其他k8s集群冲突
sed -i "/net-conf.json/{n;n;s#10.244.0.0\/16#$POD_NET#g}" kube-flannel.yml
kubectl apply -f kube-flannel.yml

echo "12、创建k8s复制用户"
useradd -p `openssl passwd -1 $SCP_PASS` $SCP_USER
yes|cp /etc/kubernetes/admin.conf /opt/kubernetes/
sed -i "/Allow root to run any commands anywhere/ascpacc  ALL=(ALL)\       NOPASSWD: \/usr\/bin\/kubeadm" /etc/sudoers

echo "k8s master节点部署完成！"