#!/bin/bash

set -exo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/util.sh"

directory_id=""
application_id=""
secret=""
wasb_sas_token=""
key_vault_url=""
databricks_url=""
adls_store=""

function Usage() {
  cat << EOF
Usage: "$0 [options]"

Options:
  -d <dir ID>    Azure Active Directory directory ID for the registered application. Required when storage is ADLS. [default: $directory_id]
  -a <app ID>    Registered application\'s ID. Required when storage is ADLS. [default: $application_id]
  -S <secret>    Registered application\'s key for access to ADLS. Required when storage is ADLS. [default: $secret]
  -t <sas token> Shared Access Signature token. Required when storage is WASB.
  -K <key vault URL> Azure Key Vault URL. Required when storage is ADLS.
  -da <Databricks URL> Databricks Service URL. Required to run Spark job in Databricks cluster.
  -adls <ADLS Store> ADLS Store name. Required when storage is ADLS.
EOF
}

while getopts "u:d:a:S:t:K:h" opt; do
  case $opt in
    d  ) directory_id=$OPTARG ;;
    a  ) application_id=$OPTARG ;;
    S  ) secret=$OPTARG ;;
    t  ) wasb_sas_token=$OPTARG ;;
    K  ) key_vault_url=$OPTARG ;;
    da ) databricks_url=$OPTARG ;;
    adls ) adls_store=$OPTARG ;;
    h  ) Usage && exit 0 ;;
    \? ) LogError "Invalid option: -$OPTARG" ;;
    :  ) LogError "Option -$OPTARG requires an argument." ;;
  esac
done

trifacta_basedir="/opt/trifacta"
triconf="$trifacta_basedir/conf/trifacta-conf.json"
create_db_roles_script="$trifacta_basedir/bin/setup-utils/db/trifacta-create-postgres-roles-dbs.sh"

trifacta_user="trifacta"

function CreateCustomerKey() {
  local keyfile="$trifacta_basedir/conf/.key/customerKey"
  if [[ -f "$keyfile" ]]; then
    LogWarning "Found existing key file (\"$keyfile\"). Leaving as is."
  else
    LogInfo "Creating customer key file \"$keyfile\""
    echo "$(RandomString 16)" > "$keyfile"
    chmod 600 "$keyfile"
  fi
}


function CheckValueSetOrExit() {
  local name="$1"
  local value="$2"
  if [[ -z "$value" ]]; then
    LogError "Error: \"$name\" is empty. Exiting."
  else
    LogInfo "$name : $value"
  fi
}

function ConfigurePostgres() {
  local pg_version="9.6"
  local pg_dir="/etc/postgresql/$pg_version/main/"
  local pg_conf="$pg_dir/postgresql.conf"

  local pg_port=$(grep -Po "^port[ \t]*=[ \t]*\K[0-9]+" "$pg_conf")

  LogInfo "Configuring PostgreSQL"
  CheckValueSetOrExit "PostgreSQL version" "pg_version"
  CheckValueSetOrExit "PostgreSQL conf" "$pg_conf"
  CheckValueSetOrExit "PostgreSQL port" "$pg_port"

  sed -i "s@5432@$pg_port@g" "$triconf"
}

function CreateDBRoles() {
  # Must be run after ConfigurePostgres
  LogInfo "Creating DB roles"
  bash "$create_db_roles_script"
}

function GetHostFromString() {
  echo "$1" | cut -d: -f1
}

function GetPortFromString() {
  echo "$1" | cut -d: -f2
}


