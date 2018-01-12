#!/bin/bash
# Script for setting up devstack with keystone and barbican, as well
# as swift master (with barbican patch)
# all on a single system. Tested on Ubuntu 16.04.2 x64 VM. User needs
# to have (passwordless) sudo rights.
# Contact: mathiasb on IRC.
set -x
set -e

# Global configuration
DIR_INSTALL=~/
DIR_DEVSTACK=/opt/devstack
DEVSTACK_IP=127.0.0.1
#APT_MIRROR=http://mirror.switch.ch/ftp/mirror
SWIFT_PROXY_USER=swift
SWIFT_PROXY_PASS=swift
SWIFT_PROXY_ENC_USER=swiftenc
SWIFT_PROXY_ENC_PASS=swiftencpass
SWIFT_PROXY_ENC_PROJECT=swiftencproj
SWIFT_USER_USER=swiftuser
SWIFT_USER_PASS=swiftuserpass
SWIFT_USER_PROJECT=swiftuserproject
SWIFT_IP=127.0.0.1
LOOPBACK_DISK=0 # 0 to use loopback device for storage, else use device
SWIFT_DATA_DEVICE=vdb # For /dev/sdb (default), set to sdb
OS_BRANCH=master
DEVSTACK_BRANCH=master

function install_devstack()
{
    # Dependencies
    #sudo sed -i "s@http://archive.ubuntu.com@$APT_MIRROR@g" /etc/apt/sources.list
    sudo apt -y update
    sudo apt -y dist-upgrade
    sudo apt -y install git python-pbr

    # Configure devstack with keystone and barbican
    if [ -d $DIR_DEVSTACK ]
    then
      sudo rm -rf $DIR_DEVSTACK
    fi
    sudo mkdir -p $DIR_DEVSTACK
    sudo mkdir -p /opt/stack
    sudo git clone -b ${DEVSTACK_BRANCH} --single-branch --depth 1 https://git.openstack.org/openstack-dev/devstack $DIR_DEVSTACK
    sudo tee $DIR_DEVSTACK/local.conf << EOF
[[local|localrc]]
enable_plugin barbican https://git.openstack.org/openstack/barbican ${OS_BRANCH}
ADMIN_PASSWORD=admin
DATABASE_PASSWORD=admin
RABBIT_PASSWORD=admin
SERVICE_PASSWORD=\$ADMIN_PASSWORD
SERVICE_TOKEN=\$ADMIN_PASSWORD
KEYSTONE_BRANCH=${OS_BRANCH}
REQUIREMENTS_BRANCH=${OS_BRANCH}
BARBICANCLIENT_BRANCH=${OS_BRANCH}
LOGFILE=/opt/stack/logs/stack.sh.log
LOGDAYS=2
ENABLED_SERVICES=rabbit,mysql,key
VERBOSE=True
HOST_IP=127.0.0.1
EOF
    sudo chown -R "$USER:$GROUPS" $DIR_DEVSTACK
    sudo chown -R "$USER:$GROUPS" /opt/stack
    $DIR_DEVSTACK/stack.sh
}

function cleanup()
{
    sudo apt clean
}

