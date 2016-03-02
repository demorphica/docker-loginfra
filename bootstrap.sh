#!/bin/bash
echo
echo "################################################################################"
echo "### Broker Docker logging infrastructure bootstrap for RHEL 7                 ##"
echo "################################################################################"
echo

kernel=$(uname -r | cut -c1-4)
arch=$(uname -m)
kernel_min=3.1
IP_addr=$(curl -s checkip.dyndns.org|sed -e 's/.*Current IP Address: //' -e 's/<.*$//')
kern=$(awk "BEGIN {print $kernel - $kernel_min}")
basedir="/opt/ibm/broker/docker"
tmpdir="/tmp/_bootstraptmp"

rm -rf $tmpdir
rm -rf $basedir
mkdir -p $tmpdir
mkdir -p $basedir


cd $tmpdir
git clone https://github.com/demorphica/docker-loginfra.git
cd $tmpdir/docker-loginfra/
cp -Rv $tmpdir/docker-loginfra/* $basedir
mkdir -p $basedir/elk-stack

echo
echo "#######################################################################################################################"
echo "#######################################################################################################################"
echo $(uname -a)
echo "Public IP Address: "$IP_addr
echo "#######################################################################################################################"
echo "#######################################################################################################################"
echo 


#flush all existing containers, images
echo
echo "#######################################################################################################################"
echo "#        Cleanup? WARNING: This will remove all existing docker containers...                                         #"
echo "#             type Ctrl+C to exit if you wish to backup before cleanup                                                #"
echo "# type "n" to try to setup the environment without cleanup, some containers that already exist will not be redeployed #"
echo "#######################################################################################################################"
echo 
echo -n " (Do you want to remove all existing Docker containers on this host y/n)? "
read answer
if echo "$answer" | grep -iq "^y" ;then
    docker kill $(docker ps -aq)
    docker rm --force $(docker ps -aq)
fi

echo
echo "#######################################################################################################################"
echo "#        Cleanup? WARNING: This will remove all existing docker images                                                #"
echo "#             type Ctrl+C to exit if you wish to backup before cleanup                                                #"
echo "# type "n" to try to setup the environment without cleanup, some containers that already exist will not be redeployed #"
echo "#######################################################################################################################"
echo 
echo -n " (Do you want to remove all existing Docker images on this host y/n)? "
read answer
if echo "$answer" | grep -iq "^y" ;then
    docker rmi --force $(docker images -aq)    
fi

echo
echo "#######################################################################################################################"
echo "#        Restart Docker Services? WARNING: This will also fliush iptables                                             #"
echo "#######################################################################################################################"
echo 
echo -n " (Do you want to restart the Docker services y/n)? "
read answer
if echo "$answer" | grep -iq "^y" ;then
    service docker restart
fi


#install Docker Engine & required containers
echo
echo "#######################################################################################################################"
echo "#        Installing...                                                                                                #"
echo "#######################################################################################################################"
echo 
echo -n " (Install Docker Engine and the containers for the logging infrastructure y/n)? "
read answer
if echo "$answer" | grep -iq "^y" ;then
    if [ $kern >=0 ] && [ "$arch" ==  "x86_64" ];then
        echo "################################################################################"
        echo "##        Creating Docker yum repo ...                                         #"
        echo "################################################################################"
        echo 
        rm /etc/yum.repos.d/docker.repo
        touch /etc/yum.repos.d/docker.repo
        printf '%s\n[dockerrepo]' >>   /etc/yum.repos.d/docker.repo
        printf '%s\n''name=Docker Repository' >>   /etc/yum.repos.d/docker.repo
        printf '%s\n''baseurl=https://yum.dockerproject.org/repo/main/centos/7' >>   /etc/yum.repos.d/docker.repo
        printf '%s\n''enabled=1' >>   /etc/yum.repos.d/docker.repo
        printf '%s\n''gpgcheck=1' >>   /etc/yum.repos.d/docker.repo
        printf '%s\n''gpgkey=https://yum.dockerproject.org/gpg' >>   /etc/yum.repos.d/docker.repo
        
        echo 
        echo "################################################################################"
        echo "#     Updating ...                                                             #"
        echo "################################################################################"
        echo 
        yum -y update
        
        echo 
        echo "################################################################################"
        echo "#  Installing Docker Engine ...                                                #"
        echo "################################################################################"
        echo 
        yum -y install docker-engine net-tools
        chkconfig docker on
        
        echo 
        echo "################################################################################"
        echo "#  Starting Docker service ...                                                 #"
        echo "################################################################################"
        echo 
        service docker start
        sleep 2
        
        echo 
        echo "################################################################################"
        echo "#  Deploying container for Docker UI ...                                       #"
        echo "################################################################################"
        echo 
        docker run -d --name dockerui-local -p 9000:9000 --privileged -v /var/run/docker.sock:/var/run/docker.sock dockerui/dockerui 
        
        echo 
        echo "################################################################################"
        echo "# Deploying local docker repository on localhost:5000 ...                      #"
        echo "################################################################################"
        echo 
        docker run -d -p 5000:5000 --restart=always --name registry registry:2
        
        echo 
        echo "################################################################################"
        echo "#  Deploying container initializer for Docker Compose ...                      #"
        echo "################################################################################"
        echo 
        curl -L https://github.com/docker/compose/releases/download/1.6.0/run.sh > /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose

        echo 
        echo "################################################################################"
        echo "#  Deploying container initializer for ELK ...                                 #"
        echo "################################################################################"
        echo 
        cd $basedir/elk-stack/ && docker-compose up -d 
        
        echo 
        echo "##########################################################################################"
        echo "#  Deploying container for logspout to forward STDOUT & STDERR on  "$IP_addr":55514...   #"
        echo "##########################################################################################"
        echo 
        cd $basedir/logspout/custom/
        docker build -f Dockerfile -t localhost:5000/logspout .
        docker run -d --name="logspout-localhost" -v /var/run/docker.sock:/tmp/docker.sock -e ROUTE_URIS=logstash://$IP_addr:55514 localhost:5000/logspout:latest 
        
        echo 
        echo "################################################################################"
        echo "#  Deploying container for Graphite, Statsd and Graphana ...                   #"
        echo "################################################################################"
        echo 
        docker run --name local-postgres -e POSTGRES_DB=grafana -e POSTGRES_PASSWORD=br0k3r! -d -p 127.0.0.1:5432:5432 postgres:latest
        docker run --name local-mysql -e MYSQL_ROOT_PASSWORD=br0k3r! -e MYSQL_DATABASE=grafana -e MYSQL_USER=grafana -e MYSQL_PASSWORD=br0k3r! -d -p 127.0.0.1:3306:3306 mysql:latest
        cd $basedir/docker-grafana-graphite
        sleep 5
        docker exec -i local-mysql mysql -u root -pbr0k3r! grafana < $basedir/docker-grafana-graphite/sesstable.sql
        docker build -f Dockerfile -t localhost:5000/grafana-dashboard .
        docker run \
            --name local-dashboard \
            --link local-mysql:mysql \
            --link local-postgres:postgres \
            --link elkstack_elk_1:elk \
            -d \
            -p 0.0.0.0:80:80 \
            -p 0.0.0.0:81:81 \
            -p 127.0.0.1:7002:7002 \
            -p 127.0.0.1:8000:8000 \
            -p 127.0.0.1:8125:8125/udp \
            -p 127.0.0.1:8126:8126 \
            -p 127.0.0.1:2003:2003 \
            -p 127.0.0.1::2003:2003/udp \
            -p 127.0.0.1:2004:2004 \
            -p 127.0.0.1::2013:2013 \            
            -p 127.0.0.1::2013:2013/udp \
            -p 127.0.0.1:2014:2014 \
                localhost:5000/grafana-dashboard

    else
        echo "#############################################################################################"
        echo "LXC and Docker requires a 64bit operating system running at least a 3.10 kernel release !   #"
        echo "bootstrap will exit                                                                         #"
        echo "#############################################################################################"
        exit
    fi
else
    exit
fi
rm -rf $tmpdir
echo 
echo "################################################################################################################"
echo "# Docker Engine, Docker UI and Docker Compose, Fluentd and Graphite dashboard containers are are now available!#"
echo "################################################################################################################"
echo 
echo
echo "Bootstrap will exit."

