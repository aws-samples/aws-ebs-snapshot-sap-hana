# SAP HANA AWS Snapshots
How to use AWS EBS Snapshots for SAP HANA database to create an automated
recovery procedure. More information see [SAP on AWS blog](https://aws.amazon.com/blogs/awsforsap/how-to-use-snapshots-for-sap-hana-database-to-create-an-automated-recovery-procedure/).

**Update 11/2023:** Customers can now use [Amazon Data Lifecycle Manager](https://aws.amazon.com/about-aws/whats-new/2023/11/automate-application-ebs-snapshots-sap-hana-databases/) to automate the creation and retention of application-consistent EBS Snapshots for SAP HANA databases.

# Backup

## Prerequisites
- SAP HANA version 2.0 SPS01 (min)
- SLES 12 SP3 (tested with a single DB tenant)
- HANA data volumes are using lvm
- jq package installed on HANA host
- AWS CLI installed on hana host (version: aws-cli/1.18.57)
- Parameter in AWS SSM parameter store for hana/data and hana/log volumes
- Password for SYSTEM set in hdbuserstore
- HANA tenant db 'restart=no'
- EC2 instance requires IAM role to execute snapshots, attach volumes etc.


### Setup
1. Optional: Install SAP HANA using AWS Quickstart, or setup the HANA instance manually.

2. Install jq package on the HANA host

3. Replace the /backup EBS file with an EFS file SYSTEM

4. Adopt HANA backup parameter basepath_logbackup, basepath_databackup and basepath_catalogbackup to the EFS file system

5. Create parameter is AWS System Manager Parameter Store

  HANA data volumes: List of EBS volume-ids used by /hana/data
````
aws ssm put-parameter --name HANADATAVOL --type StringList --value vol-1234,vol-5678,vol-9101112
````
HANA log volumes: List of EBS volume-ids used by /hana/log
  ````
aws ssm put-parameter --name HANALOGVOL --type StringList --value vol-131415,vol-161718,vol-192021
````

6. Create an entry in the HANA hdbuserstore (as sidadm) to connect to SYSTEMDB with user SYSTEM
````
hdbuserstore -i set SYSTEM <hostname>:3NN13@SYSTEMDB SYSTEM <Password>
````

7. Set the SAP HANA tenant db in no-restart mode.
This is important, to avoid an automatic start of the tenant db, after the snapshot is restored. If the tenant is online, it is no longer possible to recover log files
Logon to SAP HANA system DB and execute the following command:
````
ALTER DATABASE <Tenant-SID> NO RESTART;
````


### Recommendations
- Recommended frequency: 1 snapshot every 8-12 hours


## Execute snapshot script:

````
    ./aws-sap-hana-snapshot.sh

````


# Recovery

## Prerequisites

1. Verify mount options  
Make sure that the instance is started even if the /hana/data and /hana/log volume is not mounted. Set the option 'nofail' to the mount options in /etc/fstab

2. Create AMI of HANA server

3. Create Launch Configuration and past the recovery script into the "User data" under "Advanced Details" section

4. Create an Autoscaling Group with mix/max capacity = 1

# Additional documentation
[IAM example policies - Working with snapshots](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ExamplePolicies_EC2.html#iam-example-manage-snapshots)  
[Restricting access to Systems Manager parameters using IAM policies](https://docs.aws.amazon.com/systems-manager/latest/userguide/sysman-paramstore-access.html)  
[Attach or Detach Volumes to an EC2 Instance](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_examples_ec2_volumes-instance.html)

# License
This library is licensed under the MIT-0 License. See the LICENSE file.
