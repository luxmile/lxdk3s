#!/bin/bash

. ../.0BASE

LXC_PROFILE=${_LXC_PROFILE:-k3s}
LXC_CONTAINER_MEMORY=${_LXC_CONTAINER_MEMORY:-2GB}
LXC_CONTAINER_CPU=${_LXC_CONTAINER_CPU:-2}

K3SDB_PSWD=${_K3SDB_PSWD:-k3s123}

S=${_SCRIPT_NAME:-script.sh}
T=${_TEMP_PATH:-/tmp/.x}

mkdir -p $T; F=$T/$S

#Delete existing lxc containers
echo "CLEANING: previous setup!"
{
  lxc list | grep CONTAINER | awk '{print $2}' | grep k3s | grep -v zBase | while read i; do lxc delete -f $i; done
  /usr/bin/rm -f $T/kubeconfig $HOME/.kube/config
}
echo -e "Done.\n\n"

#Create K3S LXC Profile
echo "CREATING: k3s profile..."
{
  B=`lxc profile ls | grep $LXC_PROFILE`
  if [ -z "$B" ]; then
    cat > $F << EOF
#!/bin/bash

LXC_PROFILE=${LXC_PROFILE}
LXC_CONTAINER_MEMORY='${LXC_CONTAINER_MEMORY}'
LXC_CONTAINER_CPU=${LXC_CONTAINER_CPU}

lxc profile copy default $LXC_PROFILE
lxc profile set ${LXC_PROFILE} security.privileged true
lxc profile set ${LXC_PROFILE} security.nesting true
lxc profile set ${LXC_PROFILE} limits.memory.swap false
lxc profile set ${LXC_PROFILE} limits.memory ${LXC_CONTAINER_MEMORY}
lxc profile set ${LXC_PROFILE} limits.cpu ${LXC_CONTAINER_CPU}
lxc profile set ${LXC_PROFILE} linux.kernel_modules overlay,nf_nat,ip_tables,ip6_tables,netlink_diag,br_netfilter,xt_conntrack,nf_conntrack,ip_vs,vxlan

cat <<EOT | lxc profile set ${LXC_PROFILE} raw.lxc -
lxc.apparmor.profile = unconfined
lxc.cgroup.devices.allow = a
lxc.mount.auto=proc:rw sys:rw
lxc.cap.drop =
EOT

lxc profile show ${LXC_PROFILE}
EOF
    bash $F
    /usr/bin/rm $F
  fi
}
echo
echo -e "Done.\n\n"

#Create LXC containers
echo "PREPARing: LXC containers..."
{
  _cn=zBasek3sDB
  B=`lxc list | grep CONTAINER | grep $_cn`
  if [ -z "$B" ]; then
    lxc init local:alpine/3.17 $_cn
    lxc start $_cn
    sleep 3
    cat > $F << EOF
apk update && apk upgrade && apk add mariadb mariadb-client curl
/etc/init.d/mariadb setup && rc-service mariadb start
sed 's/skip-networking/#skip-networking\nbind-address=0.0.0.0/g' -i /etc/my.cnf.d/mariadb-server.cnf
rc-service mariadb restart
rc-update add mariadb default
mysql -u root < /tmp/db.sql
rm /tmp/db.sql
EOF
  cat > $T/db.sql << EOF
CREATE USER 'k3s'@'%' IDENTIFIED BY '$K3SDB_PSWD';
GRANT ALL PRIVILEGES ON *.* TO 'k3s'@'%';
CREATE DATABASE k3s CHARACTER SET latin1 COLLATE latin1_swedish_ci;
EOF
    lxc file push $F $_cn/tmp/$S
    lxc file push $T/db.sql $_cn/tmp/db.sql
    lxc exec $_cn -- sh /tmp/$S
    lxc stop $_cn
    /usr/bin/rm $F $T/db.sql
  fi

  _cn=zBasek3sLB
  B=`lxc list | grep CONTAINER | grep $_cn`
  if [ -z "$B" ]; then
    lxc init local:alpine/3.17 $_cn
    lxc start $_cn
    sleep 3
    cat > $F << EOF
apk update && apk upgrade && apk add net-tools haproxy curl
cp -pr /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.orig
rm /tmp/$S
EOF
    lxc file push $F $_cn/tmp/$S
    lxc exec $_cn -- sh /tmp/$S
    lxc stop $_cn
    /usr/bin/rm $F
  fi

  for _cn in zBasek3sM zBasek3sW; do
    B=`lxc list | grep CONTAINER | grep $_cn`
    [ -n "$B" ] && continue
    lxc init local:ubuntu/focal --profile $LXC_PROFILE $_cn
    lxc config device add "${_cn}" "kmsg" unix-char source="/dev/kmsg" path="/dev/kmsg"
    lxc config device add "${_cn}" mem unix-char path=/dev/mem
    lxc start $_cn
    sleep 3
    cat > $F << EOF
apt update && apt install openssl curl -y
rm /tmp/$S
EOF
    lxc file push $F $_cn/tmp/$S
    lxc exec $_cn -- bash /tmp/$S
    lxc stop $_cn
  done

  _cn=zBasek3sM
  for cn in k3sM1 k3sM2; do
    lxc copy $_cn $cn
    lxc start $cn
  done

  _cn=zBasek3sW
  for cn in k3sW1 k3sW2 k3sW3; do
    lxc copy $_cn $cn
    lxc start $cn
  done
  sleep 6
}
echo
echo -e "Done.\n\n"

#Setup MYSQL K3S DataSTORE
echo "SETUP: DB datastore..."
{
  _cn=k3sDB
  lxc copy zBase${_cn} $_cn
  lxc start $_cn
  sleep 3
}
echo -e "Done.\n\n"

