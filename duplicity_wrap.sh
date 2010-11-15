#!/bin/bash

if [[ $EUID -ne 0 ]]; then
   echo "Script must be run as root" 1>&2
   exit 1
fi

CFG_DIR='/etc/duplicity_wrap'

# read config
source "${CFG_DIR}/duplicity_wrap.cfg"

if [ "$?" -ne "0" ]; then
   echo "Can't read config. Exiting..." 1>&2
   exit 1
fi

export PASSPHRASE

ARCHIVE_DIR='/var/duplicity/archive'
DUP_ARGUMENTS="--archive-dir $ARCHIVE_DIR --exclude-other-filesystems --exclude-globbing-filelist ${CFG_DIR}/exclude_files"
if [ ! -z $FTP_PASSWORD ]; then
   export FTP_PASSWORD
   DUP_ARGUMENTS="${DUP_ARGUMENTS} --ssh-askpass"
fi
BACKUP_STATUS="BACKUP_OK"
HOSTNAME=`hostname -s`
LOGFILE='/var/log/duplicity.log'
if [ ! -z $BACKUP_FOLDER ]; then
   FULL_BACKUP_FOLDER="${SERVER}/${BACKUP_FOLDER}"
else
   FULL_BACKUP_FOLDER=$SERVER
fi
TARGET_DIR="$PROTOCOL://$FTP_USERNAME@${FULL_BACKUP_FOLDER}"
if [ ! -z $MYSQL_USER ] && [ ! -z $MYSQL_PASSWORD ]; then
   MYSQL_ARGUMENTS="--user=${MYSQL_USER} --password=${MYSQL_PASSWORD}"
fi
if [ ! -z $SSH_IDENTITY_FILE ]; then
   SSH_ARGUMENTS="-oIdentityFile=${SSH_IDENTITY_FILE}"
   DUP_ARGUMENTS="${DUP_ARGUMENTS} --ssh-options=\"${SSH_ARGUMENTS}\""
fi
if [ ! -z $ENCRYPT_KEY ]; then
   DUP_ARGUMENTS="${DUP_ARGUMENTS} --encrypt-key ${ENCRYPT_KEY}"
fi

# Read parameters

while getopts "m" optname; do
   case "$optname" in
      "m")   # Mail results
         SEND_MAIL=true
         exec >$LOGFILE 2>&1
         ;;
   esac
done
shift $(($OPTIND - 1))

if [ ! -d $ARCHIVE_DIR ]; then
   mkdir  --parents $ARCHIVE_DIR
   echo "Created $ARCHIVE_DIR"
fi

function space {
   echo "Space used:"
   COMMAND='du -ch'
   if [ "$PROTOCOL" = "scp" ] && [ -z $FTP_PASSWORD ]; then
      ssh $SSH_ARGUMENTS $FTP_USERNAME@$SERVER $COMMAND $BACKUP_FOLDER
   else
      if [ "$PROTOCOL" = "scp" ]; then
         echo $COMMAND | lftp -u "$FTP_USERNAME,$FTP_PASSWORD" "sftp://${FULL_BACKUP_FOLDER}"
      else 
         echo $COMMAND | lftp -u "$FTP_USERNAME,$FTP_PASSWORD" "ftp://${FULL_BACKUP_FOLDER}"
      fi
   fi
}

function collection_status {
   duplicity $DUP_ARGUMENTS collection-status $TARGET_DIR
}

function deleteold {
   duplicity $DUP_ARGUMENTS --force remove-all-but-n-full $KEEP_LAST_FULL $TARGET_DIR
   if [ "$?" -ne "0" ]; then
      echo "Failed cleaning old files from backup space!"
      exit 1
   fi

   duplicity $DUP_ARGUMENTS --force remove-all-inc-of-but-n-full $KEEP_INCREMENTAL $TARGET_DIR
   if [ "$?" -ne "0" ]; then
      echo "Failed cleaning old files from backup space!"
      exit 1
   fi
}

function list {
   duplicity $DUP_ARGUMENTS list-current-files $TARGET_DIR
}

function cleanup {
   duplicity $DUP_ARGUMENTS cleanup --force $TARGET_DIR
}

function mysql_dump {
   if [ -z $MYSQL_EXTERNAL_BACKUP ]; then
      filename="mysql_dump_"$(date +"%YY%mM%dD_%Hh%Mm")".sql"

      rm -f /backup/*

      mysqlcheck -A $MYSQL_ARGUMENTS -s
      result=$?
      if [ $result -ne 0 ]; then
         echo "mysqlcheck error. Returncode: $result" 
         exit 1
      fi

      mysqldump --all-databases $MYSQL_ARGUMENTS > /backup/$filename
      result=$?
      if [ $result -ne 0 ]; then
         echo "mysqldump error. Returncode: $result" 
         exit 1
      fi
   else
      if [ ! -z $MYSQL_BACKUP_USER ]; then
         MYSQL_EXTERNAL_BACKUP="sudo -u ${MYSQL_BACKUP_USER} ${MYSQL_EXTERNAL_BACKUP}"
      fi
      $MYSQL_EXTERNAL_BACKUP
   fi
}

# Take action depending on parameter
case "$1" in
   space)
      space
      ;;
   status)
      collection_status
      ;;
   list)
      list
      ;;
   cleanup)
      cleanup
      ;;
   deleteold)
      deleteold
      ;;
   mysql_dump)
      mysql_dump
      ;;
   full)
      deleteold
      if [ "$?" -ne "0" ]; then
         BACKUP_STATUS="BACKUP_FAILED"
      fi

      mysql_dump
      if [ "$?" -ne "0" ]; then
         BACKUP_STATUS="BACKUP_FAILED"
      fi

      duplicity $DUP_ARGUMENTS full / $TARGET_DIR
      if [ "$?" -ne "0" ]; then
         BACKUP_STATUS="BACKUP_FAILED"
      fi

      collection_status
      space

      cat $LOGFILE | mail -s "Full $BACKUP_STATUS : $HOSTNAME" $MAIL_TO
      ;;
   incremental)
      deleteold
      if [ "$?" -ne "0" ]; then
         BACKUP_STATUS="BACKUP_FAILED"
      fi

      mysql_dump
      if [ "$?" -ne "0" ]; then
         BACKUP_STATUS="BACKUP_FAILED"
      fi

      duplicity -vINFO $DUP_ARGUMENTS incremental / $TARGET_DIR
      if [ "$?" -ne "0" ]; then
         BACKUP_STATUS="BACKUP_FAILED"
      fi

      collection_status
      space

      if [ "$SEND_MAIL" ]; then
         cat $LOGFILE | mail -s "Incremental $BACKUP_STATUS : $HOSTNAME" $MAIL_TO
      fi
      ;;
   *)
      echo "Valid duplicity_wrap.sh arguments:" 1>&2
      echo "list, cleanup, deleteold, full, incremental, mysql_dump" 1>&2
      echo "     -m   :  Send output via mail" 1>&2
      exit 1
      ;;
esac
