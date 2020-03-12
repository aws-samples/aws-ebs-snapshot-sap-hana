#!/bin/bash
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
#

#====================================================================================
#Log output to AWS console log
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

#* SET variables*
HDBSID=HDB
SIDADM=hdbadm
HDBUSERSTORE=SYSTEM
#Parameter name for SSM of data and log volumes
SSMPARAMDATAVOL=imdbmaster-hdb-datavolumes
SSMPARAMLOGVOL=imdbmaster-hdb-logvolumes
#Path to HANA backup catalog
HDBCATALOG="/backup_efs/log/HDB/DB_HDB"

######################################################################################################
########################                                                      ########################
##################                                                                  ##################
##                                                                                                  ##
##                         Restore Amazon Elastic Block Store (EBS) Snapshots                       ##
##                                                                                                  ##
##################                                                                  ##################
########################                                                      ########################
######################################################################################################
#* SET more variables automatically
INSTANCEID=`curl -s http://169.254.169.254/latest/meta-data/instance-id`
AZ=`curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone`
REGION="`echo \"$AZ\" | sed 's/[a-z]$//'`"


#update IP in /etc/hosts
sed -i '/imdbmaster/d' /etc/hosts
curl http://169.254.169.254/latest/meta-data/local-ipv4 >> /etc/hosts
echo -n ' ' >> /etc/hosts
echo -n $(hostname) >> /etc/hosts
echo -n ' ' >> /etc/hosts
echo -n $(hostname -f) >> /etc/hosts
echo -e "\n" >> /etc/hosts

# restart AWS SSM agent
sudo systemctl stop amazon-ssm-agent
sudo systemctl start amazon-ssm-agent

