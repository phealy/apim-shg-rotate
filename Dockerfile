FROM mcr.microsoft.com/azure-cli:latest
WORKDIR /root

RUN /usr/local/bin/az aks install-cli

COPY updateToken.sh /root

ENTRYPOINT "/root/updateToken.sh"
