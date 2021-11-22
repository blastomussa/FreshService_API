# Author: Blastomussa
# Date: 11/15/21
# Requires preconfigured GAM installation
# This script imports Staff users from Google Workspace to FreshService as requesters. It then imports the
# users into a Staff requester group in FreshService. This allows for staff specific support articles
# within FreshService without manual curation of the requesters list or requester group membership.

# Declare Paths
$GAM = "C:\GAM\gam.exe"
$LOG = "C:\FreshService_API\log.txt"
$USERS = "C:\FreshService_API\users.csv"
$OLD = "C:\FreshService_API\users_old.csv"
$ROOT = "C:\FreshService_API"

# FreshService API Setup; Authentication Headers
$API_KEY = 'your_API_key' #NEEDS TO BE CHANGED IF ADMINS'S FRESHSERVICE ACCOUNT IS DISABLED
$EncodedCredentials = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(("{0}:{1}" -f $API_Key,$null)))
$HTTPHeaders = @{}
$HTTPHeaders.Add('Authorization', ("Basic {0}" -f $EncodedCredentials))
$HTTPHeaders.Add('Content-Type', 'application/json')

# Set TLS Version for Invoke-RestMethod; api request will raise error without this line!
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Declare Global Variables
[int]$count = 0
$currentDate = (Get-Date -UFormat "%D %r")

# Check if GAM is intalled on machine
if ((Test-Path -Path $GAM) -ne $true ) {
    echo "$currentDate - GAM installation or path configuration error" >> $LOG
    exit 1
}

# Check if GAM is configured correctly
$GAM_test = & $GAM info domain
if (($($GAM_test -like "*your_school.org*") -match "your_school") -eq $false) {
    echo "$currentDate - GAM not configured with school domain" >> $LOG
    exit 1
}

# Check for old user file and create a blank one if it doesn't exist
if ((Test-Path -Path $OLD) -ne $true ) {
    New-Item -Path $ROOT -Name "users_old.csv" -ItemType "file"
}

# Download users from Staff OU with GAM
echo 'primaryEmail,orgUnitPath,firstName,lastName' > $USERS
& $GAM print users primaryEmail orgUnitPath firstname lastname | Out-String -Stream | Select-String -SimpleMatch "Staff" >> $USERS

# Compare old user file and new user file. If the same exit and log success but no changes
if ($(Get-FileHash $USERS).Hash -eq $(Get-FileHash $OLD).Hash) {
    echo "$currentDate - No changes detected." >> $LOG
    exit 0
}

# Loop through current staff Google Accounts
Import-Csv $USERS | ForEach-Object {
    $username = $_.primaryEmail
    $OU = $_.orgUnitPath
    $fname = $_.firstName
    $lname = $_.lastName
    $is_new = $true #FLAG

    # compare each Username to those in old users csv
    Import-Csv "$OLD" | ForEach-Object {
        $old_username = $_.primaryEmail
        if ($username -eq $old_username){
            $is_new = $false #FLAG
        }
    }

    # if a user is new, filter for users in "/Staff" root org unit
    if ($is_new -eq $true) {
        if($OU -eq '/Staff' ){
            $count += 1

            # FRESHSERVICE API ACTION

            #Get request with filter for email address to get Requester_ID
            $URL = 'https://yourdomain.freshservice.com/api/v2/requesters?email=' + $username

            # make REST API request and save to object
            $obj = (Invoke-RestMethod -Method Get -Uri $URL -Headers $HTTPHeaders)

            #Check if requester has an account and create user if not
            if($obj.requesters.id -eq $null){
                #CREATE NEW REQUESTER JSON
                $User = @{}
                $User.Add('first_name', $fname)
                $User.Add('last_name', $lname)
                $User.Add('primary_email', $username)
                $JSON = $User | ConvertTo-Json

                #Create FreshService requester with POST request
                $URL = 'https://yourdomain.freshservice.com/api/v2/requesters'
                $obj = (Invoke-RestMethod -Method Post -Uri $URL -Headers $HTTPHeaders -Body $JSON)
            }

            # set requester ID
            $requester_ID = $obj.requesters.id

            # CREATE URL: /api/v2/requester_groups/[group_id]/members/[requester_id]
            $URL = 'https://yourdomain.freshservice.com/api/v2/requester_groups/your_groupID/members/' + $requester_ID

            # Move requester to group
            Invoke-RestMethod -Method Post -Uri $URL -Headers $HTTPHeaders
        }
    }
    Start-Sleep -Seconds 1  #slows calls to stay under api request rate; prevents API error
}

# copy users csv to replace old users csv
Copy-Item $USERS -Destination $OLD

# log changes
echo "$currentDate - FreshService sync successful: $count users imported" >> $LOG

exit 0
