#! /bin/bash

function usage {
	cat <<-EOF
	Usage: $(basename $0) -s|--subscription-id SUBSCRIPTIONID -g|--resource-group RESOURCEGROUP -n|--apim-name APIMINSTANCE -t|--token-secret SECRETNAME

	Rotates the non-used APIM gateway key, then updates it into Kubernetes.
	
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
	EOF
  exit 1
}

PARSED_ARGUMENTS=$(getopt -a -n "$(basename $0)" -o s:r:a:g:n:t:h --long subscription-id:,resource-group:,apim-instance:,gateway-name:,namespace:,token-secret:,help -- "$@")
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
    -h | --help) usage;;
    --) shift; break ;;
    *) echo "Unexpected option: $1 - this should not happen."
       usage ;;
  esac
done

# Error out if variables aren't set
for var in SUBSCRIPTION_ID RESOURCE_GROUP APIM_INSTANCE APIM_GATEWAY NAMESPACE TOKEN_SECRET; do
  if [[ -z "${!var}" ]]; then
    echo -e "\nERROR: Parameter ${var} is undefined. Please specify the parameter as either an environment variable or a command argument."
    usage
  fi
done

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
}
LAST_USED_KEY=${LAST_USED_KEY_ANNOTATION:-primary}
echo "done - last key used was ${LAST_USED_KEY}."


echo
