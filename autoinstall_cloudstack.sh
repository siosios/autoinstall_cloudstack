#!/bin/bash

# Formatting Colors and text
COLUMNS="$(tput cols)"
R=$(tput setaf 1)
B=$(tput setaf 6)
b=$(tput bold)
N=$(tput sgr0)

SSH_PUBLIC_KEY='insert_your_ssh_public_key_here'

function add_ssh_public_key() {
    cd
    mkdir -p .ssh
    chmod 700 .ssh
    echo -e "$SSH_PUBLIC_KEY" >> .ssh/authorized_keys
    chmod 600 .ssh/authorized_keys
}

echo -e "\n${N}${B}${b}* Current Network Connections\n${N}${B}${b}"
nmcli con show
    sleep 5
    
function get_network_info() {
    echo  -e "\n${N}${B}${b}* CS version\n${N}${B}${b}"
    read -p ' Cloudstack version (ex:4.19) : ' VER 
    echo  -e "\n${N}${B}${b}* password for mysql\n${N}${B}${b}"
    read -p ' mysql password               : ' MYPASS   
    echo  -e "\n${N}${B}${b}* settings for cloud agent\n${N}${B}${b}"
    read -p ' hostname   (ex:cloudstack)   : ' HOSTNAME
    read -p ' IP address   (ex:192.168.1.2): ' IPADDR
    CIDR="$IPADDR/24"
    read -p ' gateway    (ex:192.168.1.1)  : ' GATEWAY
    read -p ' dns1       (ex:192.168.1.1)  : ' DNS1
    read -p ' dns2       (ex:8.8.4.4)      : ' DNS2
    read -p ' net adapter (ex:eno1 or eth0) : ' CON
}   

function get_nfs_info() {
    echo  -e "\n${N}${B}${b}* settings for nfs server\n${N}${B}${b}"
    read -p ' NFS Server IP: ' NFS_SERVER_IP
    read -p ' Primary mount point   (ex:/export/primary)  : ' NFS_SERVER_PRIMARY
    read -p ' Secondary mount point (ex:/export/secondary): ' NFS_SERVER_SECONDARY
}

function get_nfs_network() {
    echo  -e "\n${N}${B}${b}* settings for nfs server\n${N}${B}${b}"
    read -p ' accept access from (ex:192.168.1.0/24): ' NETWORK
}

function install_common() {
    yum update -y && yum upgrade -y
    
    sed -i -e 's/SELINUX=enforcing/SELINUX=permissive/g' /etc/selinux/config
    setenforce permissive
    echo "[cloudstack-$VER]
name=cloudstack
baseurl=http://download.cloudstack.org/centos/9/$VER/
enabled=1
gpgcheck=0" > /etc/yum.repos.d/CloudStack.repo

    
    rpm -i https://dev.mysql.com/get/mysql84-community-release-el9-1.noarch.rpm
    rpm -i https://kojipkgs.fedoraproject.org/packages/bridge-utils/1.7.1/3.el9/x86_64/bridge-utils-1.7.1-3.el9.x86_64.rpm
    dnf install https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm -y
    dnf install https://dl.fedoraproject.org/pub/epel/epel-next-release-latest-9.noarch.rpm -y
    /usr/bin/crb enable
    dnf install chrony wget net-tools curl nfs4-acl-tools nfs-utils firewalld -y
    dnf groupinstall 'Development Tools' -y
    systemctl restart NetworkManager
    systemctl start chronyd
    systemctl enable chronyd

    : > /etc/idmapd.conf
    #sed -i -e "s/localhost/$HOSTNAME localhost/" /etc/hosts
    echo "$IPADDR $HOSTNAME">./temp_hosts
	cat /etc/hosts |tail -n +1 >>./temp_hosts
	cat ./temp_hosts > /etc/hosts
	rm ./temp_hosts
    echo "$HOSTNAME" > /etc/hostname
    echo "Domain = $HOSTNAME" > /etc/idmapd.conf
    
    nmcli c delete cloudbr0 
    nmcli c add type bridge ifname cloudbr0 autoconnect yes con-name cloudbr0 stp on ipv4.addresses $CIDR ipv4.method manual ipv4.gateway $GATEWAY ipv4.dns $DNS1 +ipv4.dns $DNS2 ipv6.method disabled
    nmcli c delete $CON 
    nmcli c add type bridge-slave autoconnect yes con-name $CON ifname $CON master cloudbr0
    nmcli con up $CON
    sleep 3
    

#####Webmin section comment out if not using#####
    curl -o setup-repos.sh https://raw.githubusercontent.com/webmin/webmin/master/setup-repos.sh
    dnf install perl perl-App-cpanminus perl-devel -y
    sh setup-repos.sh
    dnf install webmin -y
	systemctl start webmin
	systemctl enable webmin
#################################################
}

