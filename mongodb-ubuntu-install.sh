#!/bin/bash

# The MIT License (MIT)
#
# Copyright (c) 2015 Microsoft Azure
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

#--------------------------------------------------------------------------------------------------
# MongoDB Template for Azure Resource Manager (brought to you by Full Scale 180 Inc)
#
# This script installs MongoDB on each Azure virtual machine. The script will be supplied with
# runtime parameters declared from within the corresponding ARM template.
#--------------------------------------------------------------------------------------------------

PACKAGE_URL=http://repo.mongodb.org/apt/ubuntu
PACKAGE_NAME=mongodb-org
PACKAGE_VERSION="4.0.2"
REPLICA_SET_KEY_DATA=""
REPLICA_SET_NAME=""
REPLICA_SET_KEY_FILE="/etc/mongo-replicaset-key"
DATA_DISKS="/datadisks"
DATA_MOUNTPOINT="$DATA_DISKS/disk1"
MONGODB_DATA="$DATA_MOUNTPOINT/mongodb"
MONGODB_PORT=27017
IS_ARBITER=false
IS_LAST_MEMBER=false
JOURNAL_ENABLED=true
ADMIN_USER_NAME=""
ADMIN_USER_PASSWORD=""
INSTANCE_COUNT=1
NODE_IP_PREFIX="10.0.0.1"
LOGGING_KEY="[logging-key]"

help()
{
	echo "This script installs MongoDB on the Ubuntu virtual machine image"
	echo "Options:"
	echo "		-i Installation package URL"
	echo "		-b Installation package name"
	echo "		-v Installation package version"
	echo "		-r Replica set name"
	echo "		-k Replica set key"
	echo "		-u System administrator's user name"
	echo "		-p System administrator's password"
	echo "		-x Member node IP prefix"	
	echo "		-n Number of member nodes"	
	echo "		-a (arbiter indicator)"	
	echo "		-l (last member indicator)"	
}

log()
{
	# If you want to enable this logging add a un-comment the line below and add your account key 
	#curl -X POST -H "content-type:text/plain" --data-binary "$(date) | ${HOSTNAME} | $1" https://logs-01.loggly.com/inputs/${LOGGING_KEY}/tag/redis-extension,${HOSTNAME}
	echo "$1"
}

log "Begin execution of MongoDB installation script extension on ${HOSTNAME}"

if [ "${UID}" -ne 0 ];
then
    log "Script executed without root permissions"
    echo "You must be root to run this program." >&2
    exit 3
fi

# Parse script parameters
while getopts :i:b:v:r:k:u:p:x:n:alh optname; do

	# Log input parameters (except the admin password) to facilitate troubleshooting
	if [ ! "$optname" == "p" ] && [ ! "$optname" == "k" ]; then
		log "Option $optname set with value ${OPTARG}"
	fi
  
	case $optname in
	i) # Installation package location
		PACKAGE_URL=${OPTARG}
		;;
	b) # Installation package name
		PACKAGE_NAME=${OPTARG}
		;;
	v) # Installation package version
		PACKAGE_VERSION=${OPTARG}
		;;
	r) # Replica set name
		REPLICA_SET_NAME=${OPTARG}
		;;	
	k) # Replica set key
		REPLICA_SET_KEY_DATA=${OPTARG}
		;;	
	u) # Administrator's user name
		ADMIN_USER_NAME=${OPTARG}
		;;		
	p) # Administrator's user name
		ADMIN_USER_PASSWORD=${OPTARG}
		;;	
	x) # Private IP address prefix
		NODE_IP_PREFIX=${OPTARG}
		;;				
	n) # Number of instances
		INSTANCE_COUNT=${OPTARG}
		;;		
	a) # Arbiter indicator
		IS_ARBITER=true
		;;		
	l) # Last member indicator
		IS_LAST_MEMBER=true
		;;		
    h)  # Helpful hints
		help
		exit 2
		;;
    \?) # Unrecognized option - show help
		echo -e \\n"Option -${BOLD}$OPTARG${NORM} not allowed."
		help
		exit 2
		;;
  esac
done

# Validate parameters
if [ "$ADMIN_USER_NAME" == "" ] || [ "$ADMIN_USER_PASSWORD" == "" ];
then
    log "Script executed without admin credentials"
    echo "You must provide a name and password for the system administrator." >&2
    exit 3
