#!/usr/bin/env bash

# vanta-gcp-projects-federation-setup-script.sh takes a Vanta-provided external ID, Vanta's AWS account ID,
# and user-specified GCP projects and provisions the necessary permissions for Vanta to scan the specified
# projects.
#
# This script will:
# 1. Create a vanta-scanner project under your organization.
# 2. Enable the required APIs on the created vanta-scanner project.
# 3. Create a custom role, VantaProjectScanner, for listing resources in a GCP
#    project.
# 4. (Optional) Create a custom role, VantaOrganizationScanner, for listing essential contacts and IAM policies
#    inherited by a GCP project from the organization level.
# 5. Create a workload identity pool and provider that allows the scanner role from Vanta's AWS account to
#    authenticate as the vanta-scanner subject.
# 6. (Optional) Grant the vanta-scanner subject the VantaOrganizationScanner role in the organization
#    enclosing the first GCP project.
# 7. For each specified project:
#     i. Grant the vanta-scanner subject the VantaProjectScanner role.
#     ii. Grant the vanta-scanner subject the roles/iam.securityReviewer standard role.
# 8. Print the vanta-scanner project number.
#
# NOTE: The VantaOrganizationScanner role is optional. If omitted, we will not be able to fetch essential contacts and inherited roles and their bindings.
#
# NOTE: This script is idempotent so you may rerun this script to get the same desired permissions.
#
# USAGE:
#   bash vanta-gcp-projects-federation-setup-script.sh "Vanta-provided external ID" "Vanta's AWS account ID" "one-project" "another-project"
#
# OUTPUT: The project number of the created GCP project. Copy this value into the GCP connection flow at
#   https://app.vanta.com/integrations.

awsRoleName="scanner-apj"
identityProviderID="vanta-aws-apj"
orgRoleID="VantaOrganizationScanner-apj"
projectName="vanta-scanner-apj"
projectRoleID="VantaProjectScannerAPJ"
subjectName="vanta-scanner-apj"

set -e

# Logging utilities
purple='\033[0;35m'
nc='\033[0m'
prefix="${purple}[ Vanta ]${nc}"

# Check for gcloud.
if ! command -v gcloud &>/dev/null; then
  printf "${prefix} ERROR: gcloud CLI unavailable.\nSee https://cloud.google.com/sdk/docs/quickstart for installation instructions.\n"
  exit
fi

# Parse external ID from arguments.
externalID=$1
if [ -z "${externalID}" ]; then
  printf "${prefix} ERROR: no external ID provided. Find this value in the Vanta GCP connection flow.\n"
  exit
elif [[ ! "${externalID}" =~ ^[a-z0-9]{15}$ ]]; then
  printf "${prefix} ERROR: invalid external ID ${externalID}. Find the correct value in the Vanta GCP connection flow.\n"
  exit
fi
identityPoolID="vanta-${externalID}"

# Parse AWS account ID from arguments.
awsAccountID=$2
if [ -z "${awsAccountID}" ]; then
  printf "${prefix} ERROR: no Vanta AWS account ID provided. Find this value in the Vanta GCP connection flow.\n"
  exit
elif [[ ! "${awsAccountID}" =~ ^[0-9]{12}$ ]]; then
  printf "${prefix} ERROR: invalid Vanta AWS account ID ${awsAccountID}. Find the correct value in the Vanta GCP connection flow.\n"
  exit
fi

# Parse GCP projects from arguments.
shift 2
projects=("$@")
project0="${projects[0]}"
if [ -z "$project0" ]; then
  printf "${prefix} ERROR: no GCP projects specified.\n"
  exit
fi

# Select GCP organization ancestor from first project.
orgID=$(
  gcloud projects get-ancestors "${project0}" --format="value(id,type)" |
    grep "organization" |
    cut -f1
)
if [ -z "$orgID" ]; then
  printf "${prefix} ERROR: no organization ancestor for ${project0}\n"
  exit
fi

orgName=$(
  gcloud organizations describe "${orgID}" --format=json | jq -r '.displayName'
)

findProjectJson=$(
  gcloud projects list --filter="name=${projectName} AND parent.id=${orgID} AND parent.type=organization" --format=json
)

secondProjectWithSameProjectName=$(
  echo "$findProjectJson" | jq -r '.[1] // empty'
)
if [ -n "$secondProjectWithSameProjectName" ]; then
  printf "${prefix} [ERROR] Multiple projects named ${projectName} exist in organization ${orgName}.\n"
  exit
fi

projectID=$(
  echo "$findProjectJson" | jq -r '.[0] | .projectId // empty'
)