function install_management() {
dnf install cloudstack-management mysql-server perl-DBD-MySQL -y
#initialize the DB
    systemctl start mysqld
    sleep 3
    systemctl stop mysqld
    
    head -7 /etc/my.cnf > /tmp/before
    tail -n +7 /etc/my.cnf > /tmp/after
    cat /tmp/before > /etc/my.cnf
    echo "innodb_rollback_on_timeout=1
innodb_lock_wait_timeout=600
max_connections=350
log-bin=mysql-bin
binlog-format = 'ROW'" >> /etc/my.cnf
    cat /tmp/after >> /etc/my.cnf
    rm -rf /tmp/before /tmp/after

	chown -R mysql:mysql /var/lib/mysql
    dnf install -y mysql-connector-python3
    	
	echo $MYPASS
	echo "ALTER USER 'root'@'localhost' IDENTIFIED BY "$MYPASS";" >| /root/mysql-init
	sed -i -e "s/IDENTIFIED BY $MYPASS;.*/IDENTIFIED BY '$MYPASS';/" /root/mysql-init
    mysqld --user=root --init-file=/root/mysql-init &
    sleep 3
    pkill mysqld
    killall mysqld
    sleep 3
    rm -rf /root/mysql-init
    chown -R mysql:mysql /var/lib/mysql
    sleep 2
    systemctl start mysqld
    systemctl enable mysqld
    perl -MCPAN -e 'install DBI'
    perl -MCPAN -e 'install DBD::mysql'
    
    cloudstack-setup-databases cloud:$MYPASS@localhost --deploy-as=root:$MYPASS
    echo "Defaults:cloud !requiretty" >> /etc/sudoers
    cloudstack-setup-management
    systemctl enable cloudstack-management
}

function install_agent() {
    dnf install cloudstack-agent qemu-kvm libvirt -y
: > /etc/libvirt/libvirtd.conf
: > /etc/libvirt/qemu.conf
: > /etc/sysconfig/rpc-rquotad
: > /etc/sysconfig/libvirtd
systemctl mask libvirtd.socket libvirtd-ro.socket libvirtd-admin.socket libvirtd-tls.socket libvirtd-tcp.socket
systemctl unmask virtqemud.socket virtqemud-ro.socket virtqemud-admin.socket virtqemud-sock
systemctl enable virtqemud
systemctl start  virtqemud

    modprobe kvm-intel
    echo "listen_tls = 0
listen_tcp = 1
tcp_port = \"16509\"
auth_tcp = \"none\"
mdns_adv = 0" >> /etc/libvirt/libvirtd.conf
    echo "vnc_listen=\"0.0.0.0\"" >> /etc/libvirt/qemu.conf
    echo "LIBVIRTD_ARGS=-l" >> /etc/sysconfig/libvirtd
    echo "mode = \"legacy\"" >> /etc/libvirt/libvirt.conf
    
    systemctl enable libvirtd
    systemctl start libvirtd
}