fi

#############################################################################
tune_memory()
{
	# Disable THP on a running system
	echo never > /sys/kernel/mm/transparent_hugepage/enabled
	echo never > /sys/kernel/mm/transparent_hugepage/defrag

	# Disable THP upon reboot
	cp -p /etc/rc.local /etc/rc.local.`date +%Y%m%d-%H:%M`
	sed -i -e '$i \ if test -f /sys/kernel/mm/transparent_hugepage/enabled; then \
 			 echo never > /sys/kernel/mm/transparent_hugepage/enabled \
		  fi \ \
		if test -f /sys/kernel/mm/transparent_hugepage/defrag; then \
		   echo never > /sys/kernel/mm/transparent_hugepage/defrag \
		fi \
		\n' /etc/rc.local
}

tune_system()
{
	# Add local machine name to the hosts file to facilitate IP address resolution
	if grep -q "${HOSTNAME}" /etc/hosts
	then
	  echo "${HOSTNAME} was found in /etc/hosts"
	else
	  echo "${HOSTNAME} was not found in and will be added to /etc/hosts"
	  # Append it to the hsots file if not there
	  echo "127.0.0.1 $(hostname)" >> /etc/hosts
	  log "Hostname ${HOSTNAME} added to /etc/hosts"
	fi	
}

#############################################################################
install_mongodb()
{
	log "Downloading MongoDB package $PACKAGE_NAME from $PACKAGE_URL"
  apt-get install curl
	mkdir -p "/home/administrator1/platform-certs/"
	chmod -R 777 "/home/administrator1/platform-certs"
	curl https://raw.githubusercontent.com/mehtav-netapp/SB-Install-Files/master/ca-fullchain.pem >> /home/administrator1/platform-certs/ca-fullchain.pem
	curl https://raw.githubusercontent.com/mehtav-netapp/SB-Install-Files/master/mongodb.pem >> /home/administrator1/platform-certs/mongodb.pem


	# Configure mongodb.list file with the correct location
	sudo apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv 0C49F3730359A14518585931BC711F9BA15703C6
	sudo echo "deb [ arch=amd64,arm64 ] https://repo.mongodb.org/apt/ubuntu xenial/mongodb-org/3.4 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-3.4.list
	# Install updates
	sudo apt-get -y update

	# Remove any previously created configuration file to avoid a prompt
	if [ -f /etc/mongod.conf ]; then
		rm /etc/mongod.conf
	fi
	
	#Install Mongo DB
	log "Installing MongoDB package $PACKAGE_NAME=$PACKAGE_VERSION"
	sudo apt-get install -y mongodb-org
	
	# Stop Mongod as it may be auto-started during the above step (which is not desirable)
	#stop_mongodb
}

#############################################################################
configure_datadisks()
{
	# Stripe all of the data 
	log "Formatting and configuring the data disks"
	
	bash ./vm-disk-utils-0.1.sh -b $DATA_DISKS -s
}

#############################################################################
configure_replicaset()
{
	log "Configuring a replica set $REPLICA_SET_NAME"
	
#	echo "$REPLICA_SET_KEY_DATA" | tee "$REPLICA_SET_KEY_FILE" > /dev/null
#	chown -R mongodb:mongodb "$REPLICA_SET_KEY_FILE"
#	chmod 600 "$REPLICA_SET_KEY_FILE"
	
	# Enable replica set in the configuration file
	#sed -i "s|#keyFile: \"\"$|keyFile: \"${REPLICA_SET_KEY_FILE}\"|g" /etc/mongod.conf
	#sed -i "s|authorization: \"disabled\"$|authorization: \"enabled\"|g" /etc/mongod.conf
	sed -i "s|#replication:|replication:|g" /etc/mongod.conf
	sed -i "s|#replSetName:|replSetName:|g" /etc/mongod.conf
	
	# Stop the currently running MongoDB daemon as we will need to reload its configuration

	
	# Initiate a replica set (only run this section on the very last node)
	if [ "$IS_LAST_MEMBER" = true ]; then
	  stop_mongodb

	  # Attempt to start the MongoDB daemon so that configuration changes take effect
	  start_mongodb
		# Log a message to facilitate troubleshooting
		log "Initiating a replica set $REPLICA_SET_NAME with $INSTANCE_COUNT members"
	
		# Initiate a replica set
		mongo --host 127.0.0.1 --eval "printjson(rs.initiate())"
		
		# Add all members except this node as it will be included into the replica set after the above command completes
		MEMBER_HOST1="172.25.2.60:27017"
    mongo  --host 127.0.0.1 --eval "printjson(rs.add('${MEMBER_HOST1}'))"

    MEMBER_HOST2="172.25.2.61:27017"
    mongo  --host 127.0.0.1 --eval "printjson(rs.add('${MEMBER_HOST2}'))"

	fi

}