# update route 53
INSTANCEIP=$( curl http://169.254.169.254/latest/meta-data/local-ipv4 )
HOSTED_ZONE_ID=$( aws route53 list-hosted-zones-by-name | grep -B 1 -e "local" | sed 's/.*hostedzone\/\([A-Za-z0-9]*\)\".*/\1/' | head -n 1 )
INPUT_JSON=$( cat /hana/update-route53.json | sed "s/127\.0\.0\.1/$INSTANCEIP/" )
INPUT_JSON="{ \"ChangeBatch\": $INPUT_JSON }"
aws route53 change-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" --cli-input-json "$INPUT_JSON"


## Restore
echo -e "$(date +"%Y-%m-%d"+"%T") - Starting restore procedure"

##Get the volume-id of /hana/data volumes relevant for snapshot from parameter list
OIFS=$IFS;
IFS=",";
DATAVOL=$(aws ssm get-parameters --names $SSMPARAMDATAVOL |awk 'NR ==7' | awk '{print $2}' |sed 's/\"//g')
DATAVOLID=($DATAVOL);
for ((i=0; i<${#DATAVOLID[@]}; ++i)); do     echo "DataVolume-ID-$i: ${DATAVOLID[$i]}"; done
IFS=$OIFS;
#Log Volumes
OIFS=$IFS;
IFS=",";
LOGVOL=$(aws ssm get-parameters --names $SSMPARAMLOGVOL |awk 'NR ==7' | awk '{print $2}' |sed 's/\"//g')
LOGVOLID=($LOGVOL);
for ((i=0; i<${#LOGVOLID[@]}; ++i)); do     echo "LogVolume-ID-$i: ${LOGVOLID[$i]}"; done
IFS=$OIFS;


##Get the date of the latest complete snapshot for each volume
for ((i=0; i<${#DATAVOLID[@]}; ++i));
do
  LATESTSNAPDATEDATA[$i]=$(aws ec2 describe-snapshots --filters Name=volume-id,Values=${DATAVOLID[$i]} Name=status,Values=completed Name=tag:Createdby,Values=AWS-HANA-Snapshot_of_${HOSTNAME} | jq -r ".Snapshots[] | .StartTime" | sort -r | awk 'NR ==1')
  echo -e "Latest date of snapshot for ${DATAVOLID[$i]} : ${LATESTSNAPDATEDATA[$i]}"
done
# Log volume
for ((i=0; i<${#LOGVOLID[@]}; ++i));
do
  LATESTSNAPDATELOG[$i]=$(aws ec2 describe-snapshots --filters Name=volume-id,Values=${LOGVOLID[$i]} Name=status,Values=completed Name=tag:Createdby,Values=AWS-HANA-Snapshot_of_${HOSTNAME} | jq -r ".Snapshots[] | .StartTime" | sort -r | awk 'NR ==1')
  echo -e "Latest date of snapshot for ${LOGVOLID[$i]} : ${LATESTSNAPDATELOG[$i]}"
done


##Get the snapshot-id from the latest snapshot
for ((i=0; i<${#LATESTSNAPDATEDATA[@]}; ++i));
do
  SNAPIDDATA[$i]=$(aws ec2 describe-snapshots --filters Name=start-time,Values=${LATESTSNAPDATEDATA[$i]} Name=volume-id,Values=${DATAVOLID[$i]} | jq -r ".Snapshots[] | .SnapshotId")
  echo -e "Snapshot ID: ${SNAPIDDATA[$i]}"
done
# Log volume
for ((i=0; i<${#LATESTSNAPDATELOG[@]}; ++i));
do
  SNAPIDLOG[$i]=$(aws ec2 describe-snapshots --filters Name=start-time,Values=${LATESTSNAPDATELOG[$i]} Name=volume-id,Values=${LOGVOLID[$i]} | jq -r ".Snapshots[] | .SnapshotId")
  echo -e "Snapshot ID: ${SNAPIDLOG[$i]}"
done


##Create new data volumes out of snapshot
declare -a DATADEVICEINFO
declare -a LOGDEVICEINFO
for ((i=0; i<${#SNAPIDDATA[@]}; i++));
do
  NEWVOLDATA[$i]=$(aws ec2 create-volume --region $REGION --availability-zone $AZ --snapshot-id ${SNAPIDDATA[$i]} --volume-type gp2 --output=text --query VolumeId)
  echo -e "Volume-id of created volume: ${NEWVOLDATA[$i]}"
  #device info
  DATADEVICEINFO+=($(aws ec2 describe-snapshots --snapshot-id ${SNAPIDDATA[$i]} | jq -r ".Snapshots[] | .Tags" | grep -B1 device_name |awk 'NR ==1' | awk '{print $2}' |sed 's/\"//g' |sed 's/\,//g'))
done
# Log volume
for ((i=0; i<${#SNAPIDLOG[@]}; i++));
do
  NEWVOLLOG[$i]=$(aws ec2 create-volume --region $REGION --availability-zone $AZ --snapshot-id ${SNAPIDLOG[$i]} --volume-type gp2 --output=text --query VolumeId)
  echo -e "Volume-id of created volume: ${NEWVOLLOG[$i]}"
  #device info
  LOGDEVICEINFO+=($(aws ec2 describe-snapshots --snapshot-id ${SNAPIDLOG[$i]} | jq -r ".Snapshots[] | .Tags" | grep -B1 device_name |awk 'NR ==1' | awk '{print $2}' |sed 's/\"//g' |sed 's/\,//g'))
done



##Check availability of the volume 
for ((i=0; i<${#NEWVOLDATA[@]}; i++));
do
  NEWVOLSTATE="unknown"
  until [ $NEWVOLSTATE == "available" ]; do
    NEWVOLSTATE=$(aws ec2 describe-volumes --region $REGION --volume-ids ${NEWVOLDATA[$i]} --query Volumes[].State --output text)
    echo "Status vol ${NEWVOLDATA[$i]}: $NEWVOLSTATE"
    sleep 5
  done
done
# Log volume
for ((i=0; i<${#NEWVOLLOG[@]}; i++));
do
  NEWVOLSTATE="unknown"
  until [ $NEWVOLSTATE == "available" ]; do
    NEWVOLSTATE=$(aws ec2 describe-volumes --region $REGION --volume-ids ${NEWVOLLOG[$i]} --query Volumes[].State --output text)
    echo "Status vol ${NEWVOLLOG[$i]}: $NEWVOLSTATE"
    sleep 5
  done
done


##Attach volumes to the instance
#Data volumes
for ((i=0; i<${#NEWVOLDATA[@]}; i++));
do
  aws ec2 attach-volume --volume-id ${NEWVOLDATA[$i]} --instance-id $INSTANCEID --device ${DATADEVICEINFO[$i]}
done
#Log volumes
for ((i=0; i<${#NEWVOLLOG[@]}; i++));
do
  aws ec2 attach-volume --volume-id ${NEWVOLLOG[$i]} --instance-id $INSTANCEID --device ${LOGDEVICEINFO[$i]}
done

##Mount volumes
sleep 20
mount -a
df -h

## Update SSM Parameter with new volume-ids
echo "Update SSM parameters with new volume-ids"
for ((i=0; i<${#NEWVOLDATA[@]}; i++));
do
  voldatassmupdate=$voldatassmupdate${NEWVOLDATA[$i]},
done
voldatassmupdate=${voldatassmupdate%,}
#Log volumes
for ((i=0; i<${#NEWVOLLOG[@]}; i++));
do
  vollogssmupdate=$vollogssmupdate${NEWVOLLOG[$i]},
done
vollogssmupdate=${vollogssmupdate%,}

aws ssm put-parameter --name $SSMPARAMDATAVOL --type StringList --value ${voldatassmupdate} --overwrite
aws ssm put-parameter --name $SSMPARAMLOGVOL --type StringList --value ${vollogssmupdate} --overwrite

## Start HANA system DB
echo "Start HANA System DB"
sudo -u $SIDADM -i $HDBSID start
sleep 45


## Recover logfiles to the most recent state
echo "Start database recovery"
sudo -u $SIDADM -i hdbsql -U $HDBUSERSTORE "RECOVER DATABASE FOR $HDBSID UNTIL TIMESTAMP '2099-01-01 12:00:00' CLEAR LOG USING CATALOG PATH ('$HDBCATALOG') USING SNAPSHOT;"

## Trigger Backup 
echo "Start Backup"
/hana/aws-sap-hana-snapshot.sh

exit 0