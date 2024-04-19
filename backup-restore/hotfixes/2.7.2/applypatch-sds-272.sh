#!/bin/bash

BR_NS=$(oc get dataprotectionserver -A --no-headers -o custom-columns=NS:metadata.namespace)
[ -n "$BR_NS" ] && HUB=true
echo "Saving data before applying SDS patch..."
if [ -n "$HUB" ]
 then
   echo " This is hub"
   oc get deployment -n ibm-backup-restore backup-service -o yaml > backup-service-deployment.save.yaml
   echo "Saved backup-service deployment"
   oc get clusterrole backup-service-role-ibm-backup-restore -o yaml > backup-service-role.save.yaml
   echo "Saved backup-service clusterrole"
   oc get deployment -n ibm-backup-restore job-manager  -o yaml > job-manager-deployment.save.yaml
   echo "Saved job-manager deployment"
   oc get recipes.spp-data-protection.isf.ibm.com fusion-control-plane -n ibm-spectrum-fusion-ns -o yaml > fusion-control-plane-recipe.save.yaml
   echo "Saved fusion-control-plane recipe"
 else
   echo "This is spoke" 
fi

oc get deployment -n ibm-backup-restore transaction-manager -o yaml > transaction-manager-deployment.save.yaml
echo "Saved transaction-manager deployment"
oc get deployment -n ibm-backup-restore application-controller -o yaml > application-controller-deployment.save.yaml
echo "Saved application-controller deployment"



if [ -n "$HUB" ]
 then
  echo "Patching backup-service deployment..."
  oc patch deployment backup-service -n ibm-backup-restore -p '{"spec":{"template":{"spec":{"containers":[{"name":"backup-service","image":"cp.icr.io/cp/fbr/guardian-backup-service:2.7.2-16220444-33283","resources":{"limits":{"ephemeral-storage":"1Gi"},"requests":{"ephemeral-storage":"512Mi"}},"env":[{"name":"POD_NAMESPACE","valueFrom":{"fieldRef":{"apiVersion":"v1","fieldPath":"metadata.namespace"}}}],"volumeMounts":[{"name":"tls-service-ca","readOnly":true,"mountPath":"/etc/tls-service-ca"},{"name":"spdata","mountPath":"/spdata"}]}],"volumes":[{"name":"tls-service-ca","configMap":{"name":"guardian-service-ca","defaultMode":292}},{"name":"spdata","emptyDir":{}}]}}}}'

  echo "Patching backup-service clusterrole..."
  oc patch clusterrole backup-service-role-ibm-backup-restore --type=json -p '[{"op":"add","path":"/rules/-","value":{"verbs":["get"],"apiGroups":[""],"resources":["secrets"]}}]'

  echo "Patching job-manager deployment..."
  oc patch deployment job-manager -n ibm-backup-restore -p '{"spec":{"template":{"spec":{"containers":[{"env":[{"name":"cancelJobAfter","value":"28800000"}],"name":"job-manager-container"}]}}}}'
  
  echo "Patching fusion-control-plane recipe..."
  oc patch recipes.spp-data-protection.isf.ibm.com fusion-control-plane -n ibm-spectrum-fusion-ns --type=merge -p '{"spec":{"hooks":[{"name":"fbr-hooks","nameSelector":"transaction-manager.*","namespace":"${FBR_NAMESPACE}","onError":"fail","ops":[{"command":"[\"/usr/src/app/code/.venv/bin/python3\",\"/usr/src/app/code/ctl-plane.pyc\",\"backup\"]","container":"transaction-manager","name":"export-backup-inventory"},{"command":"[\"/usr/src/app/code/.venv/bin/python3\",\"/usr/src/app/code/ctl-plane.pyc\",\"restore\"]","container":"transaction-manager","name":"restore-backup-inventory","timeout":28800},{"command":"[\"/usr/src/app/code/.venv/bin/python3\",\"/usr/src/app/code/ctl-plane.pyc\",\"deleteCRs\"]","container":"transaction-manager","name":"deleteCRs","timeout":28800}],"selectResource":"pod","singlePodOnly":true,"type":"exec"},{"name":"isf-dp-operator-hook","nameSelector":"transaction-manager.*","namespace":"${FBR_NAMESPACE}","onError":"fail","ops":[{"command":"[\"/usr/src/app/code/.venv/bin/python3\",\"/usr/src/app/code/patch-isd-dp-cm.pyc\",\"${PARENT_NAMESPACE}\",\"isf-data-protection-config\",\"DisableWebhook\"]","container":"transaction-manager","name":"disable-webhook"},{"command":"[\"/usr/src/app/code/.venv/bin/python3\",\"/usr/src/app/code/patch-isd-dp-cm.pyc\",\"${PARENT_NAMESPACE}\",\"isf-data-protection-config\",\"Recover\"]","container":"transaction-manager","name":"quiesce-isf-dp-controller"},{"command":"[\"/usr/src/app/code/.venv/bin/python3\",\"/usr/src/app/code/patch-isd-dp-cm.pyc\",\"${PARENT_NAMESPACE}\",\"isf-data-protection-config\",\"Normal\"]","container":"transaction-manager","name":"unquiesce-isf-dp-controller"}],"selectResource":"pod","singlePodOnly":true,"type":"exec"},{"name":"appcontroller-restart","nameSelector":"application-controller","namespace":"${FBR_NAMESPACE}","onError":"fail","selectResource":"deployment","type":"scale"}]}}'
