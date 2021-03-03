#! /bin/bash
set -euo pipefail

# updateToken.sh
# 
# A shell script to use the Azure CLI and kubectl in order to rotate a token on a
# self-hosted application gateway. Designed to be run in a container using a Kubernetes
# CronJob.
#
# Based on an idea from https://github.com/briandenicola/apim-selfhosted-gateway-token-rotation
# but rewritten from scratch.

function usage {
	cat <<-EOF

	Usage: $(basename $0)
	  -s|--subscription-id <SUBSCRIPTION_ID>
	  -r|--resource-group <RESOURCE_GROUP>
	  -a|--apim-instance <APIM_INSTANCE>
	  -g|--gateway-name <APIM_GATEWAY>
	  -n|--namespace <NAMESPACE>
	  -t|--token-secret <TOKEN_SECRET>
	  -k|--token-key <TOKEN_KEY>
	  -o|--object <K8S_OBJECT>

	Generates a new token for an APIM self-hosted gateway, updates the Kubernetes secret, then performs a rolling restart.
	Arguments may be specified as parameters or as environment variables.
	
	Arguments:
	-s, --subscription-id, SUBSCRIPTION_ID environment variable
	      The GUID of the scription containing the APIM instance.

	-r, --resource-group, RESOURCE_GROUP environment variable
	      The name of the resource group containing the APIM instance.

	-a, --apim-instance, APIM_INSTANCE environment variable
	      The name of the APIM instance

	-g, --gateway-name, APIM_GATEWAY environment variable
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
	        "secondary - generate the new token from the secondary key

	-o, --object, K8S_OBJECT
	      The name of the Kubernetes object to restart after updating the secret, using kubectl rollout restart.
	      Should be specified in the form "type/name", e.g. "deployment/apim-gateway" or "statefulset/apim-gateway"

	EOF
  exit 1
}

PARSED_ARGUMENTS=$(getopt -a -n "$(basename $0)" -o s:r:a:g:n:t:k:h --long subscription-id:,resource-group:,apim-instance:,gateway-name:,namespace:,token-secret:,token-key:,help -- "$@")
VALID_ARGUMENTS=$?
if [ "$VALID_ARGUMENTS" != "0" ]; then
  usage
fi

eval set -- "$PARSED_ARGUMENTS"
while :
do
  case "$1" in
    -s | --subscription-id) SUBSCRIPTION_ID="${2}"; shift 2;;
    -r | --resource-group) RESOURCE_GROUP="${2}"; shift 2;;
    -a | --apim-name) APIM_INSTANCE="${2}"; shift 2;;
    -g | --gateway-name) APIM_GATEWAY="${2}"; shift 2;;
    -n | --namespace) NAMESPACE="${2}"; shift 2;;
    -t | --token-secret) TOKEN_SECRET="${2}"; shift 2;;
    -k | --token-key) TOKEN_KEY="${2}"; shift 2;;
    -o | --object) K8S_OBJECT="${2}"; shift 2;;
    -h | --help) usage;;
    --) shift; break ;;
  esac
done

# Set defaults
TOKEN_KEY="${TOKEN_KEY:-last}"

# Error out if variables aren't set
for var in SUBSCRIPTION_ID RESOURCE_GROUP APIM_INSTANCE APIM_GATEWAY NAMESPACE TOKEN_SECRET TOKEN_KEY; do
  if [[ -z "${!var}" ]]; then
    echo -e "\nERROR: Parameter ${var} is undefined. Please specify the parameter as either an environment variable or a command argument."
    usage
  fi
done

cat << EOF

APIM Self-hosted Gateway Secret Rotation
Date: $(date)
----------------------------------------

Parameters:
Subscription ID:  $SUBSCRIPTION_ID
Resource group:   $RESOURCE_GROUP
APIM Instance:    $APIM_INSTANCE
APIM Gateway:     $APIM_GATEWAY
K8s Namespace:    $NAMESPACE
K8s Token Secret: $TOKEN_SECRET
APIM Key Source:  $TOKEN_KEY
K8S Object:       ${K8S_OBJECT:-not provided}

----------------------------------------

EOF

echo -n "Checking for Azure CLI access..."
# See if we're logged in and can see the indicated subscription
if [[ $(az account list --refresh --query "length([?id=='$SUBSCRIPTION_ID'])" 2>/dev/null) == 1 ]]; then
  echo "done (already logged in)."
else
  # Try a managed identity login, if we're not already logged in
  az login --identity >/dev/null
  if [[ $(az account list --refresh --query "length([?id=='$SUBSCRIPTION_ID'])" 2>/dev/null) == 1 ]]; then 
    echo "done (logged in via identity)."
  else
    echo -e "\n\nERROR: Failed to access the subscription via az cli, either via already logged in credentials or identity."
    exit 1
  fi
fi

