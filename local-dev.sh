#!/bin/bash

set -e

# === FUNCTION TO VALIDATE URLS ===
validate_url() {
    local url="$1"
    echo -n "Checking $url... "
    if curl --output /dev/null --silent --head --fail "$url"; then
        echo "OK"
    else
        echo "FAILED"
        echo "❌ Cannot reach $url. Please check your network connection or the URL's availability."
        exit 1
    fi
}

# === REQUIRED URLS ===
REQUIRED_URLS=(
    "https://packages.gitlab.com/install/repositories/gitlab/gitlab-ce/script.deb.sh"
    "https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3"
    "https://dl.k8s.io/release/stable.txt"
    "https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64"
    "https://github.com/kubernetes-sigs/kustomize/releases/latest"
    "https://code-server.dev/install.sh"
    "https://dl.cloudsmith.io/public/caddy/stable/gpg.key"
    "https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt"
    "https://github.com/FiloSottile/mkcert/releases/latest/download/mkcert-v1.4.4-linux-amd64"
)

echo "🔍 Validating required URLs..."
for url in "${REQUIRED_URLS[@]}"; do
    validate_url "$url"
done

# === CONFIG ===
STATIC_IP=$(hostname -I | awk '{print $1}')
GITLAB_PORT=8080
CHARTS_PORT=8081
CODESERVER_PORT=8082
MINIKUBE_PORT=30000
DOMAINS=("gitlab.local" "charts.local" "code.local" "minikube.local")
CERT_DIR="/etc/caddy/certs"

# === SYSTEM UPDATE ===
sudo apt update && sudo apt upgrade -y

# === BASE PACKAGES ===
sudo apt install -y curl wget git dnsmasq docker.io ufw python3 python3-pip software-properties-common \
                    debian-keyring debian-archive-keyring apt-transport-https openssh-server libnss3-tools

# === ENABLE DOCKER ===
sudo systemctl enable --now docker
sudo usermod -aG docker $USER

# === INSTALL GITLAB CE ===
curl https://packages.gitlab.com/install/repositories/gitlab/gitlab-ce/script.deb.sh | sudo bash
sudo EXTERNAL_URL="http://localhost" apt install -y gitlab-ce
sudo sed -i "s|external_url .*|external_url 'http://$STATIC_IP:$GITLAB_PORT'|" /etc/gitlab/gitlab.rb
sudo gitlab-ctl reconfigure

# === HELM INSTALL ===
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# === KUBECTL INSTALL ===
K8S_VERSION=$(curl -s https://dl.k8s.io/release/stable.txt)
curl -LO "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/

# === MINIKUBE INSTALL ===
curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
chmod +x minikube-linux-amd64 && sudo mv minikube-linux-amd64 /usr/local/bin/minikube
minikube config set driver docker

# === KUSTOMIZE INSTALL ===
KUSTOMIZE_VERSION=$(curl -s https://api.github.com/repos/kubernetes-sigs/kustomize/releases/latest | grep tag_name | cut -d '"' -f 4)
curl -LO https://github.com/kubernetes-sigs/kustomize/releases/download/$KUSTOMIZE_VERSION/kustomize_${KUSTOMIZE_VERSION}_linux_amd64.tar.gz
tar -xzf kustomize_*.tar.gz && chmod +x kustomize && sudo mv kustomize /usr/local/bin/

# === CODE-SERVER INSTALL ===
curl -fsSL https://code-server.dev/install.sh | sh
mkdir -p ~/.config/code-server
cat > ~/.config/code-server/config.yaml <<EOF
bind-addr: 0.0.0.0:$CODESERVER_PORT
auth: password
password: dev123
cert: false
EOF
sudo systemctl enable --now code-server@$USER

# === CADDY INSTALL ===
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy.list
sudo apt update && sudo apt install -y caddy

# === MKCERT INSTALL ===
sudo curl -L -o /usr/local/bin/mkcert https://github.com/FiloSottile/mkcert/releases/latest/download/mkcert-v1.4.4-linux-amd64
sudo chmod +x /usr/local/bin/mkcert
mkcert -install

# === CREATE TLS CERTS ===
sudo mkdir -p "$CERT_DIR"
cd "$CERT_DIR"
sudo mkcert -cert-file gitlab.pem -key-file gitlab-key.pem gitlab.local
sudo mkcert -cert-file charts.pem -key-file charts-key.pem charts.local
sudo mkcert -cert-file code.pem -key-file code-key.pem code.local
sudo mkcert -cert-file minikube.pem -key-file minikube-key.pem minikube.local

# === CADDYFILE SETUP ===
sudo tee /etc/caddy/Caddyfile > /dev/null <<EOF
gitlab.local {
    tls $CERT_DIR/gitlab.pem $CERT_DIR/gitlab-key.pem
    reverse_proxy localhost:$GITLAB_PORT
}

charts.local {
    tls $CERT_DIR/charts.pem $CERT_DIR/charts-key.pem
    reverse_proxy localhost:$CHARTS_PORT
}

code.local {
    tls $CERT_DIR/code.pem $CERT_DIR/code-key.pem
    reverse_proxy localhost:$CODESERVER_PORT
}

minikube.local {
    tls $CERT_DIR/minikube.pem $CERT_DIR/minikube-key.pem
    reverse_proxy localhost:$MINIKUBE_PORT
}
EOF

sudo systemctl restart caddy

# === DNSMASQ SETUP ===
for DOMAIN in "${DOMAINS[@]}"; do
    echo "address=/$DOMAIN/$STATIC_IP"
done | sudo tee /etc/dnsmasq.d/dev.local.conf

sudo systemctl restart dnsmasq

# === DONE ===
echo "✅ Setup complete!"
echo ""
echo "📍 Access the following services securely:"
echo "   - https://gitlab.local"
echo "   - https://charts.local"
echo "   - https://code.local"
echo "   - https://minikube.local"
