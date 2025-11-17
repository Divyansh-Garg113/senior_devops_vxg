#!/bin/bash
set -e
apt-get update -y
apt-get install -y curl wget git jq

# Install Helm
curl https://raw.githubusercontent.com/helm/helm/master/scripts/get-helm-3 | bash

# Install K3s
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--write-kubeconfig-mode 644" sh -

# Wait for kubeconfig to appear
for i in {1..20}; do
  if [[ -f /etc/rancher/k3s/k3s.yaml ]]; then
    break
  fi
  sleep 5
done

# setup file permissions
chown ubuntu:ubuntu /etc/rancher/k3s/k3s.yaml
mkdir -p /home/ubuntu/.kube
cp /etc/rancher/k3s/k3s.yaml /home/ubuntu/.kube/config
chown -R ubuntu:ubuntu /home/ubuntu/.kube

# Wait for K3s node to become Ready
for i in {1..30}; do
  if su - ubuntu -c "kubectl get nodes --no-headers | grep -q ' Ready '"; then
    break
  fi
  sleep 10
done

# Add Helm repositories; install Nginx and Prometheus
su - ubuntu -c "helm repo add bitnami https://charts.bitnami.com/bitnami"
su - ubuntu -c "helm repo add prometheus-community https://prometheus-community.github.io/helm-charts"
su - ubuntu -c "helm repo update"
su - ubuntu -c "helm install nginx-app bitnami/nginx --namespace nginx --create-namespace"
su - ubuntu -c "helm install prometheus prometheus-community/prometheus --namespace monitoring --create-namespace"

