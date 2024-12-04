#!/bin/bash
# Run this script on hub and spoke clusters to apply the latest hotfixes for 2.8.2 release.

LOG=/tmp/br-post-install-patch-282_$$_log.txt
exec &> >(tee -a $LOG)
echo "Writing output of br-post-install-patch-282.sh script to $LOG"

ISF_NS=$(oc get spectrumfusion -A -o custom-columns=NS:metadata.namespace --no-headers)

if [ -z "$ISF_NS" ]; then
    echo "ERROR: No Successful Fusion installation found. Exiting."
    exit 1
fi

BR_NS=$(oc get dataprotectionserver -A --no-headers -o custom-columns=NS:metadata.namespace)
if [ -n "$BR_NS" ]
 then
 HUB=true
else
   BR_NS=$(oc get dataprotectionagent -A --no-headers -o custom-columns=NS:metadata.namespace)
fi

if [ -z "$BR_NS" ] 
 then
    echo "ERROR: No B&R installation found. Exiting."
    exit 1
fi
AGENTCSV=$(oc -n "$BR_NS" get csv -o name | grep ibm-dataprotectionagent)
VERSION=$(oc -n "$BR_NS" get "$AGENTCSV" -o custom-columns=:spec.version --no-headers)
if [ -z "$VERSION" ] 
 then
    echo "ERROR: Could not get B&R version. Exiting"
    exit 1
fi
if [[ $VERSION != 2.8.2* ]]
 then
    echo "ERROR: This patch appiles to B&R version 2.8.2 only. You have $VERSION"
    exit 1
fi