echo -n "Validating APIM instance is present and correct..."
APIM_RESOURCE_ID=$(az apim show --subscription $SUBSCRIPTION_ID --resource-group $RESOURCE_GROUP --name $APIM_INSTANCE --query "id" -o tsv 2>&1) || {
  echo -e "\n\nERROR: Unable to find $APIM_INSTANCE in resource group $RESOURCE_GROUP in subscription $SUBSCRIPTION_ID."
  echo -e "\nCommand output:\n${APIM_RESOURCE_ID}"
  exit 1
}
echo "done."

echo -n "Validating APIM gateway instance is present and correct..."
GATEWAY_RESOURCE_ID="${APIM_RESOURCE_ID}/gateways/${APIM_GATEWAY}"
OUTPUT=$(az rest --method GET --uri "https://management.azure.com${GATEWAY_RESOURCE_ID}" --uri-parameters "api-version=2019-12-01" 2>&1) || {
  echo -e "\n\nERROR: Unable to query APIM self-hosted gateway instance properties."
  echo -e "\nAPI output:\n${OUTPUT}"
  exit 1
}
echo "done."

echo -n "Validating Kubernetes secret is present and correct..."
LAST_USED_KEY_ANNOTATION=$(kubectl --namespace $NAMESPACE get secret $TOKEN_SECRET -o jsonpath='{.metadata.annotations.last-used-key}' 2>&1) || {
  echo -e "\n\nERROR: unable to retrieve Kubernetes secret ${TOKEN_SECRET}."
  echo -e "\nkubectl output:\n${LAST_USED_KEY_ANNOTATION}"
  exit 1
}
echo "done (last used key: \"${LAST_USED_KEY_ANNOTATION:-unset}\")."

echo -n "Determining which key to use to generate the token..."
case "${TOKEN_KEY}" in 
  last)
    TOKEN_KEY="${LAST_USED_KEY_ANNOTATION:-primary}"
    ;;
  primary)
    TOKEN_KEY="primary"
    ;;
  secondary)
    TOKEN_KEY="secondary"
    ;;
  rotate)
    case "${LAST_USED_KEY_ANNOTATION:-secondary}" in
      primary) TOKEN_KEY="secondary";;
      secondary) TOKEN_KEY="primary";;
      esac
    ;;
  *)
    echo -e "\n\nERROR: Unrecognized argument to -k/--token-key/TOKEN_KEY."
    usage
    ;;
esac
echo "done - token will be generated from the ${TOKEN_KEY} key."

echo -n "Generating new token for gateway..."
GENERATE_TOKEN_URL="https://management.azure.com${GATEWAY_RESOURCE_ID}/generateToken?api-version=2019-12-01"
TOKEN_EXPIRATION_DATE="$(date -Iseconds --date '+30 days')"
TOKEN=$(az rest --method POST --uri $URL --body "{ \"expiry\": \"${TOKEN_EXPIRATION_DATE}\", \"keyType\": \"${TOKEN_KEY}\" }" --query value -o tsv) || {
  echo -e "\n\nERROR: unable to generate new token for gateway."
  echo -e "\nAPI call output:\n${TOKEN}"
  exit 1
}
echo "done."

echo -n "Updating Kubernetes secret..."
OUTPUT=$(kubectl --namespace $NAMESPACE create secret generic ${TOKEN_SECRET} --from-literal value="GatewayKey ${TOKEN}" --dry-run=client -o yaml 2>&1 | kubectl --namespace $NAMESPACE apply -f - 2>&1) || {
  echo -e "\n\nERROR: Unable to update token secret."
  echo -e "\nkubectl output:\n${OUTPUT}"
  exit 1
}
echo "${OUTPUT}"

echo -n "Annotating token secret with \"last-used-key: ${TOKEN_KEY}\"..."
OUTPUT=$(kubectl --namespace $NAMESPACE annotate --overwrite=true secret $TOKEN_SECRET last-used-key="${TOKEN_KEY}" 2>&1) || {
  echo -e "\n\nERROR: Failed to annotate token secret."
  echo -e "\nkubectl output:\n${OUTPUT}"
  exit 1
}
echo "${OUTPUT}"

if [[ ! -z "${K8S_OBJECT}" ]]; then
  echo -n "Performing a rolling restart of the self-hosted gateway..."
  OUTPUT=$(kubectl --namespace $NAMESPACE rollout restart $K8S_OBJECT 2>&1) || {
    echo -e "\n\nERROR: Failed to restart $K8S_OBJECT."
    echo -e "\nkubectl output:\n${OUTPUT}"
    exit 1
  }
  echo "${OUTPUT}"
fi

echo

echo "Token rotation complete."
echo "A new token was generated based on the ${TOKEN_KEY} APIM key and will expire on ${TOKEN_EXPIRATION_DATE}."
