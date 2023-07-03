#!/bin/bash
set -xeuo pipefail

function extract_oc(){
    mkdir -p /tmp/client
    export OC_DIR="/tmp/client"
    export PATH=${OC_DIR}:$PATH

    echo -e "Extracting oc\n"
    local retry=5 tmp_oc="/tmp/client-2"
    mkdir -p ${tmp_oc}
    while ! (env "NO_PROXY=*" "no_proxy=*" oc adm release extract -a "${CLUSTER_PROFILE_DIR}/pull-secret" --command=oc --to=${tmp_oc} ${RELEASE_IMAGE_TARGET});
    do
        echo >&2 "Failed to extract oc binary, retry..."
        (( retry -= 1 ))
        if (( retry < 0 )); then return 1; fi
        sleep 60
    done
    mv ${tmp_oc}/oc ${OC_DIR} -f
    which oc
    oc version --client
    return 0
}

version=$(oc get -o jsonpath='{.status.desired.version}' clusterversion version)
major_rel=$(echo $version | cut -d '.' -f1)
minor_rel=$(echo $version | cut -d '.' -f2)
if [[ ${major_rel} -eq 4 && ${minor_rel} -lt 10 ]];then
    echo "version is less than 4.10, extract oc client from 4.10 release image"
    extract_oc
fi

start_date=$(date +"%Y-%m-%dT%H:%M:%S%:z")

# ensure we're stable to start
oc adm wait-for-stable-cluster --minimum-stable-period=5s

# Regenerating the Internal CA for Ingress
proxyKey="temProxy.key"
proxyCert="temProxy.pem"
cusIngressKey="wilcard.key"
cusIngressCsr="wildcard.csr"
cusIngressCert="wildcard.pem"
keyLength=4096
baseDomin=$(oc get dns.config cluster -o=jsonpath='{.spec.baseDomain}')
defaultIngressDomin=$(oc get ingresscontroller default  -o=jsonpath='{.status.domain}' -n openshift-ingress-operator)
currentPath=$(pwd)
workPath="/tmp/replcertforingress"
mkdir $workPath; cd $workPath
cat <<EOF > tmp.conf
[cus]
subjectAltName = DNS:*.$defaultIngressDomin
EOF

## create root ca for cluster proxy and certification for default ingress controller
openssl req -newkey rsa:$keyLength -nodes -sha256 -keyout $proxyKey -x509 -days 30 -subj "/CN=$baseDomin" -out $proxyCert
openssl genrsa -out $cusIngressKey $keyLength
openssl req -new -key $cusIngressKey  -subj "/CN=$defaultIngressDomin" -addext "subjectAltName = DNS:*.$defaultIngressDomin" -out  $cusIngressCsr
openssl x509 -req -days 30 -CA $proxyCert -CAkey $proxyKey -CAserial caproxy.srl -CAcreateserial -extfile  tmp.conf -extensions cus -in $cusIngressCsr -out $cusIngressCert

## create a config map and update the cluster-wide proxy configuration with the newly created config map
oc create configmap custom-ca --from-file=ca-bundle.crt=$workPath/$proxyCert -n openshift-config
oc patch proxy/cluster --type=merge --patch='{"spec":{"trustedCA":{"name":"custom-ca"}}}'

## create secret and update the Ingress Controller configuration with the newly created secret
oc create secret tls custom-secret --cert=$workPath/$cusIngressCert --key=$workPath/$cusIngressKey -n openshift-ingress
oc patch ingresscontroller.operator default --type=merge -p '{"spec":{"defaultCertificate": {"name": "custom-secret"}}}' -n openshift-ingress-operator

## get ingress-operator pod name and secrets/router-ca created time
oldPod=$(oc -n openshift-ingress-operator get pods  -l name=ingress-operator -o=jsonpath='{.items[0].metadata.name}')
oldRouterCaTime=$(oc -n openshift-ingress-operator get secrets/router-ca -o=jsonpath='{.metadata.creationTimestamp}')

## remove workPath folder
cd $currentPath; rm -rf $workPath

## delete secrets/router-ca and restart the Ingress Operator
oc -n openshift-ingress-operator delete secrets/router-ca
oc -n openshift-ingress-operator delete pods -l name=ingress-operator
oc adm wait-for-stable-cluster

