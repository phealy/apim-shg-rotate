FROM mcr.microsoft.com/azure-cli:latest
RUN /usr/local/bin/az aks install-cli
WORKDIR /root
