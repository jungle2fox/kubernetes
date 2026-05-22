#k8s初始化worker节点，请修改以下变量配置，在worker节点机执行
#! /bin/sh
REGISTRIES=192.168.1.11 #docker仓库地址
KUB_MASTER=<master节点ip>
DOCKER_VERSION=20.10.17
KUB_VERSION=1.22.13
SCP_USER=scp
SCP_PASS=xxx
HUB_USER=xxx
HUB_PASS=xxx


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

echo "6、修改yum源"
wget -O /etc/yum.repos.d/CentOS-aliyun.repo http://mirrors.aliyun.com/repo/Centos-7.repo &&
yes|mv /etc/yum.repos.d/CentOS-aliyun.repo /etc/yum.repos.d/CentOS-Base.repo &&
yum clean all && yum makecache

echo "7、安装指定版本docker"
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
  rsync -avzP /var/lib/docker /home/docker/lib/ &&
  DOCKER_MIG=$(grep "\-\-graph" /lib/systemd/system/docker.service)
  if [ ! -n "$DOCKER_MIG" ];then
    sed -i 's/containerd.sock/& --graph=\/home\/docker\/lib\/docker/g' /lib/systemd/system/docker.service 
  fi
fi

echo "8、允许http方式推送镜像..."
cat << EOF > /etc/docker/daemon.json
{
  "registry-mirrors": ["https://v16stybc.mirror.aliyuncs.com"],
  "exec-opts": ["native.cgroupdriver=systemd"],
  "insecure-registries":["$REGISTRIES"]
}
EOF
systemctl daemon-reload
systemctl start docker

echo "9、安装kubernetes（kubectl kubeadm kubelet）"
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

echo "10、初始化k8s组件"
for i in `kubeadm config images list|egrep "proxy|pause"`; do
  # 移除路径只保留镜像名和版本
  image=${i#*/}
  new_image="$REGISTRIES/library/k8s.gcr.io/$image"
  docker pull $new_image
  docker tag $new_image $i
  docker rmi $new_image
done

docker images
docker login -u $HUB_USER -p $HUB_PASS $REGISTRIES

echo "11、拷贝master配置"
useradd -p `openssl passwd -1 $SCP_PASS` $SCP_USER
yum -y install sshpass
sshpass -p $SCP_PASS scp -o StrictHostKeyChecking=no $SCP_USER@$KUB_MASTER:/etc/kubernetes/admin.conf /etc/kubernetes/
mkdir -p $HOME/.kube
yes|sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
echo "$(sshpass -p $SCP_PASS ssh $SCP_USER@$KUB_MASTER sudo kubeadm token create --ttl 0 --print-join-command) --ignore-preflight-errors=all" | sh

echo "k8s worker节点部署完成！"