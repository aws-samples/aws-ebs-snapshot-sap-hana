#!/bin/bash
set -ue
#set -x

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
#
# Permission is hereby granted, free of charge, to any person obtaining a copy of this
# software and associated documentation files (the "Software"), to deal in the Software
# without restriction, including without limitation the rights to use, copy, modify,
# merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
# INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
# PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
# HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
# SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

#====================================================================================
#* SET variables*
#Parameter name for SSM of data and log volumes
SSMPARAMDATAVOL=imdbmaster-hdb-datavolumes
SSMPARAMLOGVOL=imdbmaster-hdb-logvolumes
#Key-Name of hdbuserstore
HDBUSERSTORE=SYSTEM

#* SET more variables automatically
instanceid=`curl -s http://169.254.169.254/latest/meta-data/instance-id`
az=`curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone`
region="`echo \"$az\" | sed 's/[a-z]$//'`"
sidadm=$(ps -C sapstart -o user |awk 'NR ==2' | awk '{print $1}')

#Log output to AWS console log
logfile="/var/log/user-data.log"


# Get status of first Tenant DB. status online=yes
status=$(sudo -u $sidadm -i hdbsql -U $HDBUSERSTORE "SELECT ACTIVE_STATUS from M_DATABASES;" | awk 'FNR==3' |sed 's/\"//g')


#********************** Function Declarations ************************************************************************

# Function: Log an event.
log() {
    echo "[$(date +"%Y-%m-%d"+"%T")]: $*"
}


# Function: Prerequisite check - check if HANA DB and tenant is online.
prerequisite_check() {
if [ $status == "YES" ]; then
		log "INFO: HANA and tenant DB is online and ready for backup"
		return 0
	else
		log "ERROR: HANA or tenant is offline - Snapshot procedure failed" 
		return 1
fi
}


# Function: Create snapshot.
snapshot_instance() {
    snapshot_description="$(hostname)-$instanceid-HANA-Snapshot-$(date +%Y-%m-%d-%H:%M:%S)"

    recent_snapshot_list_new=($(aws ec2 create-snapshots --region $region --instance-specification InstanceId=$instanceid,ExcludeBootVolume=true --description $snapshot_description --tag-specifications "ResourceType=snapshot,Tags=[{Key=Createdby,Value=AWS-HANA-Snapshot_of_${HOSTNAME}}]" | jq -r ".Snapshots[] | .SnapshotId"))   
    for ((i=0; i<${#recent_snapshot_list_new[@]}; ++i)); do     log "INFO: EBS Snapshot ID-$i: ${recent_snapshot_list_new[$i]}"; done
}

# Function: Add device name to snapshot tags.
tag_mountinfo() {
    OIFS=$IFS;
    IFS=",";
    volume_list_data=$(aws ssm get-parameters --names $SSMPARAMDATAVOL --output text | awk '{print $6}')
    volume_list_log=$(aws ssm get-parameters --names $SSMPARAMLOGVOL --output text | awk '{print $6}')
    volume_list="$volume_list_data$volume_list_log"
    declare -a volume_id_sorted
    declare -a device_name_sorted
    volume_id=($volume_list);
    for ((i=0; i<${#recent_snapshot_list_new[@]}; ++i)); 
    do
        #get device name of volume
        volume_id_sorted+=($(aws ec2 describe-snapshots --region $region --snapshot-ids ${recent_snapshot_list_new[$i]} | jq -r ".Snapshots[] | .VolumeId"))
        device_name_sorted+=($(aws ec2 describe-volumes --region $region --output=text --volume-ids ${volume_id_sorted[$i]} --query 'Volumes[0].{Devices:Attachments[0].Device}'))

        #add tag to snapshot
        aws ec2 create-tags --region $region --resource ${recent_snapshot_list_new[$i]} --tags Key=device_name,Value=${device_name_sorted[$i]}

    done

    IFS=$OIFS;
}

# Function: Create Snapshot in HANA backup catalog.
hana_create_snap() {
sudo -u $sidadm -i hdbsql -U $HDBUSERSTORE "BACKUP DATA FOR FULL SYSTEM CREATE SNAPSHOT COMMENT 'Snapshot created by AWS Instance Snapshot';"
#get snapshot ID
SnapshotID=$(sudo -u $sidadm -i hdbsql -U $HDBUSERSTORE "SELECT Backup_ID FROM M_BACKUP_CATALOG WHERE ENTRY_TYPE_NAME = 'data snapshot' ORDER BY SYS_START_TIME DESC LIMIT 1;" | awk 'FNR==2')

log "INFO: HANA prepared for Snapshot -- HANA Snapshot-ID: " $SnapshotID
}

# Function: Confirm Snapshot in HANA backup catalog.
hana_confirm_snap() {
sudo -u $sidadm -i hdbsql -U $HDBUSERSTORE "BACKUP DATA FOR FULL SYSTEM CLOSE SNAPSHOT BACKUP_ID $SnapshotID SUCCESSFUL 'AWS-Snapshot';"
log "INFO: Confirmation of Snapshot in HANA BACKUP_CATALOG"
}

# Function: delete invalid EBS snapshots
delete_invalid_snap() {
    SNAP_VALIDATION=$(sudo -u $sidadm -i hdbsql -U $HDBUSERSTORE "select STATE_NAME from m_backup_catalog where ENTRY_TYPE_NAME = 'data snapshot' order by SYS_START_TIME desc limit 1" | awk 'FNR==2' |sed 's/\"//g')
    if [ $SNAP_VALIDATION == "successful" ]; then
		log "INFO: Snapshot successful, keep AWS snapshot"
	else
        for ((i=0; i<${#recent_snapshot_list_new[@]}; ++i));  do
		aws ec2 delete-snapshot --region $region --snapshot_id ${recent_snapshot_list_new[$i]}
		log "ERROR: Backup was not marked as successful in HANA backup catalog - delete EBS snapshot: $recent_snapshot_id"
        done
    fi
}


#**********************************************************************************************************************************
### Call functions in required order
log "INFO: Start AWS snapshot backup"

#log_setup
log "INFO: Check log file $logfile for more information"

# 1) Check prerequisites
prerequisite_check
if [ $? -ne 0 ]
then
   log "ERROR: Database or Tenant DB is not online, no connection possible"
   log "Exit..."
   exit 1
fi

# 2) Execute Snap on HANA DB for Backup Katalog
hana_create_snap
if [ $? -ne 0 ]
then
   log "ERROR: Entry into HANA backup catalog was not successful"
   exit 1
fi

# 3) Execute EBS Snapshot
snapshot_instance
if [ $? -ne 0 ]
then
   log "ERROR: EBS Snapshot was not successful"
   delete_invalid_snap
   exit 1
fi

# 4) Confirm Snap for Backaup Katalog
hana_confirm_snap
if [ $? -ne 0 ]
then
   log "ERROR: Snapshot could not be confirmend into HANA backup catalog"
   exit 1
fi

# 5) Tag snapshot with device name
tag_mountinfo
if [ $? -ne 0 ]
then
   log "ERROR: Could not create tags for EBS snapshots"
   exit 1
fi

# 6) Validate snap
delete_invalid_snap
if [ $? -ne 0 ]
then
   log "ERROR: EBS snapshots could not be deleted - please remove invalid snapshots manually"
   exit 1
fi

log "INFO: End of AWS snapshot backup"

exit 0
#################################################################End of script ########################################