function install_swift()
{
    # This function installs Swift based on SAIO instructions:
    # https://docs.openstack.org/developer/swift/development_saio.html
    # It assumes:
    #  - A separate partition for storing the data (/dev/$DISK)
    # Configuration
    SWIFT=${DIR_INSTALL}swift
    DISK=${SWIFT_DATA_DEVICE}
    SERVICES_IP=$DEVSTACK_IP
    LC_ALL=en_US.UTF-8
    SWIFT_REPO=git://git.openstack.org/openstack/swift
    
    # Enable multiverse repository
    sudo sed -i '/multiverse$/s/^#//' /etc/apt/sources.list
    #sudo sed -i "s@http://archive.ubuntu.com@$APT_MIRROR@g" /etc/apt/sources.list

    # Add Openstack repositories
    sudo apt -y update
    sudo apt -y dist-upgrade

    sudo apt -y install software-properties-common
    sudo add-apt-repository -y cloud-archive:pike
    sudo apt -y update
    sudo apt -y dist-upgrade

    # Swift AIO
    sudo apt -y install curl gcc memcached rsync sqlite3 xfsprogs \
                        git-core libffi-dev python-setuptools \
                        libssl-dev
    sudo apt -y install python-coverage python-dev python-nose \
                        python-xattr python-eventlet \
                        python-greenlet python-pastedeploy \
                        python-netifaces python-pip python-dnspython \
                        python-mock
    sudo apt -y install python-keystonemiddleware python-keystoneclient \
                        python-barbicanclient python-openstackclient

    # Development tools
    sudo apt -y install git git-review gitk git-gui mc htop tmux

    # Tools for building liberasurecode
    sudo apt -y install build-essential autoconf automake libtool
    # Tool for running tests
    sudo apt -y install tox

    # Build and install liberasurecode ourselves
    cd ${DIR_INSTALL}
    if [ ! -d liberasurecode ]
    then
      # Clone latest release of liberasurecode
      git clone -b '1.4.0' --single-branch --depth 1 https://github.com/openstack/liberasurecode.git
    fi
    cd liberasurecode
    git pull
    ./autogen.sh
    ./configure
    make
    sudo make install
    if ! grep "/usr/local/lib" /etc/ld.so.conf ;
    then
      echo "/usr/local/lib" | sudo tee -a /etc/ld.so.conf
    fi
    sudo ldconfig

    if ! grep "/mnt/sdb1" /etc/fstab ;
    then
        # No data disk set up yet, set it up now
        if [ "${LOOPBACK_DISK}" == 0 ]
        then
            # Use loopback device for data storage
            sudo mkdir -p /srv
            sudo truncate -s 1GB /srv/swift-disk
            sudo mkfs.xfs /srv/swift-disk
            echo "/srv/swift-disk /mnt/sdb1 xfs loop,noatime,nodiratime,nobarrier,logbufs=8 0 0" | sudo tee -a /etc/fstab
            sudo mkdir -p /mnt/sdb1
            sudo mount /mnt/sdb1
            sudo mkdir -p /mnt/sdb1/1 /mnt/sdb1/2 /mnt/sdb1/3 /mnt/sdb1/4
            sudo chown ${USER}:${USER} /mnt/sdb1/*
            for x in {1..4}; do sudo ln -s /mnt/sdb1/$x /srv/$x; done
            sudo mkdir -p /srv/1/node/sdb1 /srv/1/node/sdb5 \
                          /srv/2/node/sdb2 /srv/2/node/sdb6 \
                          /srv/3/node/sdb3 /srv/3/node/sdb7 \
                          /srv/4/node/sdb4 /srv/4/node/sdb8 \
                          /var/run/swift
            sudo chown -R ${USER}:${GROUPS} /var/run/swift
            # **Make sure to include the trailing slash after /srv/$x/**
            for x in {1..4}; do sudo chown -R ${USER}:${GROUPS} /srv/$x/; done

        else
            # Use partition for data storage
            sudo parted -s "$DISK" mklabel msdos
            sudo parted -s "$DISK" mkpart primary ext4 0 "100%"
            sudo mkdir -p /mnt/sdb1/{1..4}
            echo "/dev/${DISK}1 /mnt/sdb1 xfs noatime,nodiratime,nobarrier,logbufs=8 0 0" | sudo tee -a /etc/fstab
            sudo mkfs.xfs -m crc=0,finobt=0 "/dev/${DISK}"1
            sudo mount /mnt/sdb1

            sudo mkdir -p /srv
            for x in {1..4}; do
                sudo ln -s /mnt/sdb1/$x /srv/$x;
            done
            sudo chown -R "$USER:$GROUPS" /srv/{1..4}
        fi
    fi

    sudo mkdir -p /var/run/swift
    sudo chown -R "$USER:$GROUPS" /var/run/swift

    if ! grep "mkdir -p /var/cache/swift" /etc/rc.local ;
    then
        # Add stuff to /etc/rc.local if it is not already there
        sudo sed -i '/^exit 0$/s/.*//' /etc/rc.local
        echo "
mkdir -p /var/cache/swift /var/cache/swift2 /var/cache/swift3 /var/cache/swift4
chown $USER:$GROUPS /var/cache/swift*
mkdir -p /var/run/swift
chown $USER:$GROUPS /var/run/swift

exit 0
" | sudo tee -a /etc/rc.local
        # Run the script to create the directories without having to reboot
        sudo /etc/rc.local
    fi

    if [ -d $SWIFT ]
    then
        # Switch to the Barbican patch branch if the swift repo exists
        cd $SWIFT
        git fetch
        cd -
    else
        # Clone the swift repo if it does not exist
        git clone ${SWIFT_REPO} /vagrant/swift
        ln -s /vagrant/swift ${SWIFT}
    fi
    cd $SWIFT
    git checkout master
    cd -

    # Upgrade pip
    sudo pip install --upgrade pip
    sudo apt autoremove -y --purge python-pip

    # Install requirements
    cd ${SWIFT}
    sudo pip install -r requirements.txt
    sudo pip install .[kms_keymaster]
    sudo pip install -r test-requirements.txt
    cd -

    # Set up rsync
    sudo cp ${SWIFT}/doc/saio/rsyncd.conf /etc/
    sudo sed -i "s/<your-user-name>/$USER/" /etc/rsyncd.conf

    sudo sed -i '/RSYNC_ENABLE/s/false/true/' /etc/default/rsync
    sudo service rsync restart

    # Configure swift
    sudo rm -rf /etc/swift
    sudo cp -r ${SWIFT}/doc/saio/swift /etc/swift
    sudo chown -R "$USER:$GROUPS" /etc/swift
    find /etc/swift/ -name '*.conf' -exec sed -i "s/<your-user-name>/$USER/" {} \;

    mkdir -p ${DIR_INSTALL}/bin
    cp ${SWIFT}/doc/saio/bin/* ${DIR_INSTALL}/bin
    chmod +x ${DIR_INSTALL}/bin/*

    cp ${SWIFT}/test/sample.conf /etc/swift/test.conf
    echo "export SWIFT_TEST_CONFIG_FILE=/etc/swift/test.conf" >> ${DIR_INSTALL}/.bashrc
    echo "export PATH=$PATH:\${DIR_INSTALL}/bin" >> ${DIR_INSTALL}/.bashrc
    if [ "${LOOPBACK_DISK}" == 0 ]
    then
        echo "export SAIO_BLOCK_DEVICE=/srv/swift-disk" >> ${DIR_INSTALL}/.bashrc
    fi

    # Use keystone auth instead of tempauth
    sed -i '/^pipeline/s/tempauth //' /etc/swift/proxy-server.conf
    sed -i '/^pipeline/s/\(proxy-logging\)/authtoken keystoneauth \1/2' /etc/swift/proxy-server.conf

    cat >> /etc/swift/proxy-server.conf << EOF

[filter:authtoken]
auth_plugin = password
paste.filter_factory = keystonemiddleware.auth_token:filter_factory
password = swift
username = swift
project_name = service
auth_uri = http://$SERVICES_IP/identity
auth_url = http://$SERVICES_IP/identity
cache = swift.cache
include_service_catalog = False
delay_auth_decision = True
auth_version = v3.0

[filter:keystoneauth]
use = egg:swift#keystoneauth
operator_roles = admin, swiftoperator

EOF

    # Set up crypto
    sed -i '/^pipeline/s/\(proxy-logging\)/kms_keymaster encryption \1/2' /etc/swift/proxy-server.conf

    cat >> /etc/swift/proxy-server.conf << EOF
[filter:kms_keymaster]
use = egg:swift#kms_keymaster
keymaster_config_path = /etc/swift/kms_keymaster.conf

[filter:encryption]
use = egg:swift#encryption
EOF

    cat >> /etc/swift/kms_keymaster.conf << EOF
[kms_keymaster]
username = $SWIFT_PROXY_ENC_USER
password = $SWIFT_PROXY_ENC_PASS
project_name = $SWIFT_PROXY_ENC_PROJECT
project_domain_name = default
user_domain_name = default
auth_endpoint=http://127.0.0.1/identity
# key_id pointing to the root encryption secret in Barbican
EOF
    # Set up logging
    sudo cp ${SWIFT}/doc/saio/rsyslog.d/10-swift.conf /etc/rsyslog.d/
    sudo sed -i "/^\(\$PrivDropToGroup\).*$/s//\1 adm/" /etc/rsyslog.conf
    sudo mkdir -p /var/log/swift
    sudo chown -R "syslog:adm" /var/log/swift
    sudo chmod -R g+w /var/log/swift
    sudo service rsyslog restart
    # Without '/v3' at the end you get:
    # Authorization Failure. Authorization failed: (http://127.0.0.1/identity/auth/tokens): The resource could not be found. (HTTP 404)
    AUTH_URL=http://127.0.0.1/identity/v3

    # Create openrcs.
    rm -f ${DIR_INSTALL}/openrc.admin
    cat >> ${DIR_INSTALL}/openrc.admin << EOF
export OS_AUTH_TYPE=password
export OS_AUTH_URL=${AUTH_URL}
export OS_IDENTITY_API_VERSION=3
export OS_PROJECT_DOMAIN_ID=default
export OS_REGION_NAME=RegionOne
export OS_USER_DOMAIN_ID=default
export OS_VOLUME_API_VERSION=2
export OS_NO_CACHE="1"
export OS_USERNAME=admin
export OS_PASSWORD=admin
export OS_PROJECT_NAME=admin
EOF

    rm -f ${DIR_INSTALL}/openrc.proxy
    cat >> ${DIR_INSTALL}/openrc.proxy << EOF
export OS_AUTH_TYPE=password
export OS_AUTH_URL=${AUTH_URL}
export OS_IDENTITY_API_VERSION=3
export OS_PROJECT_DOMAIN_ID=default
export OS_REGION_NAME=RegionOne
export OS_USER_DOMAIN_ID=default
export OS_VOLUME_API_VERSION=2
export OS_NO_CACHE="1"
export OS_PASSWORD="$SWIFT_PROXY_ENC_PASS"
export OS_PROJECT_NAME="$SWIFT_PROXY_ENC_PROJECT"
export OS_USERNAME="$SWIFT_PROXY_ENC_USER"
EOF

    rm -f ${DIR_INSTALL}/openrc.swiftuser
    cat >> ${DIR_INSTALL}/openrc.swiftuser << EOF
export OS_AUTH_TYPE=password
export OS_AUTH_URL=${AUTH_URL}
export OS_IDENTITY_API_VERSION=3
export OS_PROJECT_DOMAIN_ID=default
export OS_REGION_NAME=RegionOne
export OS_USER_DOMAIN_ID=default
export OS_VOLUME_API_VERSION=2
export OS_NO_CACHE="1"
export OS_PASSWORD="$SWIFT_USER_PASS"
export OS_PROJECT_NAME="$SWIFT_USER_PROJECT"
export OS_USERNAME="$SWIFT_USER_USER"
EOF

    sudo apt install -y python-swiftclient
    sudo apt clean

    if [ "${LOOPBACK_DISK}" == 0 ]
    then
        sed -i "/^sudo mkfs/s/sdb/${DISK}/" ${DIR_INSTALL}/bin/resetswift
    fi
}


function setup_keystone_and_barbican()
{
    source ${DIR_INSTALL}/openrc.admin
    SWIFT_PROXY_ENC_USER=swiftenc
    SWIFT_PROXY_ENC_PASS=swiftencpass
    SWIFT_PROXY_ENC_PROJECT=swiftencproj

    # Create the object-store service and a project and user for the
    # Swift proxy server for managing the root encryption secret.
    openstack service create --name=object-store --description="Swift Service" object-store
    
    # Create regular Swift user and project for proxy to manage users
    # These need to match the authtoken settings in proxy-server.conf
    openstack user create $SWIFT_PROXY_USER --password $SWIFT_PROXY_PASS --project service
    openstack role add admin --project service --user $SWIFT_PROXY_USER
    
    # Create user and project for Swift to access Barbican secret
    openstack project create --enable "${SWIFT_PROXY_ENC_PROJECT}"
    openstack user create --password ${SWIFT_PROXY_ENC_PASS} --project ${SWIFT_PROXY_ENC_PROJECT} --enable ${SWIFT_PROXY_ENC_USER}
    openstack role add --project ${SWIFT_PROXY_ENC_PROJECT} --user ${SWIFT_PROXY_ENC_USER} admin
    openstack endpoint create --region RegionOne object-store public "http://${SWIFT_IP}:8080/v1/AUTH_%(tenant_id)s"
    openstack endpoint create --region RegionOne object-store internal "http://${SWIFT_IP}:8080/v1/AUTH_%(tenant_id)s"
    openstack endpoint create --region RegionOne object-store admin "http://${SWIFT_IP}:8080"
    
    # Create Swift end user for storing objects
    openstack project create --enable "${SWIFT_USER_PROJECT}"
    openstack user create --password ${SWIFT_USER_PASS} --project ${SWIFT_USER_PROJECT} --enable ${SWIFT_USER_USER}
    openstack role add --project ${SWIFT_USER_PROJECT} --user ${SWIFT_USER_USER} admin
}

function create_key_in_barbican()
{
    source ${DIR_INSTALL}/openrc.proxy
    ORDER_HREF=`openstack secret order create --name swift_root_secret --payload-content-type="application/octet-stream" --algorithm aes --bit-length 256 --mode ctr key -f value -c 'Order href'`
    SECRET_HREF=`openstack secret order get -f value -c 'Secret href' "${ORDER_HREF}"`
    KEY_ID="${SECRET_HREF##*/}"
    echo "key_id = ${KEY_ID}" >> /etc/swift/kms_keymaster.conf
}


