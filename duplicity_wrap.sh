#!/bin/bash

function prepare_backup() {

   $0 deleteold
   if [ "$?" -ne "0" ]; then
      BACKUP_STATUS="BACKUP_FAILED: Cleanup"
   fi

   $0 mysql_dump

   if [ "$?" -ne "0" ]; then
      BACKUP_STATUS="BACKUP_FAILED: Mysql"
   fi

   $0 svn_dump

   if [ "$?" -ne "0" ]; then
      BACKUP_STATUS="BACKUP_FAILED: Subversion"
   fi

}

function postprocess_backup() {
   $0 status
   $0 space

   if [ "$SEND_MAIL" ]; then
      cat $LOGFILE | mail -s "$BACKUP_STATUS : $HOSTNAME" $MAIL_TO
   fi

}

umask 177

# read config
source '/etc/duplicity_wrap/duplicity_wrap.cfg'

if [ "$?" -ne "0" ]; then
   echo "Can't read config. Exiting..."
   exit 1
fi

export PASSPHRASE
export FTP_PASSWORD

ARCHIVE_DIR='/var/duplicity/archive'
DUP_ARGUMENTS="--ssh-askpass --archive-dir $ARCHIVE_DIR --exclude-globbing-filelist /etc/duplicity_wrap/exclude_files"
BACKUP_STATUS="BACKUP_OK"
HOSTNAME=`hostname -s`
LOGFILE='/var/log/duplicity.log'
TARGET_DIR="$PROTOCOL://$FTP_USERNAME:@$SERVER"

if [ "$REMOTE_DIRECTORY" ]; then 
  TARGET_DIR="$TARGET_DIR/$REMOTE_DIRECTORY"
fi

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

if [ "$1" = "space" ]; then
   echo "Space used:"
   if [ "$PROTOCOL" = "scp" ]; then
      echo "du -h" | lftp -u "$FTP_USERNAME,$FTP_PASSWORD" "sftp://$SERVER"
   else 
      echo "du -h" | lftp -u "$FTP_USERNAME,$FTP_PASSWORD" "ftp://$SERVER"
   fi
   exit

elif [ "$1" = "status" ]; then
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

elif [ "$1" = "svn_dump"  ]; then

    if [ "$SUBVERSION_DIRECTORY" ]; then
       rm -rf /backup/svn_dump*

       filename="svn_dump_"$(date +"%YY%mM%dD_%Hh%Mm")
       mkdir "/backup/$filename"

       cd "$SUBVERSION_DIRECTORY"
       for f in *; do
          if [ -d "$f" ]; then
              svnadmin hotcopy "$f" "/backup/$filename/$f"
              if [ "$?" -ne "0" ]; then
                echo "svn dump error.: $f"
	        exit 1
              fi
          fi
       done
   
    fi
    exit 0


elif [ "$1" = "mysql_dump" ]; then
    filename="mysql_dump_"$(date +"%YY%mM%dD_%Hh%Mm")".sql"

    rm -f /backup/mysql_dump*

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
   prepare_backup

   duplicity  $DUP_ARGUMENTS full / $TARGET_DIR
   if [ "$?" -ne "0" ]; then
      BACKUP_STATUS="BACKUP_FAILED"
   fi

   postprocess_backup 


elif [ "$1" = "incremental" ]; then

   prepare_backup

   duplicity -vINFO $DUP_ARGUMENTS incremental / $TARGET_DIR
   if [ "$?" -ne "0" ]; then
      BACKUP_STATUS="BACKUP_FAILED"
   fi

   postprocess_backup 

else
   echo "Valid duplicity_wrap.sh arguments: space,list, cleanup, deleteold, full, incremental, mysql_dump, svn_dump"
   echo "     -m   :  Send output via mail"
   exit 1;
fi

