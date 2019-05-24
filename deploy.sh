#!/bin/bash

#Yeah, I know this could have been a lot better and used an actual deploy system.

DEBIAN_FRONTEND=noninteractive

apt -y update
apt -y upgrade

#Create user and add to sudo

useradd -p $(openssl passwd -1 password) qtran
adduser qtran sudo

#Copy over dummy netplan YML config and apply the settings

rm -rf /etc/netplan/01-netcfg.yaml
cp assets/netplan_config/01-netcfg.yaml /etc/netplan/

netplan apply

#Install SSH and configure it properly

apt -y install openssh-server

rm -rf /etc/ssh/sshd_config
cp assets/sshd/sshd_config /etc/ssh/
yes "y" | ssh-keygen -q -N "" > /dev/null
mkdir ~/.ssh
cat assets/ssh/id_rsa.pub > ~/.ssh/authorized_keys

service sshd restart

#Install iptables
apt -y install iptables

#Install and configure Fail2Ban
apt -y install fail2ban

rm -rf /etc/fail2ban/jail.local
cp assets/fail2ban/jail.local /etc/fail2ban/

cp assets/fail2ban/nginx-dos.conf /etc/fail2ban/filter.d
cp assets/fail2ban/portscan.conf /etc/fail2ban/filter.d

service fail2ban restart

#Copy and set up cron scripts for updating packages and detecting crontab changes

apt -y install mailutils

cp -r assets/scripts /home/qtran
{ crontab -l -u qtran; echo '0 4 * * SUN /home/qtran/scripts/update_script.sh'; } | crontab -u qtran -
{ crontab -l -u qtran; echo '@reboot /home/qtran/scripts/update_script.sh'; } | crontab -u qtran -

{ crontab -l -u qtran; echo '0 0 * * * SUN /home/qtran/scripts/check_cron.sh'; } | crontab -u qtran -

#Set up nginx and copy website files over
apt -y install nginx

rm -rf /var/www/html/index.nginx-debian.html
cp assets/nginx/index.nginx-debian.html /var/www/html/

#Set up SSL
yes "y" | openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout /etc/ssl/private/nginx-selfsigned.key -out /etc/ssl/certs/nginx-selfsigned.crt \
	-subj "/C=US/ST=California/L=Fremont/O=42 Silicon Valley/OU=Student/CN=localhost"
yes "y" | openssl dhparam -dsaparam -out /etc/nginx/dhparam.pem 4096
cp assets/ssl/self-signed.conf /etc/nginx/snippets/
cp assets/ssl/ssl-params.conf /etc/nginx/snippets/

rm -rf /etc/nginx/sites-available/default
cp assets/ssl/default /etc/nginx/sites-available/

#Set up Firewall; Default DROP connections
#Flush iptables
sudo iptables -F
sudo iptables -X
sudo iptables -t nat -F
sudo iptables -t nat -X
sudo iptables -t mangle -F
sudo iptables -t mangle -X
sudo iptables -P INPUT ACCEPT
sudo iptables -P FORWARD ACCEPT
sudo iptables -P OUTPUT ACCEPT

#Blocking all
sudo iptables -P INPUT DROP
sudo iptables -P FORWARD DROP
sudo iptables -P OUTPUT DROP

#Droping all invalid packets
sudo iptables -A INPUT -m state --state INVALID -j DROP
sudo iptables -A FORWARD -m state --state INVALID -j DROP
sudo iptables -A OUTPUT -m state --state INVALID -j DROP

#Flooding of RST packets, smurf attack Rejection
sudo iptables -A INPUT -p tcp -m tcp --tcp-flags RST RST -m limit --limit 2/second --limit-burst 2 -j ACCEPT

#For SMURF attack protection
sudo iptables -A INPUT -p icmp -m icmp --icmp-type address-mask-request -j DROP
sudo iptables -A INPUT -p icmp -m icmp --icmp-type timestamp-request -j DROP

#Attacking IP will be locked for 24 hours (3600 x 24 = 86400 Seconds)
sudo iptables -A INPUT -m recent --name portscan --rcheck --seconds 86400 -j DROP
sudo iptables -A FORWARD -m recent --name portscan --rcheck --seconds 86400 -j DROP

#Remove attacking IP after 24 hours
sudo iptables -A INPUT -m recent --name portscan --remove
sudo iptables -A FORWARD -m recent --name portscan --remove

#PORT SCAN
sudo iptables -A INPUT -p TCP -m state --state NEW -m recent --set
sudo iptables -A INPUT -p TCP -m state --state NEW -m recent --update --seconds 1 --hitcount 10 -j DROP

#DOS - This rule limits the ammount of connections from the same IP in a short time
sudo iptables -I INPUT -p TCP --dport 5647 -i enp0s3 -m state --state NEW -m recent --set
sudo iptables -I INPUT -p TCP --dport 5647 -i enp0s3 -m state --state NEW -m recent --update --seconds 60 --hitcount 10 -j DROP
sudo iptables -I INPUT -p TCP --dport 80 -i enp0s3 -m state --state NEW -m recent --set
sudo iptables -I INPUT -p TCP --dport 80 -i enp0s3 -m state --state NEW -m recent --update --seconds 60 --hitcount 10 -j DROP
sudo iptables -I INPUT -p TCP --dport 443 -i enp0s3 -m state --state NEW -m recent --set
sudo iptables -I INPUT -p TCP --dport 443 -i enp0s3 -m state --state NEW -m recent --update --seconds 60 --hitcount 10 -j DROP
sudo iptables -I INPUT -p TCP --dport 25 -i enp0s3 -m state --state NEW -m recent --set
sudo iptables -I INPUT -p TCP --dport 25 -i enp0s3 -m state --state NEW -m recent --update --seconds 60 --hitcount 10 -j DROP

#Keeping connections already ESTABLISHED
sudo iptables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
sudo iptables -A OUTPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
sudo iptables -A OUTPUT -m conntrack ! --ctstate INVALID -j ACCEPT

#Accept lo
sudo iptables -t filter -A INPUT -i lo -j ACCEPT
sudo iptables -t filter -A OUTPUT -o lo -j ACCEPT

#ACCEPT SSH
sudo iptables -A INPUT -p TCP --dport 55555 -j ACCEPT
sudo iptables -A OUTPUT -p TCP --dport 55555 -j ACCEPT

#ACCEPT HTTP
sudo iptables -A INPUT -p TCP --dport 80 -j ACCEPT
sudo iptables -A OUTPUT -p TCP --dport 80 -j ACCEPT

#ACCEPT HTTPS
sudo iptables -A INPUT -p TCP --dport 443 -j ACCEPT
sudo iptables -A OUTPUT -p TCP --dport 443 -j ACCEPT

#ACCEPT SMTP
sudo iptables -t filter -A INPUT -p tcp --dport 25 -j ACCEPT
sudo iptables -t filter -A OUTPUT -p tcp --dport 25 -j ACCEPT

# Lastly reject All INPUT traffic
sudo iptables -A INPUT -j REJECT

#ACCEPT PING
sudo iptables -t filter -A INPUT -p icmp -j ACCEPT
sudo iptables -t filter -A OUTPUT -p icmp -j ACCEPT

#Reboot Nginx server, hopefully we have a live website
systemctl restart nginx
