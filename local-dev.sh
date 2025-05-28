#!/bin/bash

set -e

# CONFIG
STATIC_IP="192.168.1.100"
GITLAB_PORT=8080
CHARTS_PORT=8081
CODESERVER_PORT=8082
MINIKUBE_PORT=30000
DOMAINS=("gitlab.local" "charts.local" "code.local" "minikube.local")

echo "==> Updating system..."
sudo apt update && sudo apt upgrade -y

echo "==> Installing dependencies..."
sudo apt install -y curl wget gnupg2 lsb-release software-properties-common apt-transport-https \
                    git python3 python3-pip dnsmasq docker.io ufw

echo "==> Configuring Docker..."
sudo systemctl enable --now docker
sudo usermod -aG docker $USER

echo "==> Installing GitLab CE..."
curl https://packages.gitlab.com/install/repositories/gitlab/gitlab-ce/script.deb.sh | sudo bash
sudo EXTERNAL_URL="http://localhost" apt install -y gitlab-ce
sudo sed -i "s/external_url.*/external_url 'http:\/\/$STATIC_IP:$GITLAB_PORT'/" /etc/gitlab/gitlab.rb
sudo gitlab-ctl reconfigure

echo "==> Installing Helm..."
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

echo "==> Installing kubectl..."
curl -LO "https://dl.k8s.io/release/$(curl -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/

echo "==> Installing Minikube..."
curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
chmod +x minikube-linux-amd64 && sudo mv minikube-linux-amd64 /usr/local/bin/minikube
minikube config set driver docker

echo "==> Installing Kustomize..."
KUSTOMIZE_VERSION=$(curl -s https://api.github.com/repos/kubernetes-sigs/kustomize/releases/latest | grep tag_name | cut -d '"' -f 4)
curl -LO https://github.com/kubernetes-sigs/kustomize/releases/download/$KUSTOMIZE_VERSION/kustomize_${KUSTOMIZE_VERSION}_linux_amd64.tar.gz
tar -xzf kustomize_*.tar.gz && chmod +x kustomize && sudo mv kustomize /usr/local/bin/

echo "==> Installing code-server..."
curl -fsSL https://code-server.dev/install.sh | sh
mkdir -p ~/.config/code-server
cat > ~/.config/code-server/config.yaml <<EOF
bind-addr: 0.0.0.0:$CODESERVER_PORT
auth: password
password: dev123
cert: false
EOF
sudo systemctl enable --now code-server@$USER

echo "==> Installing Caddy..."
sudo apt install -y debian-keyring debian-archive-keyring
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy.list
sudo apt update && sudo apt install -y caddy

echo "==> Creating Caddyfile..."
sudo tee /etc/caddy/Caddyfile > /dev/null <<EOF
gitlab.local {
    reverse_proxy localhost:$GITLAB_PORT
}

charts.local {
    reverse_proxy localhost:$CHARTS_PORT
}

code.local {
    reverse_proxy localhost:$CODESERVER_PORT
}

minikube.local {
    reverse_proxy localhost:$MINIKUBE_PORT
}
EOF

sudo systemctl restart caddy

echo "==> Configuring dnsmasq for .local domains..."
for DOMAIN in "${DOMAINS[@]}"; do
    echo "address=/$DOMAIN/$STATIC_IP"
done | sudo tee /etc/dnsmasq.d/dev.local.conf

sudo systemctl restart dnsmasq

echo "✅ All done!"
echo "🔗 Access GitLab:     http://gitlab.local"
echo "🔗 Access Charts:     http://charts.local (Python server needed)"
echo "🔗 Access code-server: http://code.local"
echo "🔗 Access Minikube app: http://minikube.local (after exposing a NodePort)"