#Setup LB
echo "SETUP: load balancer..."
{
  _cn="k3sLB"
  lxc copy zBase${_cn} $_cn
  lxc start $_cn
  sleep 3
  cat > $F << EOF
cat /tmp/haproxy.cfg.append >> /etc/haproxy/haproxy.cfg
/etc/init.d/haproxy start
EOF
  lb_ip=`lxc list | grep sLB | grep CONTAINER | grep -v zBase | awk '{print $6}'`
  k3sM1_ip=`lxc list | grep sM1 | grep CONTAINER | grep -v zBase | awk '{print $6}'`
  k3sM2_ip=`lxc list | grep sM2 | grep CONTAINER | grep -v zBase | awk '{print $6}'`
  cat > $T/haproxy.cfg.append << EOF
listen kubernetes-apiserver-https
  bind $lb_ip:6443
  mode tcp
  option log-health-checks
  timeout client 3h
  timeout server 3h
  server k3sM1 $k3sM1_ip:6443 check check-ssl verify none inter 10000
  server k3sM2 $k3sM2_ip:6443 check check-ssl verify none inter 10000
  balance roundrobin
EOF
  lxc file push $T/haproxy.cfg.append $_cn/tmp/haproxy.cfg.append
  lxc file push $F $_cn/tmp/$S
  lxc exec $_cn -- sh /tmp/$S
  sleep 3
  /usr/bin/rm $T/haproxy.cfg.append $F
}
echo
echo -e "Done.\n\n"

#Setup K3S master nodes
echo "SETUP: k3s master nodes..."
{
  LB_ip=`lxc list | grep sLB | grep CONTAINER | grep -v zBase | awk '{print $6}'`
  DB_ip=`lxc list | grep sDB | grep CONTAINER | grep -v zBase | awk '{print $6}'`
  cat > $F << EOF
export K3S_DATASTORE_ENDPOINT='mysql://k3s:$K3SDB_PSWD@tcp($DB_ip:3306)/k3s'
curl -sfL https://get.k3s.io | sh -s - server --disable servicelb --node-taint CriticalAddonsOnly=true:NoExecute --tls-san $LB_ip
/usr/bin/rm /tmp/$S
EOF
  _cn=k3sM1
  lxc file push $F $_cn/tmp/$S
  lxc exec $_cn -- bash /tmp/$S
  lxc file pull $_cn/etc/rancher/k3s/k3s.yaml $T/k3s.yaml
  sed "s/127.0.0.1/$LB_ip/g" $T/k3s.yaml > $T/kubeconfig

  TOKEN=$(lxc exec $_cn -- sh -c "cat /var/lib/rancher/k3s/server/node-token")
  cat > $F << EOF
export K3S_DATASTORE_ENDPOINT='mysql://k3s:k3s123@tcp($DB_ip:3306)/k3s'
curl -sfL https://get.k3s.io | sh -s - server -s https://${LB_ip}:6443 -t ${TOKEN} --disable servicelb --node-taint CriticalAddonsOnly=true:NoExecute --tls-san $LB_ip
/usr/bin/rm /tmp/$S
EOF
  cn=k3sM2
  lxc file push $F $cn/tmp/$S
  lxc exec $cn -- bash /tmp/$S
  /usr/bin/rm -f $F $T/k3s.yaml
}
echo
echo -e "Done.\n\n"

#Setup K3S worker nodes
echo "Setup K3S Worker nodes..."
{
  K3S_MASTER_IP=`lxc list | grep -v zBase | grep sLB | grep CONTAINER | awk '{print $6}'`
  K3S_MASTER_NAME=k3sM1
  K3S_TOKEN_VALUE=$(lxc exec $K3S_MASTER_NAME -- sh -c "cat /var/lib/rancher/k3s/server/node-token")
  cat > $F << EOF
curl -sfL https://get.k3s.io | K3S_URL=https://$K3S_MASTER_IP:6443 K3S_TOKEN=$K3S_TOKEN_VALUE sh -
/usr/bin/rm /tmp/$S
EOF
  for _cn in k3sW1 k3sW2 k3sW3; do
    lxc file push $F $_cn/tmp/$S
    lxc exec $_cn -- bash /tmp/$S
  done
  /usr/bin/rm $F
}
echo
echo -e "Done.\n\n"

#Install Kubeconfig
echo "Install Kubeconfig..."
{
  mkdir -p $HOME/.kube
  /usr/bin/cp $T/kubeconfig $HOME/.kube/config
  /usr/bin/rm $T/kubeconfig
  [ -x /usr/local/bin/kubectl ] || {
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
    /usr/bin/rm kubctl
  }
}
echo
echo -e "Done.\n\n"

#Deploy MetalLB
echo "Deploy MetalLB..."
{
  kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.9.6/manifests/namespace.yaml
  kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.9.6/manifests/metallb.yaml
  # On first install only
  kubectl create secret generic -n metallb-system memberlist --from-literal=secretkey="$(openssl rand -base64 128)"

  cluster_subnet=`lxc list | grep CONTAINER | grep eth0 | grep -v zBase | grep sLB | awk '{print $6}' | cut -f1-3 -d'.'`
  cat << EOF > configmap-metallb.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  namespace: metallb-system
  name: config
data:
  config: |
    address-pools:
    - name: default
      protocol: layer2
      addresses:
      - $cluster_subnet.230-$cluster_subnet.250
EOF
  kubectl apply -f configmap-metallb.yaml
  /usr/bin/rm configmap-metallb.yaml
}
echo
echo -e "Done.\n\n"

