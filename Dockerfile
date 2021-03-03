FROM mcr.microsoft.com/azure-cli:latest
WORKDIR /root

RUN /usr/local/bin/az aks install-cli

COPY rotate.sh /root

ENTRYPOINT "/root/rotate.sh"
