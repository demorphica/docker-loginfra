#!/bin/bash
echo
echo "################################################################################"
echo "### Broker Docker infrastructure bootstrap for RHEL 7                         ##"
echo "################################################################################"
echo

kernel=$(uname -r | cut -c1-4)
arch=$(uname -m)
kernel_min=3.1
IP_addr=$(curl -s checkip.dyndns.org|sed -e 's/.*Current IP Address: //' -e 's/<.*$//')
kern=$(awk "BEGIN {print $kernel - $kernel_min}")
basedir="/opt/ibm/broker/docker"
tmpdir="/tmp/_bootstraptmp"

mkdir -p $tmpdir
mkdir -p $basedir


cd $tmpdir
git clone https://github.com/demorphica/docker-loginfra.git
cd $tmpdir/docker-loginfra/
cp -Rv $tmpdir/docker-loginfra/* $basedir
mkdir -p $basedir/elk-stack

echo
echo "#######################################################################################################################"
echo $(uname -a)
echo "Public IP Address: "$IP_addr
echo "#######################################################################################################################"
echo 


#flush all existing containers, images
echo
echo "#######################################################################################################################"
echo "#        Cleanup? WARNING: This will remove all existing docker containers...                              #"
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


#install Docker Engine

echo -n " (Install Docker Engine y/n)? "
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
        echo "#  Deploying container initializer for ELK ...                      #"
        echo "################################################################################"
        echo 
        
        curl -Lso $basedir/elk-stack/docker-compose.yml https://raw.githubusercontent.com/ChristianKniep/docker-elk/master/docker-compose.yml
        cd $basedir/elk-stack/ && docker-compose up -d 
        
        echo 
        echo "################################################################################"
        echo "#  Deploying container for logspout to forward syslog on  127.0.0.1:55514...   #"
        echo "################################################################################"
        echo 
        cd $basedir/logspout/custom/
        docker build -f Dockerfile -t localhost:5000/logspout .
        docker run -d -p $IP_addr:8000:8000 --name="logspout-localhost" --link elkstack_elk_1:logspout -v /var/run/docker.sock:/tmp/docker.sock -e ROUTE_URIS=logstash://$IP_addr:55514 localhost:5000/logspout:latest 
        
#        echo 
#        echo "################################################################################"
#        echo "#  Deploying container for Graphite, Statsd and Graphana ...                   #"
#        echo "################################################################################"
#        echo 
        docker run --name local-postgres -e POSTGRES_DB=grafana -e POSTGRES_PASSWORD=br0k3r! -d -p 127.0.0.1:5432:5432 postgres:latest
        docker run --name local-mysql -e MYSQL_ROOT_PASSWORD=br0k3r! -e MYSQL_DATABASE=grafana -e MYSQL_USER=grafana -e MYSQL_PASSWORD=br0k3r! -d -p 127.0.0.1:3306:3306 mysql:latest
#        docker run --name grafana-dashboard --link local-mysql:mysql --link local-postgres:postgres -d -p -p $IP_addr:80:80 -p $IP_addr:81:81 -p $IP_addr:8125:8125/udp -p $IP_addr:8126:8126 kamon/grafana_graphite:latest
        cd $basedir/docker-grafana-graphite
        docker build -f Dockerfile -t localhost:5000/grafana-dashboard .
        docker run --name local-dashboard --link local-mysql:mysql --link local-postgres:postgres -d -p $IP_addr:80:80 -p $IP_addr:81:81 -p $IP_addr:8125:8125/udp -p $IP_addr:8126:8126 localhost:5000/grafana-dashboard
#        
#        echo 
#        echo "################################################################################"
#        echo "#  Deploying container for fluentd ...                   #"
#        echo "################################################################################"
#        echo 
#        
#        mkdir -p /opt/ibm/broker/docker/fluentd/plugins
#        rm -f $basedir/fluentd/Dockerfile
#        touch $basedir/fluentd/Dockerfile
#        rm -f $basedir/fluentd/fluent.conf
#        touch $basedir/fluentd/fluent.conf
#        
#        #Create fluent.conf for fluentd
#        printf '%s\n<source>' >>   $basedir/fluentd/fluent.conf
#        printf '%s\n  @type  forward' >>   $basedir/fluentd/fluent.conf
#        printf '%s\n  @id    input1' >>   $basedir/fluentd/fluent.conf
#        printf '%s\n  @label @mainstream' >>   $basedir/fluentd/fluent.conf
#        printf '%s\n  port  24224' >>   $basedir/fluentd/fluent.conf
#        printf '%s\n</source>' >>   $basedir/fluentd/fluent.conf
#        printf '%s\n' >>   $basedir/fluentd/fluent.conf
#        printf '%s\n<filter **>' >>   $basedir/fluentd/fluent.conf
#        printf '%s\n  @type stdout' >>   $basedir/fluentd/fluent.conf
#        printf '%s\n</filter>' >>   $basedir/fluentd/fluent.conf
#        printf '%s\n' >>   $basedir/fluentd/fluent.conf
#        printf '%s\n<label @mainstream>' >>   $basedir/fluentd/fluent.conf
#        printf '%s\n  <match docker.**>' >>   $basedir/fluentd/fluent.conf
#        printf '%s\n    @type file' >>   $basedir/fluentd/fluent.conf
#        printf '%s\n    @id   output_docker1' >>   $basedir/fluentd/fluent.conf
#        printf '%s\n    path         /fluentd/log/docker.*.log' >>   $basedir/fluentd/fluent.conf
#        printf '%s\n    symlink_path /fluentd/log/docker.log' >>   $basedir/fluentd/fluent.conf
#        printf '%s\n    append       true' >>   $basedir/fluentd/fluent.conf
#        printf '%s\n    time_slice_format %%Y%%m%%d' >>   $basedir/fluentd/fluent.conf
#        printf '%s\n    time_slice_wait   1m' >>   $basedir/fluentd/fluent.conf
#        printf '%s\n    time_format       %%Y%%m%%dT%%H%%M%%S%%z' >>   $basedir/fluentd/fluent.conf
#        printf '%s\n  </match>' >>   $basedir/fluentd/fluent.conf
#        printf '%s\n  <match **>' >>   $basedir/fluentd/fluent.conf
#        printf '%s\n    @type file' >>   $basedir/fluentd/fluent.conf
#        printf '%s\n    @id   output1' >>   $basedir/fluentd/fluent.conf
#        printf '%s\n    path         /fluentd/log/data.*.log' >>   $basedir/fluentd/fluent.conf
#        printf '%s\n    symlink_path /fluentd/log/data.log' >>   $basedir/fluentd/fluent.conf
#        printf '%s\n    append       true' >>   $basedir/fluentd/fluent.conf
#        printf '%s\n    time_slice_format %%Y%%m%%d' >>   $basedir/fluentd/fluent.conf
#        printf '%s\n    time_slice_wait   10m' >>   $basedir/fluentd/fluent.conf
#        printf '%s\n    time_format       %%Y%%m%%dT%%H%%M%%S%%z' >>   $basedir/fluentd/fluent.conf
#        printf '%s\n  </match>' >>   $basedir/fluentd/fluent.conf
#        printf '%s\n  <match graphite>' >>   $basedir/fluentd/fluent.conf
#        printf '%s\n  type graphite' >>   $basedir/fluentd/fluent.conf
#        printf '%s\n  host localhost # optional' >>   $basedir/fluentd/fluent.conf
#        printf '%s\n  port 2003 # optional' >>   $basedir/fluentd/fluent.conf
#        printf '%s\n  </match>' >>   $basedir/fluentd/fluent.conf
#        printf '%s\n</label>' >>   $basedir/fluentd/fluent.conf
#        
#        #Create Dockerfile for fluentd
#        printf '%s\nFROM ubuntu:14.04' >>   $basedir/fluentd/Dockerfile
#        printf '%s\nMAINTAINER Sushant Tripathi <sushtrip@in.ibm.com.com>' >>   $basedir/fluentd/Dockerfile
#        printf '%s\nLABEL Description="IBM Fluentd docker image with graphite forwarding" Vendor="IBM" Version="1.0"' >>   $basedir/fluentd/Dockerfile
#        printf '%s\nRUN apt-get update -y && apt-get install -y \' >>   $basedir/fluentd/Dockerfile
#        printf '%s\n              autoconf \' >>   $basedir/fluentd/Dockerfile
#        printf '%s\n              bison \' >>   $basedir/fluentd/Dockerfile
#        printf '%s\n              build-essential \' >>   $basedir/fluentd/Dockerfile
#        printf '%s\n              curl \      ' >>   $basedir/fluentd/Dockerfile
#        printf '%s\n              git \' >>   $basedir/fluentd/Dockerfile
#        printf '%s\n              gcc \' >>   $basedir/fluentd/Dockerfile
#        printf '%s\n              libruby \' >>   $basedir/fluentd/Dockerfile
#        printf '%s\n              libffi-dev \              ' >>   $basedir/fluentd/Dockerfile
#        printf '%s\n              libgdbm3 \' >>   $basedir/fluentd/Dockerfile
#        printf '%s\n              libgdbm-dev \' >>   $basedir/fluentd/Dockerfile
#        printf '%s\n              libncurses5-dev \' >>   $basedir/fluentd/Dockerfile
#        printf '%s\n              libreadline6-dev \              ' >>   $basedir/fluentd/Dockerfile
#        printf '%s\n              libssl-dev \' >>   $basedir/fluentd/Dockerfile
#        printf '%s\n              libyaml-dev \' >>   $basedir/fluentd/Dockerfile
#        printf '%s\n              zlib1g-dev \              ' >>   $basedir/fluentd/Dockerfile
#        printf '%s\n        && rm -rf /var/lib/apt/lists/*' >>   $basedir/fluentd/Dockerfile
#        printf '%s\n' >>   $basedir/fluentd/Dockerfile
#        printf '%s\nRUN useradd ubuntu -d /home/ubuntu -m -U' >>   $basedir/fluentd/Dockerfile
#        printf '%s\nRUN chown -R ubuntu:ubuntu /home/ubuntu' >>   $basedir/fluentd/Dockerfile
#        printf '%s\n' >>   $basedir/fluentd/Dockerfile
#        printf '%s\n# for log storage (maybe shared with host)' >>   $basedir/fluentd/Dockerfile
#        printf '%s\nRUN mkdir -p /fluentd/log' >>   $basedir/fluentd/Dockerfile
#        printf '%s\n# configuration/plugins path (default: copied from .)' >>   $basedir/fluentd/Dockerfile
#        printf '%s\nRUN mkdir -p /fluentd/etc' >>   $basedir/fluentd/Dockerfile
#        printf '%s\nRUN mkdir -p /fluentd/plugins' >>   $basedir/fluentd/Dockerfile
#        printf '%s\n' >>   $basedir/fluentd/Dockerfile
#        printf '%s\nRUN chown -R ubuntu:ubuntu /fluentd' >>   $basedir/fluentd/Dockerfile
#        printf '%s\nRUN chmod a+w -R /fluentd/log/' >>   $basedir/fluentd/Dockerfile
#        printf '%s\n' >>   $basedir/fluentd/Dockerfile
#        printf '%s\nUSER ubuntu' >>   $basedir/fluentd/Dockerfile
#        printf '%s\nWORKDIR /home/ubuntu' >>   $basedir/fluentd/Dockerfile
#        printf '%s\n' >>   $basedir/fluentd/Dockerfile
#        printf '%s\nRUN git clone https://github.com/tagomoris/xbuild.git /home/ubuntu/.xbuild' >>   $basedir/fluentd/Dockerfile
#        printf '%s\nRUN /home/ubuntu/.xbuild/ruby-install 2.2.2 /home/ubuntu/ruby' >>   $basedir/fluentd/Dockerfile
#        printf '%s\n' >>   $basedir/fluentd/Dockerfile
#        printf '%s\nENV PATH /home/ubuntu/ruby/bin:$PATH' >>   $basedir/fluentd/Dockerfile
#        printf '%s\nRUN gem install fluentd -v 0.12.19' >>   $basedir/fluentd/Dockerfile
#        printf '%s\nRUN gem install fluent-plugin-secure-forward' >>   $basedir/fluentd/Dockerfile
#        printf '%s\nRUN gem install fluent-plugin-graphite' >>   $basedir/fluentd/Dockerfile
#        printf '%s\n# RUN gem install fluent-plugin-webhdfs' >>   $basedir/fluentd/Dockerfile
#        printf '%s\n' >>   $basedir/fluentd/Dockerfile
#        printf '%s\nCOPY fluent.conf /fluentd/etc/' >>   $basedir/fluentd/Dockerfile
#        printf '%s\nONBUILD COPY fluent.conf /fluentd/etc/' >>   $basedir/fluentd/Dockerfile
#        printf '%s\nONBUILD COPY plugins /fluentd/plugins/' >>   $basedir/fluentd/Dockerfile
#        printf '%s\n' >>   $basedir/fluentd/Dockerfile
#        printf '%s\nWORKDIR /home/ubuntu' >>   $basedir/fluentd/Dockerfile
#        printf '%s\n' >>   $basedir/fluentd/Dockerfile
#        printf '%s\nENV FLUENTD_OPT=""' >>   $basedir/fluentd/Dockerfile
#        printf '%s\nENV FLUENTD_CONF="fluent.conf"' >>   $basedir/fluentd/Dockerfile
#        printf '%s\n' >>   $basedir/fluentd/Dockerfile
#        printf '%s\nEXPOSE 24224' >>   $basedir/fluentd/Dockerfile
#        printf '%s\n' >>   $basedir/fluentd/Dockerfile
#        printf '%s\n### docker run -p 24224 -v `pwd`/log: -v `pwd`/log:/home/ubuntu/log fluent/fluentd:latest' >>   $basedir/fluentd/Dockerfile
#        printf '%s\nCMD exec fluentd -c /fluentd/etc/$FLUENTD_CONF -p /fluentd/plugins $FLUENTD_OPT' >>   $basedir/fluentd/Dockerfile
#
#        
#        docker build $basedir/fluentd
#        docker build -t localhost:5000/fluentd_graphite $basedir/fluentd
#        docker run -d --name fluentd-graphite -p 24224:24224 -v /data:/fluentd/log localhost:5000/fluentd_graphite

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
echo 
echo "################################################################################################################"
echo "# Docker Engine, Docker UI and Docker Compose, Fluentd and Graphite dashboard containers are are now available!#"
echo "################################################################################################################"
echo 
#

#echo -n " (Setup Google Container Engine y/n)? "
#read answer
#if echo "$answer" | grep -iq "^y" ;then
#    echo
#    echo -n "Deploying container for etcd ..."
#    echo
#    docker run --name etcd-local --net=host -d gcr.io/google_containers/etcd:2.0.12 /usr/local/bin/etcd --addr=127.0.0.1:4001 --bind-addr=0.0.0.0:4001 --data-dir=/var/etcd/data 
#    
#    echo
#    echo "####################################################################################################"
#    echo "#  Deploying hyperkube kubelet and pod for the Google Container Engine kubernetes master ...       #"
#    echo "####################################################################################################"
#    echo
#    docker run \
#        --volume=/:/rootfs:ro \
#        --volume=/sys:/sys:ro \
#        --volume=/dev:/dev \
#        --volume=/var/lib/docker/:/var/lib/docker:ro \
#        --volume=/var/lib/kubelet/:/var/lib/kubelet:rw \
#        --volume=/var/run:/var/run:rw \
#        --net=host \
#        --pid=host \
#        --privileged=true \
#        -d\
#        gcr.io/google_containers/hyperkube:v1.0.1 \
#        /hyperkube kubelet --containerized --hostname-override="127.0.0.1" --address="0.0.0.0" --api-servers=http://$IP_addr:8080 --config=/etc/kubernetes/manifests 
#    
#    echo
#    echo "################################################################################"
#    echo "#  Deploying Google Container Engine Service Proxy ...                         #"
#    echo "################################################################################"
#    echo
#    docker run -d --net=host --privileged gcr.io/google_containers/hyperkube:v1.0.1 /hyperkube proxy --master=http://127.0.0.1:8080 --v=2 
#    
#    echo
#    echo "################################################################################"
#    echo "#  Installing kubectl ...                                                      #"
#    echo "################################################################################"
#    echo
#    curl -L https://storage.googleapis.com/kubernetes-release/release/v1.0.1/bin/linux/amd64/kubectl > /usr/local/bin/kubectl
#    chmod +x /usr/local/bin/kubectl
#else
#    exit
#fi
#echo "################################################################################"   
#echo "#  etcd, the hyperkube kubelet, kubernetes, and kubectl are now available!     #"
#echo "################################################################################"
echo
echo "Bootstrap will exit."

