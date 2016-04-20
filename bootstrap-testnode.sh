#!/usr/bin/env bash

# bootstrap script for all nodes inside the simulation

# setup instructions for vagrant to install a local VM with debian sid that works as a Freifunk node
# use this file with
# # vagrant up testnode

# This is mainly taken from https://pad.freifunk.net/p/fastd_anbindung

# enable output what is executed:
set -x

MACHINE=$1
FASTD_PORT=$2
MESH_CODE=$3
MESH_MTU=$4
COUNTER=$5
IP_RANGE=$6

SCRIPTPATH="/vagrant"
MACHINE_PATH="$SCRIPTPATH/machines/${MACHINE}/"
mkdir -p "$MACHINE_PATH"

## generate a MAC address
# Uppercase:
#MAC=$(printf '%02X:%02X:%02X:%02X:%02X:%02X\n' $[RANDOM%256] $[RANDOM%256] $[RANDOM%256] $[RANDOM%256] $[RANDOM%256] $[RANDOM%256])
# oder $(hexdump -n6 -e '/1 ":%02X"' /dev/random|sed s/^://g)
# lower case: 
MAC=$(od /dev/urandom -w6 -tx1 -An|sed -e 's/ //' -e 's/ /:/g'|head -n 1)


cat > /etc/apt/sources.list << EOF
deb http://ftp.de.debian.org/debian wheezy main
deb-src http://ftp.de.debian.org/debian wheezy main

deb http://security.debian.org/ wheezy/updates main contrib
deb-src http://security.debian.org/ wheezy/updates main contrib

# wheezy-updates, previously known as 'volatile'
deb http://ftp.de.debian.org/debian wheezy-updates main contrib
deb-src http://ftp.de.debian.org/debian wheezy-updates main contrib
EOF

# install packages without user interaction:
export DEBIAN_FRONTEND=noninteractive

#apt-get update
# remove unnessecary packages (source https://wiki.debian.org/ReduceDebian#Remove_non-critical_packages)
#apt-get remove --purge -y aspell aspell-en cupsys-client cupsys-bsd debian-faq* doc-debian eject hplip iamerican ibritish info ispell laptop-detect manpages mutt ppp pppconfig pppoe pppoeconf reportbug w3m 
#apt-get autoremove -y

#Reconfigure apt so that it does not install additional packages
echo 'APT::Install-Recommends "0" ; APT::Install-Suggests "0" ; '>>/etc/apt/apt.conf

apt-get install --no-install-recommends -y puppet git tcpdump mtr-tiny vim unzip zip apt-transport-https

# PPA for fastd and batman-adv
echo "deb https://repo.universe-factory.net/debian/ sid main" > /etc/apt/sources.list.d/batman-adv-universe-factory.net.list
apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 16EF3F64CB201D9C
apt-get update

# fastd installieren:

# wheezy-Backports for libjson-c2 ( fastd >= 15)
echo "deb http://http.debian.net/debian wheezy-backports main" > /etc/apt/sources.list.d/wheezy-backports.list
gpg --keyserver pgpkeys.mit.edu --recv-key 16EF3F64CB201D9C
gpg -a --export 16EF3F64CB201D9C | apt-key add -

# moved wget http://download.opensuse.org/repositories/home:fusselkater:ffms/Debian_7.0/Release.key
wget http://download.opensuse.org/repositories/home:fusselkater:/ffms/Debian_7.0/Release.key -O - | apt-key add - 
apt-get update
apt-get install -y fastd

useradd --system --no-create-home --shell /bin/false fastd
mkdir /var/log/fastd

cd $MACHINE_PATH

# fasd-key generieren
NODE_FASTD_PUB_KEY=${SCRIPTPATH}/fastd/gc/${MACHINE}
fastd --generate-key > /tmp/fastdkeys.tmp
echo 'secret "'$(cat /tmp/fastdkeys.tmp|grep Secret|sed "s/Secret: //g")'";' > ${MACHINE_PATH}/fastd-secret.conf
echo 'key "'$(cat /tmp/fastdkeys.tmp|grep Public|sed "s/Public: //g")'";' > ${NODE_FASTD_PUB_KEY}
git add ${NODE_FASTD_PUB_KEY}
git commit ${NODE_FASTD_PUB_KEY} -m "${MACHINE} key generated"