if [ -n "$HUB" ]
  then
    echo "Apply patches to hub..."

    if (oc get deployment -n $BR_NS backup-location-deployment -o yaml > backup-location-deployment.save.yaml)
      then
        echo "Patching backup-location-deployment image..."
        oc patch deployment backup-location-deployment -n $BR_NS -p '{"spec":{"template":{"spec":{"containers":[{"name":"backup-location-container","image":"cp.icr.io/cp/fbr/guardian-backup-location@sha256:c737450b02a9f415a4c4eea6cc6a67ce0723a8bf5c08ce41469c847c5b598e16"}]}}}}'
    else
        echo "ERROR: Failed to save original backup-location-deployment. Skipped updates."
    fi

    if (oc get deployment -n $BR_NS backuppolicy-deployment -o yaml > backuppolicy-deployment.save.yaml)
      then
        echo "Creating backup-policy service account..."
        oc create sa backup-policy -n $BR_NS

        echo "Creating backup-policy-role cluster role..."
        oc create clusterrole backup-policy-role --verb=get --resource=configmaps

        echo "Creating backup-policy-rolebinding cluster role binding..."
        oc adm policy add-cluster-role-to-user backup-policy-role -z backup-policy  -n $BR_NS --rolebinding-name=backup-policy-rolebinding

        echo "Patching backuppolicy-deployment service account..."
        oc patch deployment backuppolicy-deployment -n $BR_NS -p '{"spec":{"template":{"spec":{"serviceAccountName":"backup-policy"}}}}'

        echo "Patching backuppolicy-deployment image..."
        oc patch deployment backuppolicy-deployment -n $BR_NS -p '{"spec":{"template":{"spec":{"containers":[{"name":"backuppolicy-container","image":"cp.icr.io/cp/fbr/guardian-backup-policy@sha256:32a4ffba0dd2da241bd128ab694fd6fc34a7087aab053a29658e3e0f69ef11aa"}]}}}}'
    else
        echo "ERROR: Failed to save original backuppolicy-deployment. Skipped updates."
    fi

    if (oc get deployment -n $BR_NS backup-service -o yaml > backup-service-deployment.save.yaml)
      then
        echo "Patching backup-service image..."
        oc patch deployment backup-service -n $BR_NS -p '{"spec":{"template":{"spec":{"containers":[{"name":"backup-service","image":"cp.icr.io/cp/fbr/guardian-backup-service@sha256:742367383260fa25fdf1a7cf94a78267361519720869bb6cceac7476b5d5fab3"}]}}}}'
    else
        echo "ERROR: Failed to save original backup-service deployment. Skipped updates."
    fi

    if (oc get recipes.spp-data-protection.isf.ibm.com fusion-control-plane -n $ISF_NS -o yaml > fusion-control-plane-recipe.save.yaml)
      then
        echo "Patching fusion-control-plane recipe..."
        oc patch recipes.spp-data-protection.isf.ibm.com fusion-control-plane -n $ISF_NS --type=merge -p '{"spec":{"hooks":[{"name":"fbr-hooks","nameSelector":"transaction-manager.*","namespace":"${FBR_NAMESPACE}","onError":"fail","ops":[{"command":"[\"/usr/src/app/code/.venv/bin/python3\",\"/usr/src/app/code/ctl-plane.pyc\",\"backup\",\"uid=${BACKUP_ID}\"]","container":"transaction-manager","name":"export-backup-inventory"},{"command":"[\"/usr/src/app/code/.venv/bin/python3\",\"/usr/src/app/code/ctl-plane.pyc\",\"restore\",\"uid=${BACKUP_ID}\"]","container":"transaction-manager","name":"restore-backup-inventory"},{"command":"[\"/usr/src/app/code/.venv/bin/python3\",\"/usr/src/app/code/ctl-plane.pyc\",\"deleteCRs\"]","container":"transaction-manager","name":"deleteCRs"}],"selectResource":"pod","singlePodOnly":true,"timeout":28800,"type":"exec"},{"name":"isf-dp-operator-hook","nameSelector":"transaction-manager.*","namespace":"${FBR_NAMESPACE}","onError":"fail","ops":[{"command":"[\"/usr/src/app/code/.venv/bin/python3\",\"/usr/src/app/code/patch-isd-dp-cm.pyc\",\"${PARENT_NAMESPACE}\",\"isf-data-protection-config\",\"DisableWebhook\"]","container":"transaction-manager","name":"disable-webhook"},{"command":"[\"/usr/src/app/code/.venv/bin/python3\",\"/usr/src/app/code/patch-isd-dp-cm.pyc\",\"${PARENT_NAMESPACE}\",\"isf-data-protection-config\",\"Recover\"]","container":"transaction-manager","name":"quiesce-isf-dp-controller"},{"command":"[\"/usr/src/app/code/.venv/bin/python3\",\"/usr/src/app/code/patch-isd-dp-cm.pyc\",\"${PARENT_NAMESPACE}\",\"isf-data-protection-config\",\"Normal\"]","container":"transaction-manager","name":"unquiesce-isf-dp-controller"}],"selectResource":"pod","singlePodOnly":true,"type":"exec"}]}}'
    else
        echo "ERROR: Failed to save original fusion-control-plane recipe. Skipped updates."
    fi
fi

if (oc get deployment -n $BR_NS transaction-manager -o yaml > transaction-manager-deployment.save.yaml)
  then
    echo "Patching transaction-manager image..."
    oc patch deployment/transaction-manager -n $BR_NS -p '{"spec":{"template":{"spec":{"containers":[{"name":"transaction-manager","image":"cp.icr.io/cp/fbr/guardian-transaction-manager@sha256:0ae46fc2f6e744f79f81005579f4dcb7c9981b201f239433bf1e132f9c89c8cd"}]}}}}'
else
    echo "ERROR: Failed to save original transaction-manager deployment. Skipped updates."
fi

if [[ -z "$SKIP_MINIO" ]];
  then
    echo "Saving old guardian-minio image to old-minio-image.txt"
    oc get statefulset guardian-minio -n $BR_NS -o jsonpath="{.spec.template.spec.containers[0].image}" >> old-minio-image.txt
    echo "Updating statefulset/guardian-minio image to quay.io/minio/minio@sha256:ea15e53e66f96f63e12f45509d2d2d8fad774808debb490f48508b3130bd22d3"
    oc set image statefulset/guardian-minio -n $BR_NS minio=quay.io/minio/minio@sha256:ea15e53e66f96f63e12f45509d2d2d8fad774808debb490f48508b3130bd22d3
fi
