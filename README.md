# Description
Terrafrom GKE cluster, Postgres DB installation
## Requirements 
* Use terrafrom v0.12.6 version minimum
* Use kubectl v1.15.1 version minimum
* Use helm v2.14.3 version minimum
* Configuration variables can be changed in files:
  ```shell
  variables.tf
  ```
## Before start
* Install utilities before terraform launch:
  ``` 
  jq
  spin
  ```
  read more here https://stedolan.github.io/jq/, https://www.spinnaker.io/setup/spin/
* add istio repo
   helm repo add banzaicloud-stable http://kubernetes-charts.banzaicloud.com/branch/master
   helm repo update
   
## How to run
* Create Google service accout for terraform
* Set variables in variables.tf :
  ```
  project_name - GCP project name
  gloud_creds_file - GCP json service account path
  ```
* Run:
  ```
  terraform init
  terraform apply
  ```
## Issues
* 'terraform destroy' may fail due to dependencies error. Use bash script to avoid those errors during destroy:
  ```
  ./destroy-terraform.sh
  ```