function start_swift()
{
    if [ "${LOOPBACK_DISK}" == 0 ]
    then
        export SAIO_BLOCK_DEVICE=/srv/swift-disk
    fi
    ${DIR_INSTALL}/bin/resetswift
    ${DIR_INSTALL}/bin/remakerings
    ${DIR_INSTALL}/bin/startmain
    ${DIR_INSTALL}/bin/startrest
}

function store_object()
{
    source ${DIR_INSTALL}/openrc.swiftuser
    swift upload 1 ${DIR_INSTALL}/openrc.swiftuser
}

function show_object_info()
{
    find /mnt/ -type f -name "*.data" | tail -n 1 | xargs swift-object-info
}

function cleanup_usage()
{
    set +x
    set +e
    echo "To cleanup after running this script (e.g., prior to running"
    echo "it again), perform the following steps:"
    echo "# Stop the swift processes:"
    echo "    swift-init all stop"
    echo "# Unstack devstack:"
    echo "    /opt/devstack/unstack.sh"
    echo "# Clean up from devstack:"
    echo "    /opt/devstack/clean.sh"
    echo "# Remove devstack directory:"
    echo "    sudo rm -rf /opt/devstack/"
    echo "# Remove stack directory:"
    echo "    sudo rm -rf /opt/stack/"
    echo "# Unmount the swift storage:"
    echo "    sudo umount /mnt/sdb1"
    echo "# Remove /etc/fstab entry for /mnt/sdb1"
    echo "# Remove /srv/{1..4} directories"
    echo "# Remove /mnt/sdb1 directory"
    echo "# Remove /var/cache/swift*"
    echo "# Remove /var/run/swift"
    echo "# Remove everything in ${DIR_INSTALL} (except this file)"
    exit 1
}

