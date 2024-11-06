#!/usr/bin/env bash
export DEBIAN_FRONTEND=noninteractive

read -p "Enter domain: " domainName
read -p "Enter obfs: " obfs
read -p "Enter user: " user
read -p "Enter password: " password

apt update && apt upgrade -y
echo iptables-persistent iptables-persistent/autosave_v4 boolean true | sudo debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean true | sudo debconf-set-selections
apt install iptables-persistent certbot dnsutils lsof -y

DOWNLOAD_URL="https://github.com/apernet/hysteria/releases/download/app%2Fv2.5.2/hysteria-linux-amd64"
DOWNLOAD_PATH="/etc/udp/hysteria135"

# Create the directory if it doesn't exist
mkdir -p /etc/udp

# Download with retries and timeout
wget --retry-connrefused --waitretry=5 --read-timeout=20 --timeout=15 -t 10 -O $DOWNLOAD_PATH $DOWNLOAD_URL

# Check if the download was successful
if [ $? -eq 0 ]; then
  echo "Download successful."
  chmod +x $DOWNLOAD_PATH
else
  echo "Download failed after multiple attempts. Exiting."
  exit 1
fi

# Check if port 80 is in use
port_info=$(sudo lsof -i :80)

# If port 80 is in use, proceed to find the service
if [[ ! -z "$port_info" ]]; then
  # Extract the PID and the command (service) that is using port 80
  pid=$(echo "$port_info" | grep -v "COMMAND" | awk '{print $2}' | head -n 1)
  service=$(ps -p $pid -o comm=)

  echo "Port 80 is currently being used by service: $service (PID: $pid)"

  # Check if the service is managed by systemctl
  if systemctl list-units --type=service | grep -q "$service"; then
    echo "Stopping service: $service"
    sudo systemctl stop $service
    echo "$service stopped successfully."
  else
    # If the service is not managed by systemctl, kill the process manually
    echo "Service $service is not managed by systemctl. Killing process: $pid"
    sudo kill -9 $pid
    echo "Process $pid killed successfully."
  fi
else
  echo "Port 80 is not in use."
fi

# Check if the domain has DNS records (A record)
if ! dig +short $domainName | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "Domain $domainName does not have valid DNS records. Exiting."
  exit 1
fi

# Proceed with Certbot if the domain exists
echo "Proceeding with Certbot for domain: $domainName"

sudo certbot certonly --standalone --pre-hook "echo ${domainName}" -d ${domainName} \
  --email jlhsnzfn@bugfoo.com --agree-tos --non-interactive --no-eff-email


cat << UDP > /etc/udp/config.json
{
    "server": "$domainName",
    "listen": ":36712",
    "protocol": "udp",
    "cert": "/etc/letsencrypt/live/$domainName/fullchain.pem",
    "key": "/etc/letsencrypt/live/$domainName/privkey.pem",
    "up": "1000 Mbps",
    "up_mbps": 1000,
    "down": "1000 Mbps",
    "down_mbps": 1000,
    "disable_udp": false,
    "insecure": false,
    "obfs": "$obfs",
    "auth": {
      "mode": "passwords",
      "config": [
        "$user:$password"
      ]
    }
  }
UDP

cat << EOF > /etc/systemd/system/udp.service
[Unit]
Description=JuanScript Simplified UDP
After=network.target

[Service]
User=root
WorkingDirectory=/etc/udp
ExecStart=/etc/udp/hysteria135 server --config /etc/udp/config.json

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable udp
systemctl restart udp

echo 1 > /proc/sys/net/ipv4/ip_forward
echo 1 > /proc/sys/net/ipv6/conf/all/forwarding
echo 1 > /proc/sys/net/ipv6/conf/default/forwarding

{
    echo "net.ipv4.ip_forward = 1"
    echo "net.ipv6.conf.all.forwarding = 1"
    echo "net.ipv6.conf.default.forwarding = 1"
} >> /etc/sysctl.conf

sysctl -p

PNET="$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)"
systemctl -q enable netfilter-persistent
iptables -t nat -A PREROUTING -i ${PNET} -p udp --dport 10000:65000 -j DNAT --to-destination :36712
ip6tables -t nat -A PREROUTING -i ${PNET} -p udp --dport 10000:65000 -j DNAT --to-destination :36712
iptables -A INPUT -s 0.0.0.0/0 -p tcp -m multiport --dport 1:65535 -j ACCEPT
iptables -A INPUT -s 0.0.0.0/0 -p udp -m multiport --dport 1:65535 -j ACCEPT
ip6tables  -A INPUT -s 0.0.0.0/0 -p tcp -m multiport --dport 1:65535 -j ACCEPT
ip6tables  -A INPUT -s 0.0.0.0/0 -p udp -m multiport --dport 1:65535 -j ACCEPT
iptables -A INPUT -i ${PNET} -j ACCEPT
iptables -A OUTPUT -o ${PNET} -j ACCEPT
ip6tables -A INPUT -i ${PNET} -j ACCEPT
ip6tables -A OUTPUT -o ${PNET} -j ACCEPT
netfilter-persistent save
systemctl -q restart netfilter-persistent
reboot