## check if new ingress-operator pod and new secret router-ca are created or not
newPod=$(oc -n openshift-ingress-operator get pods  -l name=ingress-operator -o=jsonpath='{.items[0].metadata.name}')
newRouterCaTime=$(oc -n openshift-ingress-operator get secrets/router-ca -o=jsonpath='{.metadata.creationTimestamp}')
if [ -z "$newPod" ] || [ X"$newPod" == X"$oldPod" ]
then
    echo "new ingress controller pod is not created or old ingress controller pod is not deleted" && exit 1
fi
if [ -z "$newRouterCaTime" ] || [ X"$newRouterCaTime" == X"$oldRouterCaTime" ]
then
    echo "new secret router-ca is not created or old secret router-ca is not deleted" && exit 1
fi

# Let's start with the MCO cert rotation
oc adm ocp-certificates regenerate-machine-config-server-serving-cert

# A few preparatory rotations, these give us 30 days to complete the rotation after generating new roots of trust
oc adm ocp-certificates regenerate-leaf -n openshift-config-managed secrets kube-controller-manager-client-cert-key kube-scheduler-client-cert-key
oc adm ocp-certificates regenerate-leaf -n openshift-kube-apiserver-operator secrets node-system-admin-client
oc adm ocp-certificates regenerate-leaf -n openshift-kube-apiserver secrets check-endpoints-client-cert-key control-plane-node-admin-client-cert-key  external-loadbalancer-serving-certkey internal-loadbalancer-serving-certkey kubelet-client localhost-recovery-serving-certkey localhost-serving-cert-certkey service-network-serving-certkey
oc adm wait-for-stable-cluster

# generate new roots of trust
oc adm ocp-certificates regenerate-top-level -n openshift-kube-apiserver-operator secrets kube-apiserver-to-kubelet-signer kube-control-plane-signer  loadbalancer-serving-signer  localhost-serving-signer service-network-serving-signer
oc -n openshift-kube-controller-manager-operator delete secrets/next-service-account-private-key
oc -n openshift-kube-apiserver-operator delete secrets/next-bound-service-account-signing-key
oc adm wait-for-stable-cluster

# skip the AWS STS bound SA changes because we don't have the aws CLI or know where this info is stored.

# generate new client certs for kcm and ks
oc adm ocp-certificates regenerate-leaf -n openshift-config-managed secrets kube-controller-manager-client-cert-key kube-scheduler-client-cert-key

# distribute trust across all known clients
# update our local CA bundle so that when new serving certs are used for kube-apiserver we will trust them
oc config refresh-ca-bundle
# produce a new kubelet bootstrap kubeconfig (used to create the first CSR and establishes ca bundle)
oc config new-kubelet-bootstrap-kubeconfig > /tmp/bootstrap.kubeconfig
oc whoami --kubeconfig=/tmp/bootstrap.kubeconfig --server="$(oc get infrastructure/cluster -ojsonpath='{ .status.apiServerURL }')"
# distribute to nodes
oc adm copy-to-node nodes --all --copy=/tmp/bootstrap.kubeconfig=/etc/kubernetes/kubeconfig
# make all nodes use the new ca bundle
oc adm restart-kubelet nodes --all --directive=RemoveKubeletKubeconfig
# delete all pods to ensure that new kube-apiserver ca bundles are used by all pods
oc adm reboot-machine-config-pool mcp/worker mcp/master
oc adm wait-for-node-reboot nodes --all

# now that trust is distributed, create new certificates using new roots
oc adm ocp-certificates regenerate-leaf -n openshift-kube-apiserver-operator secrets node-system-admin-client
oc adm ocp-certificates regenerate-leaf -n openshift-kube-apiserver secrets check-endpoints-client-cert-key control-plane-node-admin-client-cert-key  external-loadbalancer-serving-certkey internal-loadbalancer-serving-certkey kubelet-client localhost-recovery-serving-certkey localhost-serving-cert-certkey service-network-serving-certkey
oc adm wait-for-stable-cluster

# create new admin.kubeconfig
oc config new-admin-kubeconfig > /tmp/admin.kubeconfig
oc --kubeconfig=/tmp/admin.kubeconfig whoami

# revoke old trust for the signers we have regenerated
oc adm ocp-certificates remove-old-trust -n openshift-kube-apiserver-operator configmaps kube-apiserver-to-kubelet-client-ca kube-control-plane-signer-ca loadbalancer-serving-ca localhost-serving-ca service-network-serving-ca  --created-before=${start_date}
oc adm wait-for-stable-cluster
oc adm reboot-machine-config-pool mcp/worker mcp/master
oc adm wait-for-node-reboot nodes --all