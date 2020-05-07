#!/bin/bash

set -o pipefail
set -o errexit
set -o errtrace
set -o nounset
# set -o xtrace

DB_TYPE=${DB_TYPE:-/tmp}
BACKUP_DIR=${BACKUP_DIR:-/tmp}
BOTO_CONFIG_PATH=${BOTO_CONFIG_PATH:-/root/.boto}
GCS_BUCKET=${GCS_BUCKET:-}
GCS_KEY_FILE_PATH=${GCS_KEY_FILE_PATH:-}
DB_HOST=${DB_HOST:-127.0.0.1}
DB_PORT=${DB_PORT:-27017}
DB_NAME=${DB_NAME:-}
DB_USER=${DB_USER:-}
DB_PASSWORD=${DB_PASSWORD:-}
DB_OPLOG=${DB_OPLOG:-}
RETENTION_COUNT=${RETENTION_COUNT:-}
SLACK_ALERTS=${SLACK_ALERTS:-}
SLACK_WEBHOOK_URL=${SLACK_WEBHOOK_URL:-}
SLACK_CHANNEL=${SLACK_CHANNEL:-}
SLACK_USERNAME=${SLACK_USERNAME:-}
SLACK_ICON=${SLACK_ICON:-}

backup() {
  echo "Prepare inputs for backup $DB_TYPE"

  mkdir -p $BACKUP_DIR
  date=$(date "+%Y-%m-%dT%H:%M:%SZ")
  archive_name="backup-$date.tar.gz"

  if [[ $DB_TYPE == "MONGODB" ]]
  then

    cmd_auth_part=""
    if [[ ! -z $DB_USER ]] && [[ ! -z $DB_PASSWORD ]]
    then
      cmd_auth_part="--username=\"$DB_USER\" --password=\"$DB_PASSWORD\" --authenticationDatabase=admin"
    fi

    cmd_db_part=""
    if [[ ! -z $DB_NAME ]]
    then
      cmd_db_part="--db=\"$DB_NAME\""
    fi

    cmd_oplog_part=""
    if [[ $DB_OPLOG = "true" ]]
    then
      cmd_oplog_part="--oplog"
    fi

    echo ""mongodump --host=\"$DB_HOST\" --port=\"$DB_PORT\" $cmd_auth_part $cmd_db_part $cmd_oplog_part --gzip --archive=$BACKUP_DIR/$archive_name""
    cmd="mongodump --host=\"$DB_HOST\" --port=\"$DB_PORT\" $cmd_auth_part $cmd_db_part $cmd_oplog_part --gzip --archive=$BACKUP_DIR/$archive_name"
  fi
  if [[ $DB_TYPE == "MYSQL" ]]
  then

    cmd_db_part="--all-databases"
    if [[ ! -z $DB_NAME ]]
    then
      cmd_db_part=$DB_NAME
    fi


    cmd_auth_part=""
    if [[ ! -z $DB_USER ]] && [[ ! -z $DB_PASSWORD ]]
    then
      cmd_auth_part="-u $DB_USER -p$DB_PASSWORD"
    fi

    echo "mysqldump -h $DB_HOST -P $DB_PORT -usessl=false $cmd_auth_part $cmd_db_part | gzip > $BACKUP_DIR/$archive_name"
    cmd="mysqldump -h $DB_HOST -P $DB_PORT -usessl=false $cmd_auth_part $cmd_db_part | gzip > $BACKUP_DIR/$archive_name"
  fi

  if [[ $DB_TYPE == "POSTGRESQL" ]]
  then

    cmd_db_part=""
    if [[ ! -z $DB_NAME ]]
    then
      cmd_db_part="--dbname=$DB_NAME"
    fi

    echo "pg_dump --host=$DB_HOST --port=$DB_PORT --username=$DB_USER $cmd_db_part | gzip > $BACKUP_DIR/$archive_name"
    cmd="pg_dump --host=$DB_HOST --port=$DB_PORT --username=$DB_USER $cmd_db_part | gzip > $BACKUP_DIR/$archive_name"
  fi

  echo "starting to backup $DB_TYPE host=$DB_HOST port=$DB_PORT"
  eval "$cmd" 2>&1
}

upload_to_gcs() {
  if [[ $GCS_KEY_FILE_PATH != "" ]]
  then
cat <<EOF > $BOTO_CONFIG_PATH
[Credentials]
gs_service_key_file = $GCS_KEY_FILE_PATH
[Boto]
https_validate_certificates = True
[GoogleCompute]
[GSUtil]
content_language = en
default_api_version = 2
[OAuth2]
EOF
  fi
  echo "uploading backup archive to GCS bucket=$GCS_BUCKET"
  gsutil cp $BACKUP_DIR/$archive_name $GCS_BUCKET 2>&1
}

send_slack_message() {
  local color=${1}
  local title=${2}
  local message=${3}

  echo 'Sending to '${SLACK_CHANNEL}'...'
  curl --silent --data-urlencode \
    "$(printf 'payload={"channel": "%s", "username": "%s", "link_names": "true", "icon_emoji": "%s", "attachments": [{"author_name": "mongodb-gcs-backup", "title": "%s", "text": "%s", "color": "%s"}]}' \
        "${SLACK_CHANNEL}" \
        "${SLACK_USERNAME}" \
        "${SLACK_ICON}" \
        "${title}" \
        "${message}" \
        "${color}" \
    )" \
    ${SLACK_WEBHOOK_URL} || true
  echo
}

err() {
  err_msg="Something went wrong on line $(caller)"
  echo $err_msg >&2
  if [[ $SLACK_ALERTS == "true" ]]
  then
    send_slack_message "danger" "Error while performing mongodb backup" "$err_msg"
  fi
}

cleanup() {
  echo "cleanup started"
  rm $BACKUP_DIR/$archive_name
  if [[ $RETENTION_COUNT != "" ]]
  then
    NUMBER="$(gsutil ls $GCS_BUCKET/ | wc -l)"
    RETENTION=$((RETENTION_COUNT+1))
    if [[ ${NUMBER} -gt ${RETENTION} ]]
    then
    gsutil ls -l $GCS_BUCKET/ | sort -r -k 2 | tail  +$RETENTION | awk '{print $3}' | gsutil rm -I
    fi
  fi
}

trap err ERR
backup
upload_to_gcs
cleanup
echo "backup done!"