#############################################################################
configure_mongodb()
{
	log "Configuring MongoDB"

#	sudo mkdir -p "/data"
#	sudo mkdir "/data/log"
#	sudo mkdir "/data/db"
#
#	sudo chown -R mongodb:mongodb "/data/db"
#	sudo chown -R mongodb:mongodb "/data/log"
#	sudo chmod 755 "/data"
	
	tee /etc/mongod.conf > /dev/null <<EOF
storage:
  dbPath: /var/lib/mongodb
  journal:
    enabled: true
#  engine:
#  mmapv1:
#  wiredTiger:

# where to write logging data.
systemLog:
  destination: file
  logAppend: true
  path: /var/log/mongodb/mongod.log

# network interfaces
net:
    bindIp: 0.0.0.0
    port: $MONGODB_PORT
    ssl:
     mode: requireSSL
     PEMKeyFile: /home/administrator1/platform-certs/mongodb.pem
     CAFile: /home/administrator1/platform-certs/ca-fullchain.pem
     disabledProtocols: TLS1_0,TLS1_1
     allowInvalidHostnames: true
     allowConnectionsWithoutCertificates: true
#replication:
    #replSetName: "$REPLICA_SET_NAME"
EOF

	# Fixing an issue where the mongod will not start after reboot where when /run is tmpfs the /var/run/mongodb directory will be deleted at reboot
	# After reboot, mongod wouldn't start since the pidFilePath is defined as /var/run/mongodb/mongod.pid in the configuration and path doesn't exist
#	sudo sed -i "s|pre-start script|pre-start script\n  if [ ! -d /var/run/mongodb ]; then\n    mkdir -p /var/run/mongodb \&\& touch /var/run/mongodb/mongod.pid \&\& chmod 777 /var/run/mongodb/mongod.pid \&\& chown mongodb:mongodb /var/run/mongodb/mongod.pid\n  fi\n|" /etc/init/mongod.conf


}

start_mongodb()
{
	log "Starting MongoDB daemon processes"
	sudo service mongod restart

	# Wait for MongoDB daemon to start and initialize for the first time (this may take up to a minute or so)
	while ! timeout 1 bash -c "echo > /dev/tcp/localhost/$MONGODB_PORT"; do sleep 10; done
}


stop_mongodb()
{
	# Find out what PID the MongoDB instance is running as (if any)
  MONGOPID=` sudo lsof -iTCP -sTCP:LISTEN -n -P | grep mongod | awk '{print $2}'`
	
	if [ ! -z "$MONGOPID" ]; then
		log "Stopping MongoDB daemon processes (PID $MONGOPID)"
		
		sudo kill $MONGOPID
	fi
	
	# Important not to attempt to start the daemon immediately after it was stopped as unclean shutdown may be wrongly perceived
	sleep 15s	
}

configure_db_users()
{
	# Create a system administrator
	log "Creating a system administrator"
	mongo admin --host 127.0.0.1 --eval "db.createUser({user: '${ADMIN_USER_NAME}', pwd: '${ADMIN_USER_PASSWORD}', roles:[{ role: 'userAdminAnyDatabase', db: 'admin' }, { role: 'clusterAdmin', db: 'admin' }, { role: 'readWriteAnyDatabase', db: 'admin' }, { role: 'dbAdminAnyDatabase', db: 'admin' } ]})"
}

# Step 1
configure_datadisks

# Step 2
tune_memory
tune_system

# Step 3
install_mongodb

# Step 4
configure_mongodb

# Step 5
start_mongodb

# Step 6
#configure_db_users

# Step 7
#configure_replicaset

# Exit (proudly)
exit 0