if [ -z "$projectID" ]; then
  # Create vanta-scanner project under the specified organization if no existing project found
  printf "${prefix} Creating project ${projectName} under organization ${orgName}.\n"
  timestamp=$(perl -MTime::HiRes -e 'printf("%.0f\n", Time::HiRes::time() * 1000)')
  gcloud projects create ${projectName}-"${timestamp}" --name="${projectName}" --organization="${orgID}" --quiet
  projectID=$(
    gcloud projects list --filter="name=${projectName} AND parent.id=${orgID} AND parent.type=organization" --format=json | jq -r '.[0] | .projectId'
  )
else
  printf "${prefix} Project ${projectName} (${projectID}) already exists under organization ${orgName}, no need to create, continuing.\n"
fi

projectNum=$(
  gcloud projects describe "${projectID}" --format="value(projectNumber)"
)

subjectURI="principal://iam.googleapis.com/projects/${projectNum}/locations/global/workloadIdentityPools/${identityPoolID}/subject/${subjectName}"

gcloud services enable --project="${projectID}" --quiet --no-user-output-enabled \
  bigquery.googleapis.com \
  cloudasset.googleapis.com \
  cloudresourcemanager.googleapis.com \
  cloudkms.googleapis.com \
  containeranalysis.googleapis.com \
  essentialcontacts.googleapis.com \
  firestore.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  logging.googleapis.com \
  monitoring.googleapis.com \
  pubsub.googleapis.com \
  serviceusage.googleapis.com \
  sqladmin.googleapis.com \
  storage-api.googleapis.com \
  sts.googleapis.com &&
  printf "${prefix} Enabled required APIs for project ${projectName}.\n" ||
  (printf "${prefix} [ERROR] Failed to enable required APIs for project ${projectName}.\n" && exit)

printf "${prefix} Creating custom role ${projectRoleID} for listing project resources with configuration metadata.\n"
# If the role already exists, update it.
gcloud iam roles create "$projectRoleID" --organization "$orgID" --verbosity=critical ||
  printf "${prefix} [ERROR] Failed to create custom role. This is expected if ${projectRoleID} role already exists in organization ${orgName}.\n"

gcloud iam roles update "$projectRoleID" --organization "$orgID" --quiet --no-user-output-enabled --permissions "\
resourcemanager.projects.get,\
bigquery.datasets.get,\
compute.instances.get,\
compute.instances.getEffectiveFirewalls,\
compute.subnetworks.get,\
pubsub.topics.get,\
storage.buckets.get,\
cloudasset.assets.searchAllResources"

# These permissions on the organization are optional
# If omitted, we will not be able to fetch inherited roles and their bindings
printf "${prefix} Creating custom role ${orgRoleID} for listing inhertited IAM policies.\n"
# If the role already exists, update it.
gcloud iam roles create "$orgRoleID" --organization "$orgID" --verbosity=critical  ||
  printf "${prefix} [ERROR] Failed to create custom role ${orgRoleID}. This is expected if ${orgRoleID} role already exists in organization ${orgName}.\n"

gcloud iam roles update "$orgRoleID" --organization "$orgID" --quiet --no-user-output-enabled --permissions "\
essentialcontacts.contacts.list,\
iam.roles.list,\
resourcemanager.organizations.getIamPolicy,\
resourcemanager.folders.getIamPolicy"

while ! gcloud iam workload-identity-pools list \
  --location="global" \
  --project="${projectID}" \
  &> /dev/null; do
  printf "${prefix} Waiting for project ${projectName} to finish setup. This may take a minute...\n"
  sleep 15
done

existingIdentityPoolState=$(
  gcloud iam workload-identity-pools list \
    --location="global" \
    --project="${projectID}" \
    --show-deleted \
    --filter="name=projects/${projectNum}/locations/global/workloadIdentityPools/${identityPoolID}" \
    --format="value(state)" \
    --verbosity="error"
)
if [ -z "${existingIdentityPoolState}" ]; then
  printf "${prefix} Creating workload identity pool ${identityPoolID} in project ${projectName}.\n"
  gcloud iam workload-identity-pools create "${identityPoolID}" \
    --location="global" \
    --project="${projectID}" \
    --display-name="Vanta"
elif [ "${existingIdentityPoolState}" = "ACTIVE" ]; then
  printf "${prefix} Workload identity pool ${identityPoolID} already exists.\n"
elif [ "${existingIdentityPoolState}" = "DELETED" ]; then
  printf "${prefix} Undeleting workload identity pool ${identityPoolID} in project ${projectName}.\n"
  gcloud iam workload-identity-pools undelete "${identityPoolID}" \
    --location="global" \
    --project="${projectID}" \
    --format="none"