function initialize_storage() {
    dnf install quota-rpc rpcbind -y
    echo "RPCRQUOTADOPTS=\"-p 875\"" >> /etc/sysconfig/rpc-rquotad
    systemctl start rpcbind
    systemctl enable rpcbind
    systemctl start rpc-rquotad
    systemctl enable rpc-rquotad
    : > /etc/exports

    systemctl restart NetworkManager
    mkdir -p $NFS_SERVER_PRIMARY
    mkdir -p $NFS_SERVER_SECONDARY
    mkdir -p /mnt/primary
    mkdir -p /mnt/secondary
    echo "/export  $NETWORK(rw,async,no_root_squash,no_subtree_check)" >> /etc/exports
    exportfs -a
    mount -t nfs ${NFS_SERVER_IP}:${NFS_SERVER_PRIMARY} /mnt/primary
    sleep 10
    mount -t nfs ${NFS_SERVER_IP}:${NFS_SERVER_SECONDARY} /mnt/secondary
    brctl show
    sleep 10
    rm -rf /mnt/primary/*
    rm -rf /mnt/primary/*
    /usr/share/cloudstack-common/scripts/storage/secondary/cloud-install-sys-tmplt -m $NFS_SERVER_SECONDARY -u http://download.cloudstack.org/systemvm/$VER/systemvmtemplate-$VER.0-hyperv.vhd.zip -h hyperv -F
    /usr/share/cloudstack-common/scripts/storage/secondary/cloud-install-sys-tmplt -m $NFS_SERVER_SECONDARY -u http://download.cloudstack.org/systemvm/$VER/systemvmtemplate-$VER.0-xen.vhd.bz2 -h xenserver -F
    /usr/share/cloudstack-common/scripts/storage/secondary/cloud-install-sys-tmplt -m $NFS_SERVER_SECONDARY -u http://download.cloudstack.org/systemvm/$VER/systemvmtemplate-$VER.0-vmware.ova -h vmware -F
    /usr/share/cloudstack-common/scripts/storage/secondary/cloud-install-sys-tmplt -m $NFS_SERVER_SECONDARY -u http://download.cloudstack.org/systemvm/$VER/systemvmtemplate-$VER.0-kvm.qcow2.bz2 -h kvm -F
    /usr/share/cloudstack-common/scripts/storage/secondary/cloud-install-sys-tmplt -m $NFS_SERVER_SECONDARY -u http://download.cloudstack.org/systemvm/$VER/systemvmtemplate-$VER.0-ovm.raw.bz2 -h ovm3 -F
    sync
}

function install_nfs() {

: > /etc/nfs.conf
    echo "[general]
[exportfs]
[gssd]
use-gss-proxy=1
[lockd]
port=32803
udp-port=32769
[mountd]
port=892
[nfsdcld]
[nfsdcltrack]
[nfsd]
[statd]
port=662
outgoing-port=2020
[sm-notify]" >> /etc/nfs.conf
    systemctl start nfs-server
    systemctl enable nfs-server
    
firewall-cmd --zone=public --add-port=111/udp --permanent
firewall-cmd --zone=public --add-port=111/tcp --permanent
firewall-cmd --zone=public --add-port=2049/tcp --permanent
firewall-cmd --zone=public --add-port=32803/tcp --permanent
firewall-cmd --zone=public --add-port=32769/udp --permanent
firewall-cmd --zone=public --add-port=892/tcp --permanent
firewall-cmd --zone=public --add-port=892/udp --permanent
firewall-cmd --zone=public --add-port=875/tcp --permanent
firewall-cmd --zone=public --add-port=875/udp --permanent
firewall-cmd --zone=public --add-port=10000/tcp --permanent
firewall-cmd --zone=public --add-port=8080/tcp --permanent
firewall-cmd --zone=public --add-port=662/tcp --permanent
firewall-cmd --zone=public --add-port=22/tcp --permanent
firewall-cmd --zone=public --add-port=3306/tcp --permanent
firewall-cmd --reload

}

if [ $# -eq 0 ]
then
    OPT_ERROR=1
fi

while getopts "acnmhr" flag; do
    case $flag in
    \?) OPT_ERROR=1; break;;
    h) OPT_ERROR=1; break;;
    a) opt_agent=true;;
    c) opt_common=true;;
    n) opt_nfs=true;;
    m) opt_management=true;;
    r) opt_reboot=true;;
    esac
done

shift $(( $OPTIND - 1 ))

if [ $OPT_ERROR ]
then
    echo >&2 "usage: $0 [-cnamr for install / -h or ? for help]
  -c : install common packages
  -n : install nfs server
  -a : install cloud agent
  -m : install management server
  -h : show this help
  -r : reboot after installation"
    exit 1
fi

if [ "$opt_agent" = "true" ]
then
    get_network_info
fi
if [ "$opt_nfs" = "true" ]
then
    get_nfs_network
fi
if [ "$opt_management" = "true" ]
then
    get_nfs_info
fi


if [ "$opt_common" = "true" ]
then
    add_ssh_public_key
    install_common
fi
if [ "$opt_agent" = "true" ]
then
    install_agent
fi
if [ "$opt_nfs" = "true" ]
then
    install_nfs
fi
if [ "$opt_management" = "true" ]
then
    install_management
    initialize_storage
fi
if [ "$opt_reboot" = "true" ]
then
    sync
    sync
    sync
    reboot
fi
