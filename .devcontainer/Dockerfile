ARG DEBIAN_VERSION=bookworm
ARG UV_VERSION=0.10.12
ARG PYTHON_VERSION=3.13

# Pull UV installer layer
FROM ghcr.io/astral-sh/uv:$UV_VERSION AS uv

# Base image
FROM mcr.microsoft.com/vscode/devcontainers/base:$DEBIAN_VERSION
LABEL maintainer="matthias zimmermann <zimmermann@xbrain.com>"

# Add a non-root dev user
ARG USERNAME=devuser
ARG USER_UID=1000
ARG USER_GID=1000

# Create user and group only if they don't already exist
RUN if ! id -u devuser > /dev/null 2>&1; then \
      groupadd devuser && \
      useradd -m -s /bin/bash -g devuser devuser; \
    fi && \
    apt-get update && apt-get install -y sudo curl ca-certificates && \
    echo "devuser ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/devuser && \
    chmod 0440 /etc/sudoers.d/devuser

# Set environment
ENV HOME=/home/$USERNAME
WORKDIR $HOME

# Copy UV from builder image
COPY --from=uv --chown=$USERNAME:$USERNAME /uv /uvx /bin/

# Install Python via UV (as non-root user)
USER $USERNAME
RUN uv python install $PYTHON_VERSION

# Install Foundry
RUN curl -L https://foundry.paradigm.xyz | bash && $HOME/.foundry/bin/foundryup

# Add Foundry to path
ENV PATH="$HOME/.foundry/bin:$PATH"

WORKDIR $HOME