function ConfigureSecureTokenService() {
  # Secure Token Service: Refresh Token Encryption Key
  local refresh_token_encryption_key=$(RandomString 16 | base64)

  jq ".[\"secure-token-service\"].systemProperties[\"server.port\"] = \"8090\" |
    .[\"secure-token-service\"].systemProperties[\"com.trifacta.services.secure_token_service.refresh_token_encryption_key\"] = \"$refresh_token_encryption_key\"" \
    "$triconf" | sponge "$triconf"
}

function ConfigureUdfService() {
  LogInfo "Configuring UDF service"

  # The edge node on HDI clusters doesn't handle websocket compression correctly
  # Turning it off sustains websocket connections and udfs work with this change
  local jvm_options="-Dorg.apache.tomcat.websocket.DISABLE_BUILTIN_EXTENSIONS=true"
  jq ".[\"udf-service\"].jvmOptions = [\"$jvm_options\"]" "$triconf" | sponge "$triconf"
}

function ConfigureAzureDatabricks() {
  CheckValueSetOrExit "Databricks URL" "$service_url"

  jq ".databricks.serviceUrl = \"$service_url\"" \
    "$triconf" | sponge "$triconf"
}


function ConfigureAzureCommon() {
  CheckValueSetOrExit "Directory ID" "$directory_id"
  CheckValueSetOrExit "Application ID" "$application_id"
  CheckValueSetOrExit "Secret" "$secret"

  jq ".azure.directoryid = \"$directory_id\" |
    .azure.applicationid = \"$application_id\" |
    .azure.secret = \"$secret\" |
    .azure.keyVaultUrl = \"$key_vault_url\"" \
    "$triconf" | sponge "$triconf"
}

function ConfigureADLS() {
  local adls_host=${adls_store}.azuredatalakestore.net
  local adls_uri="adl://${adls_host}"
  local adls_prefix=""

  LogInfo "Configuring ADLS"
  CheckValueSetOrExit "ADLS URI" "$adls_uri"
  CheckValueSetOrExit "ADLS Prefix" "$adls_prefix"

  jq ".webapp.storageProtocol = \"hdfs\" |
    .hdfs.username = \"$trifacta_user\" |
    .hdfs.enabled = true |
    .hdfs.protocolOverride = \"adl\" |
    .hdfs.highavailability.serviceName = \"$adls_host\" |
    .hdfs.namenode.host = \"$adls_host\" |
    .hdfs.namenode.port = 443 |
    .hdfs.webhdfs.httpfs = false |
    .hdfs.webhdfs.ssl.enabled = true |
    .hdfs.webhdfs.host = \"$adls_host\" |
    .hdfs.webhdfs.version = \"/webhdfs/v1\" |
    .hdfs.webhdfs.credentials.username = \"$trifacta_user\" |
    .hdfs.webhdfs.port = 443 |
    .hdfs.pathsConfig.fileUpload = \"${adls_prefix}/trifacta/uploads\" |
    .hdfs.pathsConfig.dictionaries = \"${adls_prefix}/trifacta/dictionaries\" |
    .hdfs.pathsConfig.libraries = \"${adls_prefix}/trifacta/libraries\" |
    .hdfs.pathsConfig.tempFiles = \"${adls_prefix}/trifacta/tempfiles\" |
    .hdfs.pathsConfig.sparkEventLogs = \"${adls_prefix}/trifacta/sparkeventlogs\" |
    .hdfs.pathsConfig.batchResults = \"${adls_prefix}/trifacta/queryResults\" |
    .hdfs.pathsConfig.globalDatasourceCache = \"${adls_prefix}/trifacta/.datasourceCache\" |
    .azure.resourceURL = \"https://datalake.azure.net/\" |
    .azure.adl.mode = \"system\" |
    .azure.adl.enabled = true |
    .azure.adl.store = \"$adls_uri\"" \
    "$triconf" | sponge "$triconf"
}

function ConfigureWASB() {
  local wasb_service_name=$(GetDefaultFS)
  local wasb_container=$(echo "$wasb_service_name" | cut -d@ -f1 | cut -d/ -f3)
  local wasb_host=$(echo "$wasb_service_name" | cut -d@ -f2)

  LogInfo "Configuring WASB"
  CheckValueSetOrExit "WASB service name" "$wasb_service_name"
  CheckValueSetOrExit "WASB Host" "$wasb_host"
  CheckValueSetOrExit "WASB Shared Access Signature token" "$wasb_sas_token"

  jq ".webapp.storageProtocol = \"wasbs\" |
    .hdfs.enabled = false |
    .azure.wasb.enabled = true |
    .azure.wasb.fetchSasTokensFromKeyVault = false |
    .azure.wasb.defaultStore.blobHost = \"$wasb_host\" |
    .azure.wasb.defaultStore.container = \"$wasb_container\" |
    .azure.wasb.defaultStore.sasToken = \"$wasb_sas_token\"" \
    "$triconf" | sponge "$triconf"

}



function ConfigureAzureStorage() {
  LogInfo "Configuring HDI"

  fs_type=$(GetDefaultFSType)
  CheckValueSetOrExit "Default FS Type" "$fs_type"

  if [[ "$fs_type" == "adl" ]]; then
    ConfigureADLS
  elif [[ "$fs_type" == "wasb" || "$fs_type" == "wasbs" ]]; then
    ConfigureWASB
  else
    LogError "Unsupported filesystem (\"$fs_type\"). Exiting."
  fi
}

function ConfigureEdgeNode() {
  LogInfo "Configuring edge node"

  local total_cores=$(GetCoreCount)

  # Num. webapp processes = round(cores/3) + 1
  local webapp_num_procs=$(echo "$(Round $(echo $total_cores/3 | bc -l)) + 1" | bc)
  # Num. webapp DB connections = cores * 2
  local webapp_db_max_connections=$(echo "$total_cores*2" | bc)

  # Num. VFS processes = (# of webapp processes) / 2
  local vfs_num_procs=$(echo "$webapp_num_procs/2" | bc)

  # Num. photon processes = round(cores/6) + 1
  local photon_num_procs=$(echo "$(Round $(echo $total_cores/6 | bc -l)) + 1" | bc)
  if [[ "$total_cores" > 16 ]]; then
    photon_num_threads="4"
  else
    photon_num_threads="2"
  fi
  photon_mem_thresh="50"

  LogInfo "Webapp processes           : $webapp_num_procs"
  LogInfo "Webapp max connections     : $webapp_db_max_connections"
  LogInfo "VFS service processes      : $vfs_num_procs"
  LogInfo "Photon processes           : $photon_num_procs"
  LogInfo "Photon threads per process : $photon_num_threads"
  LogInfo "Photon memory threshold    : $photon_mem_thresh"

  jq ".webapp.numProcesses = $webapp_num_procs |
    .webapp.db.pool.maxConnections = $webapp_db_max_connections |
    .[\"vfs-service\"].numProcesses = $vfs_num_procs |
    .batchserver.workers.photon.max  = $photon_num_procs |
    .batchserver.workers.photon.memoryPercentageThreshold = $photon_mem_thresh |
    .photon.numThreads = $photon_num_threads" \
    "$triconf" | sponge "$triconf"
}

function StartTrifacta() {
  LogInfo "Starting Trifacta"
  chmod 666 "$triconf"
  service trifacta restart || true
}

BackupFile "$triconf"

CreateCustomerKey

ConfigurePostgres
CreateDBRoles

ConfigureEdgeNode
ConfigureSecureTokenService
ConfigureUdfService
ConfigureAzureCommon
ConfigureAzureStorage
ConfigureDatabricks

StartTrifacta
