#!/bin/bash

# Use this script to destroy cluster via terraform command
terraform state rm kubernetes_namespace.spinnaker
terraform state rm module.postgres.google_sql_user.default
yes yes | terraform destroy