cat > /etc/fastd/${MESH_CODE}/fastd.conf  << EOF
log to syslog level error;
log to syslog as "fastd-debug" level debug;
interface "${MESH_CODE}-mesh-vpn";
method "salsa2012+umac"; # since fastd v15
method "salsa2012+gmac";
method "xsalsa20-poly1305"; # deprecated
bind any:${FASTD_PORT};
hide ip addresses yes;
hide mac addresses yes;
include "${MACHINE_PATH}/fastd-secret.conf";
mtu ${MESH_MTU}; # 1492 - IPv{4,6} Header - fastd Header...
status socket "/var/run/fastd-status.${MESH_CODE}.sock";
include peers from "${SCRIPTPATH}/fastd/gc";
on up "
	modprobe batman-adv
	ip link set address ${MAC} dev \$INTERFACE
	/usr/sbin/batctl -m bat-${MESH_CODE} if add \$INTERFACE
	ip link set address ${MAC} dev bat-${MESH_CODE}
	ifup bat-${MESH_CODE}
	ip link set up dev \$INTERFACE
	service alfred start bat-${MESH_CODE}
";
EOF

#install bridge utils for networking; kernel headers and build-essential for make
apt-get install -y bridge-utils build-essential linux-headers-$(uname -r)


: "install batman"
# keine offizielle Batman-Adv Version verwenden, Clients müssen die Optimierte Version aus dem Gluon Repo verwenden.
cd /tmp/
wget https://github.com/freifunk-gluon/batman-adv-legacy/archive/master.zip
rm -Rf batman-adv-legacy-master
unzip master.zip
cd /tmp/batman-adv-legacy-master/
make
make install

: "add batman-adv in modules if not exists"
LINE="batman-adv"
FILE=/etc/modules
grep -q "$LINE" "$FILE" || echo "$LINE" >> "$FILE"

apt-get install -y batctl
modprobe batman-adv
batctl -v

# add devices into /etc/network/interfaces
LINE="iface br0 inet dhcp"
FILE=/etc/network/interfaces
grep -q "$LINE" "$FILE" || cat >> "$FILE" << EOF
#BOOTSTRAP-BEGIN
auto br0

iface br0 inet static
        ${IP_RANGE}.20${$COUNTER}
#        hwaddress ether ${MAC}
        bridge_ports none
        bridge_stp no

iface br0 inet6 auto
#BOOTSTRAP-END
EOF

# br0 starten und fastd in betrieb nehmen
ifup br0

/etc/init.d/fastd restart


# adapt /etc/sysctl.conf
cat > /etc/sysctl.conf << EOF
net.ipv4.conf.default.rp_filter=0
net.ipv4.conf.all.rp_filter=0
net.ipv4.tcp_syncookies=1
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
net.ipv4.conf.all.accept_redirects = 1
net.ipv6.conf.all.accept_redirects = 1
net.ipv4.conf.all.secure_redirects = 1
net.ipv4.conf.all.send_redirects = 1
net.ipv4.conf.all.accept_source_route = 1
net.ipv6.conf.all.accept_source_route = 1
net.ipv4.conf.all.log_martians = 1
net.bridge.bridge-nf-call-arptables = 0
net.bridge.bridge-nf-call-ip6tables = 0
net.bridge.bridge-nf-call-iptables = 0
net.ipv6.conf.all.autoconf = 1
net.ipv6.conf.default.autoconf = 1
net.ipv6.conf.eth0.autoconf = 1
net.ipv6.conf.all.accept_ra = 1
net.ipv6.conf.default.accept_ra = 1
net.ipv6.conf.eth0.accept_ra = 1
EOF

# nun noch laden 
sysctl -p

#cd "$MACHINE_PATH"
#cp -r * /root
#cd /root

# in case anything goes wrong, delete the lines in nano /etc/network/interfaces and in /etc/modules
# otherwise you cannot start networking and though not login to your machine!

source $SCRIPTPATH/minify_debian.sh
