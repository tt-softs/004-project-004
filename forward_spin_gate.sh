#!/bin/bash
count=0
i=0
while [ $count -lt 10 ]
do 
 (( count=$(kubectl get pods -n spinnaker --kubeconfig=kubeconfig | grep '1/1' | wc -l) ))
 sleep 4
 echo "Waiting for spinnaker pods ...."
 (( i++ ))
 if [ $i -gt  225 ]
	then 
	    echo "ERROR:  Spinnaker pods have not ready in 15 minutes"
		exit
	fi
done
GATE_POD=$(kubectl -n spinnaker get pod -l cluster=spin-gate --kubeconfig=kubeconfig -ojsonpath='{.items[0].metadata.name}')
kubectl -n spinnaker port-forward ${GATE_POD} 8084 --kubeconfig=kubeconfig >> /dev/null 2>&1 & 
sleep 5
echo "Creating spinnaker applications"
spin application save --application-name logicapp --owner-email devops-kv53@softserve.com --cloud-providers "kubernetes" --gate-endpoint http://localhost:8084
spin application save --application-name queryapp --owner-email devops-kv53@softserve.com --cloud-providers "kubernetes" --gate-endpoint http://localhost:8084
spin application save --application-name cfgmanapp --owner-email devops-kv53@softserve.com --cloud-providers "kubernetes" --gate-endpoint http://localhost:8084
spin application save --application-name frontendapp --owner-email devops-kv53@softserve.com --cloud-providers "kubernetes" --gate-endpoint http://localhost:8084

echo "Applying pipelines"

spin pipeline save --file pipeline_spin_logicapp.json  --gate-endpoint http://localhost:8084 
spin pipeline save --file pipeline_spin_queryapp.json  --gate-endpoint http://localhost:8084 
spin pipeline save --file pipeline_spin_confmanapp.json  --gate-endpoint http://localhost:8084 
spin pipeline save --file pipeline_spin_frontendapp.json  --gate-endpoint http://localhost:8084 

