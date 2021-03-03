# apim-shg-rotate

## Table of contents

1. [Overview](#overview)
2. [Requirements](#requirements)
3. [Deploying in Kubernetes](#deploying-in-kubernetes)
4. [Usage](#usage)
5. [Example output](#example-output)

## Overview

A Docker container image that can be deployed in a Kubernetes [CronJob](https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/) to automatically rotate Azure API Management [Self-Hosted Gateway](https://docs.microsoft.com/en-us/azure/api-management/self-hosted-gateway-overview) tokens on a regular basis. This is needed because tokens have a maximum lifetime of 30 days and the agent doesn't contain any self-rotate functionality. See [this question](https://docs.microsoft.com/en-us/azure/api-management/how-to-deploy-self-hosted-gateway-kubernetes#access-token) in the [deploy a self-hosted gateway to Kubernetes](https://docs.microsoft.com/en-us/azure/api-management/how-to-deploy-self-hosted-gateway-kubernetes) documentation for further details.

Original idea from [Brian Denicola's apim-selfhosted-gateway-token-rotation script](https://github.com/briandenicola/apim-selfhosted-gateway-token-rotation), but I wanted something a little more production-ready with more verbosity, error handling, and the ability to configure via environment variables.

This is a side project of mine and is not officially supported or endorsed by Microsoft. Pull requests and issues welcome.

## Requirements

Components:

- APIM Self-hosted Gateway deployed in Kubernetes
- [aad-pod-identity](https://github.com/Azure/aad-pod-identity)

Access:

- A [user-assigned managed identity](https://docs.microsoft.com/en-us/azure/active-directory/managed-identities-azure-resources/how-to-manage-ua-identity-portal) with one of the two following roles, assigned to the pod via an [AAD Pod Identity Binding](manifests/aad-pod-identity.yaml)
  - API Management Service Contributor - the built-in role with access to generate gateway tokens; this role gives far more access than actually needed.
  - [API Management Self-Hosted Gateway Token Operator (custom role)](azure/apim-shg-token-operator.json) - this custom role contains only two permissions - the ability to list self-hosted gateways and the ability to generate new tokens for them. See the [Azure custom roles](https://docs.microsoft.com/en-us/azure/role-based-access-control/custom-roles) documentation for how to create this role.
- A Kubernetes Service Account assigned to the pod that can update the secrets and then restart the deployment or statefulset hosting the APIM Self-Hosted Gateway.

## Deploying in Kubernetes

This script should be deployed into the same namespace as your APIM self-hosted gateway using a CronJob to run on a scheduled basis. The following items are required:

- [AAD Pod Identity and Binding](manifests/aad-pod-identity.yaml)
- [RBAC (role, role binding, service account)](manifests/rbac.yaml)
- [CronJob](manifests/cronjob.yaml)

## Usage

```shell
Usage: updateToken.sh
  -s|--subscription-id <SUBSCRIPTION_ID>
  -r|--resource-group <RESOURCE_GROUP>
  -a|--apim-instance <APIM_INSTANCE>
  -g|--apim-gateway <APIM_GATEWAY>
  -n|--namespace <NAMESPACE>
  -t|--token-secret <TOKEN_SECRET>
  -k|--token-key <TOKEN_KEY>
  -o|--k8s-object <K8S_OBJECT>
  --debug

Generates a new token for an APIM self-hosted gateway, updates the Kubernetes secret, then performs a rolling restart.
Arguments may be specified as parameters or as environment variables.

Arguments:
  -s, --subscription-id, SUBSCRIPTION_ID environment variable
        The GUID of the scription containing the APIM instance.

  -r, --resource-group, RESOURCE_GROUP environment variable
        The name of the resource group containing the APIM instance.

  -a, --apim-instance, APIM_INSTANCE environment variable
        The name of the APIM instance

  -g, --apim-gateway, APIM_GATEWAY environment variable
        The name of the self-hosted gateway

  -n, --namespace, NAMESPACE environment variable
        The namespace containing the token to rotate

  -t, --token-secret, TOKEN_SECRET environment variable
        The name of the Kubernetes secret object containing the token to rotate

  -k, --token-key, TOKEN_KEY
        Switch the key used to generate the token. Can be set to one of the following values:
          "last" - default, the value from the last-key-used annotation on the token will be used
                  if no annotation is present, defaults to primary
          "rotate" - rotate from the last used key to the other key: primary -> secondary or secondary -> primary
          "primary" - generate the new token from the primary key
          "secondary" - generate the new token from the secondary key

  -o, --k8s-object, K8S_OBJECT
        The name of the Kubernetes object to restart after updating the secret, using kubectl rollout restart.
        Should be specified in the form "type/name", e.g. "deployment/apim-gateway" or "statefulset/apim-gateway"

  --debug
        Enable debug logging (set -x)
```

## Example output

```shell
$ kubectl logs apim-shg-rotate-1614798780-l2scx

APIM Self-hosted Gateway Secret Rotation
Date: Wed Mar  3 19:13:07 UTC 2021
----------------------------------------

Parameters:
Subscription ID:  2006d617-bee2-430e-8239-c83634af2fef
Resource group:   rg-network-apim-eastus
APIM Instance:    apim-pahealy-eastus
APIM Gateway:     akseast0
K8s Namespace:    apim-gateway
K8s Token Secret: apim-gateway-token
APIM Key Source:  primary
K8S Object:       statefulset/apim-gateway

----------------------------------------

Checking for Azure CLI access...done (logged in via identity).
Validating APIM instance is present and correct...done.
Validating APIM gateway instance is present and correct...done.
Validating Kubernetes secret is present and correct...done (last used key: "primary").
Determining which key to use to generate the token...done - token will be generated from the primary key.
Generating new token for gateway...done.
Updating Kubernetes secret...secret/apim-gateway-token configured
Annotating token secret with "last-used-key: primary"...secret/apim-gateway-token annotated
Performing a rolling restart of the self-hosted gateway...statefulset.apps/apim-gateway restarted

Token rotation complete.
A new token was generated based on the primary APIM key and will expire on 2021-04-02T19:13:11+0000.
```
