FROM ubuntu:24.04

LABEL maintainer="VCF Engineering Team"
LABEL description="VCF 9 IaC development environment with VCF CLI, kubectl, and tooling"

ARG VCF_CLI_VERSION=v9.0.2
ARG KUBECTL_VERSION=v1.33.0

ENV DEBIAN_FRONTEND=noninteractive

# Install base packages
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    curl \
    ca-certificates \
    jq \
    git \
    python3 \
    python3-pip \
    python3-venv \
    tar \
    gzip \
    vim \
    less \
    nodejs \
    && rm -rf /var/lib/apt/lists/*

# Install kubectl
RUN curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
    -o /usr/local/bin/kubectl \
    && chmod +x /usr/local/bin/kubectl \
    && kubectl version --client

# Install Helm v3
RUN curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash \
    && helm version --short

# Install VCF CLI — extract to temp dir, find the binary, move it into PATH
RUN curl -fsSL "https://packages.broadcom.com/artifactory/vcf-distro/vcf-cli/linux/amd64/${VCF_CLI_VERSION}/vcf-cli.tar.gz" \
    -o /tmp/vcf-cli.tar.gz \
    && mkdir -p /tmp/vcf-cli-extract \
    && tar -xzf /tmp/vcf-cli.tar.gz -C /tmp/vcf-cli-extract \
    && echo "=== Tarball contents ===" && find /tmp/vcf-cli-extract -type f \
    && VCF_BIN=$(find /tmp/vcf-cli-extract -type f -name 'vcf*' | head -1) \
    && if [ -z "$VCF_BIN" ]; then VCF_BIN=$(find /tmp/vcf-cli-extract -type f | head -1); fi \
    && cp "$VCF_BIN" /usr/local/bin/vcf \
    && chmod +x /usr/local/bin/vcf \
    && rm -rf /tmp/vcf-cli.tar.gz /tmp/vcf-cli-extract

# Create workspace directory
WORKDIR /workspace

# Install Python test dependencies
COPY tests/requirements.txt /tmp/requirements.txt
RUN pip3 install --break-system-packages -r /tmp/requirements.txt \
    && rm /tmp/requirements.txt

# Default shell
SHELL ["/bin/bash", "-c"]

ENTRYPOINT ["/bin/bash"]