else
  printf "${prefix} [ERROR] Workload identity pool ${identityPoolID} in project ${projectName} has unexpected state ${existingIdentityPoolState}.\n"
  exit
fi

while ! gcloud iam workload-identity-pools providers list \
  --location="global" \
  --project="${projectID}" \
  --workload-identity-pool="${identityPoolID}" \
  &> /dev/null; do
  printf "${prefix} Waiting for workload identity pool ${identityPoolID} to finish setup...\n"
  sleep 5
done

existingIdentityProviderState=$(
  gcloud iam workload-identity-pools providers list \
    --location="global" \
    --project="${projectID}" \
    --workload-identity-pool="${identityPoolID}" \
    --show-deleted \
    --filter="name=projects/${projectNum}/locations/global/workloadIdentityPools/${identityPoolID}/providers/${identityProviderID}" \
    --format="value(state)" \
    --verbosity="error"
)
if [ -z "${existingIdentityProviderState}" ]; then
  printf "${prefix} Creating workload identity provider ${identityProviderID} in identity pool ${identityPoolID}.\n"
  gcloud iam workload-identity-pools providers create-aws "${identityProviderID}" \
    --location="global" \
    --project="${projectID}" \
    --workload-identity-pool="${identityPoolID}" \
    --account-id="${awsAccountID}"
elif [ "${existingIdentityProviderState}" = "ACTIVE" ]; then
  printf "${prefix} Workload identity provider ${identityProviderID} already exists.\n"
elif [ "${existingIdentityProviderState}" = "DELETED" ]; then
  printf "${prefix} Undeleting workload identity provider ${identityProviderID} in identity pool ${identityPoolID}.\n"
  gcloud iam workload-identity-pools providers undelete "${identityProviderID}" \
    --location="global" \
    --project="${projectID}" \
    --workload-identity-pool="${identityPoolID}" \
    --format="none"
else
  printf "${prefix} [ERROR] Workload identity provider ${identityProviderID} in identity pool ${identityPoolID} has unexpected state ${existingIdentityProviderState}.\n"
  exit
fi

printf "${prefix} Updating workload identity provider ${identityProviderID}.\n"
gcloud iam workload-identity-pools providers update-aws "${identityProviderID}" \
  --location="global" \
  --project="${projectID}" \
  --workload-identity-pool="${identityPoolID}" \
  --display-name="Vanta AWS" \
  --account-id="${awsAccountID}" \
  --attribute-mapping="google.subject='${subjectName}',attribute.arn=assertion.arn" \
  --attribute-condition="attribute.arn.extract('assumed-role/{role}/') == '${awsRoleName}'" \
  --format="none"

printf "${prefix} Granting role ${orgRoleID} to subject ${subjectName} in organization ${orgName}.\n"
gcloud organizations add-iam-policy-binding "${orgID}" \
  --member "${subjectURI}" \
  --role "organizations/${orgID}/roles/${orgRoleID}" --condition=None --format=none

printf "${prefix} Granting role ${projectRoleID} to subject ${subjectName} for project ${projectID}.\n"
gcloud projects add-iam-policy-binding "$projectID" \
  --member "${subjectURI}" \
  --role "organizations/${orgID}/roles/${projectRoleID}" --condition=None --format=none
printf "${prefix} Granting role securityReviewer to subject ${subjectName} for project ${projectID}.\n"
gcloud projects add-iam-policy-binding "$projectID" \
  --member "${subjectURI}" \
  --role "roles/iam.securityReviewer" --condition=None --format=none

# For every project, grant the required project-level roles.
printf "${prefix} Granting roles for specified projects.\n"
for PROJECT in ${projects[@]}; do
  printf "${prefix} Granting role ${projectRoleID} to subject ${subjectName} for project ${PROJECT}.\n"
  gcloud projects add-iam-policy-binding "$PROJECT" \
    --member "${subjectURI}" \
    --role "organizations/${orgID}/roles/${projectRoleID}" --condition=None --format=none
  printf "${prefix} Granting role securityReviewer to subject ${subjectName} for project ${PROJECT}.\n"
  gcloud projects add-iam-policy-binding "$PROJECT" \
    --member "${subjectURI}" \
    --role "roles/iam.securityReviewer" --condition=None --format=none
done

# Add a 60-second sleep after the last role assignment
printf "${prefix} Waiting 60 seconds to ensure changes are fully propagated.\n"
sleep 60

printf "${prefix} Configuration completed. Copy the project number below into the Vanta GCP connection flow to finish.\n"
printf "${prefix} Project number: ${projectNum}\n"