function usage()
{
    set +x
    set +e
    echo "This script sets up devstack with Keystone and Barbican, and"
    echo " separately sets up Swift with the Barbican patch (364878) to"
    echo "retrieve the encryption root secret from Barbican."
    echo "The script creates three users in Keystone (in addition to"
    echo "admin):"
    echo " - swift proxy user"
    echo " - swift proxy encryption key manager user"
    echo " - swift object storage user"
    echo "The script also creates an encryption root secret in Barbican"
    echo "and configured the Swift proxy server to use it for"
    echo "encryption."
    echo "Make sure git review and SSH keys are correctly set up."
    echo ""
    echo "Usage:"
    echo "   $0 <option>"
    echo "Where valid values for option are:"
    echo "   devstack   Install devstack with keystone and barbican"
    echo "   swift      Install swift with Barbican patch"
    echo "   keystone   Configure users, projects and roles"
    echo "   createkey  Create a root encryption secret in Barbican"
    echo "   startswift Start swift"
    echo "   storeobj   Store an object in swift"
    echo "   showobj    Show information about a stored object"
    echo "   all        Do all of the above"
    echo "   cleanup    Show information about what/how to clean up"
    echo "Most options depend on the options above it having been set"
    echo "up successfully, e.g., 'swift' needs to be run before"
    echo "'startswift' can be executed."
    echo ""
    echo -n "The script will currently use "
    if [ "${LOOPBACK_DISK}" == 0 ]
    then
        echo "a file '/srv/swift-disk' for data storage."
    else
        echo "the /dev/${SWIFT_DATA_DEVICE} for data storage."
    fi
    echo "Change the LOOPBACK_DISK and SWIFT_DATA_DEVICE variables in"
    echo "the script to change the above behavior."
    exit 1
}

if [ "$1" == "" ]
then
    usage
fi
if [ "$1" == "cleanup" ]
then
    cleanup_usage
fi
if [ "$1" == "all" ] || [ "$1" == "devstack" ]
then
    install_devstack
fi
if [ "$1" == "all" ] || [ "$1" == "swift" ]
then
    install_swift
fi
if [ "$1" == "all" ] || [ "$1" == "keystone" ]
then
    setup_keystone_and_barbican
fi
if [ "$1" == "all" ] || [ "$1" == "createkey" ]
then
    create_key_in_barbican
fi
if [ "$1" == "all" ] || [ "$1" == "startswift" ]
then
    start_swift
fi
if [ "$1" == "all" ] || [ "$1" == "storeobj" ]
then
    store_object
fi
if [ "$1" == "all" ] || [ "$1" == "showobj" ]
then
    show_object_info
fi
