#!/bin/bash

# read config
source '/etc/duplicity_wrap/duplicity_wrap.cfg'

if [ "$?" -ne "0" ]; then
   echo "Can't read config. Exiting..."
   exit 1
fi

export PASSPHRASE
export FTP_PASSWORD

ARCHIVE_DIR='/var/duplicity/archive'
DUP_ARGUMENTS="--ssh-askpass --archive-dir $ARCHIVE_DIR --exclude-other-filesystems --exclude-globbing-filelist /etc/duplicity_wrap/exclude_files"
BACKUP_STATUS="BACKUP_OK"
HOSTNAME=`hostname -s`
LOGFILE='/var/log/duplicity.log'

# Read parameters

while getopts "m" optname
  do
    case "$optname" in
      "m")   # Mail results
        SEND_MAIL=true
        exec >$LOGFILE 2>&1
        ;;
    esac
  done
shift $(($OPTIND - 1))


if [ `id -u` != 0 ]; then
 echo "Script must be run as root";
 exit 1
fi

if [ ! -d $ARCHIVE_DIR ]; then
   mkdir  --parents $ARCHIVE_DIR
   echo "Created $ARCHIVE_DIR"
fi


# Take action depending on parameter

if [ "$1" = "status" ]; then
   duplicity $DUP_ARGUMENTS collection-status $TARGET_DIR
   exit

elif [ "$1" = "list" ]; then
   duplicity $DUP_ARGUMENTS list-current-files $TARGET_DIR
   exit

elif [ "$1" = "cleanup" ]; then

    duplicity $DUP_ARGUMENTS cleanup --force $TARGET_DIR
    exit

elif [ "$1" = "deleteold" ]; then

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

elif [ "$1" = "mysql_dump" ]; then
    filename="mysql_dump_"$(date +"%YY%mM%dD_%Hh%Mm")".sql"

    rm -f /backup/*

    mysqlcheck -A --user=$MYSQL_USER --password=$MYSQL_PASSWORD -s
    result=$?
    if [ $result -ne 0 ]; then
       echo "mysqlcheck error. Returncode: $result" 
       exit 1
    fi

    mysqldump --all-databases --user=$MYSQL_USER --password=$MYSQL_PASSWORD > /backup/$filename
    result=$?
    if [ $result -ne 0 ]; then
        echo "mysqldump error. Returncode: $result" 
        exit 1
    fi

elif [ "$1" = "full" ]; then
   $0 deleteold

   if [ "$?" -ne "0" ]; then
      BACKUP_STATUS="BACKUP_FAILED"
   fi

   $0 mysql_dump

   if [ "$?" -ne "0" ]; then
      BACKUP_STATUS="BACKUP_FAILED"
   fi

   duplicity $DUP_ARGUMENTS full / $TARGET_DIR
   if [ "$?" -ne "0" ]; then
      BACKUP_STATUS="BACKUP_FAILED"
   fi
   ./$0 status 2>&1 > $LOGFILE

   cat $LOGFILE | mail -s "Full $BACKUP_STATUS : $HOSTNAME" $MAIL_TO

elif [ "$1" = "incremental" ]; then

   $0 deleteold
   if [ "$?" -ne "0" ]; then
      BACKUP_STATUS="BACKUP_FAILED"
   fi

   $0 mysql_dump

   if [ "$?" -ne "0" ]; then
      BACKUP_STATUS="BACKUP_FAILED"
   fi

   duplicity -vINFO $DUP_ARGUMENTS incremental / $TARGET_DIR
   if [ "$?" -ne "0" ]; then
      BACKUP_STATUS="BACKUP_FAILED"
   fi
   $0 status

   if [ "$SEND_MAIL" ]; then
      cat $LOGFILE | mail -s "Incremental $BACKUP_STATUS : $HOSTNAME" $MAIL_TO
   fi

else
   echo "Valid duplicity_wrap.sh arguments: list, cleanup, deleteold, full, incremental, mysql_dump"
   echo "     -m   :  Send output via mail"
   exit 1;
fi