fi

echo "Patching transaction-manager deployment..."
oc patch deployment/transaction-manager -n ibm-backup-restore -p '{"spec":{"template":{"spec":{"containers":[{"name":"transaction-manager","image":"cp.icr.io/cp/fbr/guardian-transaction-manager:2.7.2-16317973-33579"}]}}}}'

echo "Patching application-controller deployment..."
oc patch deployment/application-controller -n ibm-backup-restore -p '{"spec":{"template":{"spec":{"containers":[{"name":"application-controller","image":"cp.icr.io/cp/fbr/guardian-transaction-manager:2.7.2-16317973-33579"}]}}}}'

echo "Deployment rollout status..."
if [ -n "$HUB" ]
 then
  oc rollout status -n ibm-backup-restore deployment backup-service  job-manager  transaction-manager application-controller
 else
  oc rollout status -n ibm-backup-restore deployment transaction-manager application-controller
fi


DM_CSV=$(oc get csv -n ibm-backup-restore | grep guardian-dm-operator | awk '{print $1}')
echo "Saving original guardian-dm-operator yaml"
oc get csv -n ibm-backup-restore ${DM_CSV} -o yaml > guardian-dm-operator.v2.7.2-original.yaml
oc get configmap  -n ibm-backup-restore guardian-dm-image-config -o yaml > guardian-dm-image-config-original.yaml
echo Updating data mover image...
oc set data -n ibm-backup-restore cm/guardian-dm-image-config DM_IMAGE=cp.icr.io/cp/fbr/guardian-datamover:2.7.2-16061418-33705
echo Updating CSV $DM_CSV...
oc patch csv -n ibm-backup-restore $DM_CSV  --type='json' -p='[{"op":"replace", "path":"/spec/install/spec/deployments/0/spec/template/spec/containers/1/image", "value":"icr.io/cpopen/guardian-dm-operator:2.7.2-16061418-33705"}]'

ISF_CSV=$(oc get csv -n ibm-spectrum-fusion-ns | grep "isf-operator.v2.7.2" | awk '{print $1}')
if [[ -z ${ISF_CSV} ]]; then
    echo "Cannot find the isf-operator.v2.7.2"
    exit 1
fi
echo "Saving original to isf-operator.v2.7.2-original.yaml"
oc get csv -n ibm-spectrum-fusion-ns ${ISF_CSV} -o yaml > isf-operator.v2.7.2-original.yaml
echo "Updating SDS csv ${ISF_CSV}"
oc patch csv -n ibm-spectrum-fusion-ns $ISF_CSV  --type='json' -p='[{"op":"replace", "path":"/spec/install/spec/deployments/4/spec/template/spec/containers/0/image", "value":"cp.icr.io/cp/isf-sds/isf-application-operator:2.7.2-f2f8eec-31017"}]'
