$InformationPreference = "Continue"

$IsCloudLabs = Test-Path C:\LabFiles\AzureCreds.ps1;

$Load30Billion = 0

if ($Env:POWERSHELL_DISTRIBUTION_CHANNEL -ne "CloudShell")
{
        $title = "Data Size"
        $yes = New-Object System.Management.Automation.Host.ChoiceDescription "30 &Billion", "Loads 30 billion records into the Sales table. Scales SQL Pool to DW3000c during data loading. Approxiamate loading time is 4 hours."
        $no = New-Object System.Management.Automation.Host.ChoiceDescription "3 &Million", "Loads 3 million records into the Sales table."
        $options = [System.Management.Automation.Host.ChoiceDescription[]]($yes, $no)
        $result = $host.ui.PromptForChoice($title, "Choose how much data you want to load.", $options, 1)
        
        switch($result)
        {
        0 { $Load30Billion = 1 }
        1 { $Load30Billion = 0 }
        }
}

if($IsCloudLabs){
        if(Get-Module -Name solliance-synapse-automation){
                Remove-Module solliance-synapse-automation
        }
        Import-Module "..\solliance-synapse-automation"

        . C:\LabFiles\AzureCreds.ps1

        $userName = $AzureUserName                # READ FROM FILE
        $password = $AzurePassword                # READ FROM FILE
        $clientId = $TokenGeneratorClientId       # READ FROM FILE
        #$global:sqlPassword = $AzureSQLPassword          # READ FROM FILE

        $securePassword = $password | ConvertTo-SecureString -AsPlainText -Force
        $cred = new-object -typename System.Management.Automation.PSCredential -argumentlist $userName, $SecurePassword
        
        Connect-AzAccount -Credential $cred | Out-Null

        $resourceGroupName = (Get-AzResourceGroup | Where-Object { $_.ResourceGroupName -like "*-L400*" }).ResourceGroupName

        if ($resourceGroupName.Count -gt 1)
        {
                $resourceGroupName = $resourceGroupName[0];
        }

        $ropcBodyCore = "client_id=$($clientId)&username=$($userName)&password=$($password)&grant_type=password"
        $global:ropcBodySynapse = "$($ropcBodyCore)&scope=https://dev.azuresynapse.net/.default"
        $global:ropcBodyManagement = "$($ropcBodyCore)&scope=https://management.azure.com/.default"
        $global:ropcBodySynapseSQL = "$($ropcBodyCore)&scope=https://sql.azuresynapse.net/.default"
        $global:ropcBodyPowerBI = "$($ropcBodyCore)&scope=https://analysis.windows.net/powerbi/api/.default"

        $artifactsPath = "..\..\"
        $reportsPath = "..\reports"
        $notebooksPath = "..\notebooks"
        $templatesPath = "..\templates"
        $datasetsPath = "..\datasets"
        $dataflowsPath = "..\dataflows"
        $pipelinesPath = "..\pipelines"
        $sqlScriptsPath = "..\sql"
        $functionsSourcePath = "..\functions"
} else {
        if(Get-Module -Name solliance-synapse-automation){
                Remove-Module solliance-synapse-automation
        }
        Import-Module "..\solliance-synapse-automation"

        Connect-AzAccount

        az login

        #Different approach to run automation in Cloud Shell
        $subs = Get-AzSubscription | Select-Object -ExpandProperty Name
        if($subs.GetType().IsArray -and $subs.length -gt 1){
                $subOptions = [System.Collections.ArrayList]::new()
                for($subIdx=0; $subIdx -lt $subs.length; $subIdx++){
                        $opt = New-Object System.Management.Automation.Host.ChoiceDescription "$($subs[$subIdx])", "Selects the $($subs[$subIdx]) subscription."   
                        $subOptions.Add($opt)
                }
                $selectedSubIdx = $host.ui.PromptForChoice('Enter the desired Azure Subscription for this lab','Copy and paste the name of the subscription to make your choice.', $subOptions.ToArray(),0)
                $selectedSubName = $subs[$selectedSubIdx]
                Write-Information "Selecting the $selectedSubName subscription"
                Select-AzSubscription -SubscriptionName $selectedSubName
        }

        $resourceGroupName = Read-Host "Enter the resource group name";
        
        $userName = ((az ad signed-in-user show) | ConvertFrom-JSON).UserPrincipalName
        
        #$global:sqlPassword = Read-Host -Prompt "Enter the SQL Administrator password you used in the deployment" -AsSecureString
        #$global:sqlPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringUni([System.Runtime.InteropServices.Marshal]::SecureStringToCoTaskMemUnicode($sqlPassword))

        $artifactsPath = "..\..\"
        $noteBooksPath = "..\notebooks"
        $reportsPath = "..\reports"
        $templatesPath = "..\templates"
        $datasetsPath = "..\datasets"
        $dataflowsPath = "..\dataflows"
        $pipelinesPath = "..\pipelines"
        $sqlScriptsPath = "..\sql"
        $functionsSourcePath = "..\functions"
}

Write-Information "Using $resourceGroupName";

$uniqueId =  (Get-AzResourceGroup -Name $resourceGroupName).Tags["DeploymentId"]
$subscriptionId = (Get-AzContext).Subscription.Id
$tenantId = (Get-AzContext).Tenant.Id
$global:logindomain = (Get-AzContext).Tenant.Id;

$workspaceName = "asaworkspace$($uniqueId)"
$cosmosDbAccountName = "asacosmosdb$($uniqueId)"
$cosmosDbDatabase = "CustomerProfile"
$cosmosDbContainer = "OnlineUserProfile01"
$dataLakeAccountName = "asadatalake$($uniqueId)"
$blobStorageAccountName = "asastore$($uniqueId)"
$keyVaultName = "asakeyvault$($uniqueId)"
$keyVaultSQLUserSecretName = "SQL-USER-ASA"
$sqlPoolName = "SQLPool01"
$integrationRuntimeName = "AzureIntegrationRuntime01"
$sparkPoolName = "SparkPool01"
$amlWorkspaceName = "amlworkspace$($uniqueId)"
$global:sqlEndpoint = "$($workspaceName).sql.azuresynapse.net"
$global:sqlUser = "asa.sql.admin"
$twitterFunction="twifunction$($uniqueId)"
$locationFunction="locfunction$($uniqueId)"
$asaName="asa$($uniqueId)"

Write-Information "Deploying Azure functions"

az functionapp deployment source config-zip `
        --resource-group $resourceGroupName `
        --name $twitterFunction `
        --src "../functions/Twitter_Function_Publish_Package.zip"
		
az functionapp deployment source config-zip `
        --resource-group $resourceGroupName `
        --name $locationFunction `
        --src "../functions/LocationAnalytics_Publish_Package.zip"

$global:synapseToken = ""
$global:synapseSQLToken = ""
$global:managementToken = ""
$global:powerbiToken = "";

$global:tokenTimes = [ordered]@{
        Synapse = (Get-Date -Year 1)
        SynapseSQL = (Get-Date -Year 1)
        Management = (Get-Date -Year 1)
        PowerBI = (Get-Date -Year 1)
}

Write-Information "Assign Ownership to L400 Proctors on Synapse Workspace"
Assign-SynapseRole -WorkspaceName $workspaceName -RoleId "6e4bf58a-b8e1-4cc3-bbf9-d73143322b78" -PrincipalId "37548b2e-e5ab-4d2b-b0da-4d812f56c30e"  # Workspace Admin
Assign-SynapseRole -WorkspaceName $workspaceName -RoleId "7af0c69a-a548-47d6-aea3-d00e69bd83aa" -PrincipalId "37548b2e-e5ab-4d2b-b0da-4d812f56c30e"  # SQL Admin
Assign-SynapseRole -WorkspaceName $workspaceName -RoleId "c3a6d2f1-a26f-4810-9b0f-591308d5cbf1" -PrincipalId "37548b2e-e5ab-4d2b-b0da-4d812f56c30e"  # Apache Spark Admin

#add the current user...
$user = Get-AzADUser -UserPrincipalName $userName
Assign-SynapseRole -WorkspaceName $workspaceName -RoleId "6e4bf58a-b8e1-4cc3-bbf9-d73143322b78" -PrincipalId $user.id  # Workspace Admin
Assign-SynapseRole -WorkspaceName $workspaceName -RoleId "7af0c69a-a548-47d6-aea3-d00e69bd83aa" -PrincipalId $user.id  # SQL Admin
Assign-SynapseRole -WorkspaceName $workspaceName -RoleId "c3a6d2f1-a26f-4810-9b0f-591308d5cbf1" -PrincipalId $user.id  # Apache Spark Admin

#Set the Azure AD Admin - otherwise it will bail later
Set-SqlAdministrator $username $user.id;

#add the permission to the datalake to workspace
$id = (Get-AzADServicePrincipal -DisplayName $workspacename).id
New-AzRoleAssignment -Objectid $id -RoleDefinitionName "Storage Blob Data Owner" -Scope "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Storage/storageAccounts/$dataLakeAccountName" -ErrorAction SilentlyContinue;
New-AzRoleAssignment -SignInName $username -RoleDefinitionName "Storage Blob Data Owner" -Scope "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Storage/storageAccounts/$dataLakeAccountName" -ErrorAction SilentlyContinue;

Write-Information "Setting Key Vault Access Policy"
Set-AzKeyVaultAccessPolicy -ResourceGroupName $resourceGroupName -VaultName $keyVaultName -UserPrincipalName $userName -PermissionsToSecrets set,delete,get,list
Set-AzKeyVaultAccessPolicy -ResourceGroupName $resourceGroupName -VaultName $keyVaultName -ObjectId $id -PermissionsToSecrets set,delete,get,list

#remove need to ask for the password in script.
$global:sqlPassword = $(Get-AzKeyVaultSecret -VaultName $keyVaultName -Name "SqlPassword").SecretValueText

Write-Information "Create SQL-USER-ASA Key Vault Secret"
$secretValue = ConvertTo-SecureString $sqlPassword -AsPlainText -Force
Set-AzKeyVaultSecret -VaultName $keyVaultName -Name $keyVaultSQLUserSecretName -SecretValue $secretValue

Write-Information "Create KeyVault linked service $($keyVaultName)"

$result = Create-KeyVaultLinkedService -TemplatesPath $templatesPath -WorkspaceName $workspaceName -Name $keyVaultName
Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId

Write-Information "Create Integration Runtime $($integrationRuntimeName)"

$result = Create-IntegrationRuntime -TemplatesPath $templatesPath -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -WorkspaceName $workspaceName -Name $integrationRuntimeName -CoreCount 16 -TimeToLive 60
Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId

Write-Information "Create Data Lake linked service $($dataLakeAccountName)"

$dataLakeAccountKey = List-StorageAccountKeys -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -Name $dataLakeAccountName
$result = Create-DataLakeLinkedService -TemplatesPath $templatesPath -WorkspaceName $workspaceName -Name $dataLakeAccountName  -Key $dataLakeAccountKey
Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId

Write-Information "Create linked service for SQL pool $($sqlPoolName) with user asaexp.sql.admin"

$linkedServiceName = $sqlPoolName.ToLower()
$result = Create-SQLPoolKeyVaultLinkedService -TemplatesPath $templatesPath -WorkspaceName $workspaceName -Name $linkedServiceName -DatabaseName $sqlPoolName -UserName "asaexp.sql.admin" -KeyVaultLinkedServiceName $keyVaultName -SecretName $keyVaultSQLUserSecretName
Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId

Write-Information "Create Blob Storage linked service $($blobStorageAccountName)"

$blobStorageAccountKey = List-StorageAccountKeys -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -Name $blobStorageAccountName
$result = Create-BlobStorageLinkedService -TemplatesPath $templatesPath -WorkspaceName $workspaceName -Name $blobStorageAccountName  -Key $blobStorageAccountKey
Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId

Write-Information "Copy Public Data"

Ensure-ValidTokens $true

if ([System.Environment]::OSVersion.Platform -eq "Unix")
{
        $azCopyLink = Check-HttpRedirect "https://aka.ms/downloadazcopy-v10-linux"

        if (!$azCopyLink)
        {
                $azCopyLink = "https://azcopyvnext.azureedge.net/release20200709/azcopy_linux_amd64_10.5.0.tar.gz"
        }

        Invoke-WebRequest $azCopyLink -OutFile "azCopy.tar.gz"
        tar -xf "azCopy.tar.gz"
        $azCopyCommand = (Get-ChildItem -Path ".\" -Recurse azcopy).Directory.FullName
        cd $azCopyCommand
        chmod +x azcopy
        cd ..
        $azCopyCommand += "\azcopy"
}
else
{
        $azCopyLink = Check-HttpRedirect "https://aka.ms/downloadazcopy-v10-windows"

        if (!$azCopyLink)
        {
                $azCopyLink = "https://azcopyvnext.azureedge.net/release20200501/azcopy_windows_amd64_10.4.3.zip"
        }

        Invoke-WebRequest $azCopyLink -OutFile "azCopy.zip"
        Expand-Archive "azCopy.zip" -DestinationPath ".\" -Force
        $azCopyCommand = (Get-ChildItem -Path ".\" -Recurse azcopy.exe).Directory.FullName
        $azCopyCommand += "\azcopy"
}

#$jobs = $(azcopy jobs list)

$download = $false;

$publicDataUrl = "https://solliancepublicdata.blob.core.windows.net/"
$dataLakeStorageUrl = "https://"+ $dataLakeAccountName + ".dfs.core.windows.net/"
$dataLakeStorageBlobUrl = "https://"+ $dataLakeAccountName + ".blob.core.windows.net/"
$dataLakeStorageAccountKey = (Get-AzStorageAccountKey -ResourceGroupName $resourceGroupName -AccountName $dataLakeAccountName)[0].Value
$dataLakeContext = New-AzStorageContext -StorageAccountName $dataLakeAccountName -StorageAccountKey $dataLakeStorageAccountKey

$storageContainers = @{
        twitterData = "twitterdata"
        financeDb = "financedb"
        salesData = "salesdata"
        customerInsights = "customer-insights"
        sapHana = "saphana"
        campaignData = "campaigndata"
        iotContainer = "iotcontainer"
        recommendations = "recommendations"
        customCsv = "customcsv"
        machineLearning = "machine-learning"
}

foreach ($storageContainer in $storageContainers.Keys) {        
        Write-Information "Creating container: $($storageContainers[$storageContainer])"
        if(Get-AzStorageContainer -Name $storageContainers[$storageContainer] -Context $dataLakeContext -ErrorAction SilentlyContinue)  {  
                Write-Information "$($storageContainers[$storageContainer]) container already exists."  
        }else{  
                Write-Information "$($storageContainers[$storageContainer]) container created."   
                New-AzStorageContainer -Name $storageContainers[$storageContainer] -Permission Container -Context $dataLakeContext  
        }
}          

$destinationSasKey = New-AzStorageContainerSASToken -Container "wwi-02" -Context $dataLakeContext -Permission rwdl

if ($download)
{
        Write-Information "Copying single files from the public data account..."
        $singleFiles = @{
                customer_info = "wwi-02/customer-info/customerinfo.csv"
                products = "wwi-02/data-generators/generator-product/generator-product.csv"
                dates = "wwi-02/data-generators/generator-date.csv"
                customer = "wwi-02/data-generators/generator-customer.csv"
                onnx = "wwi-02/ml/onnx-hex/product_seasonality_classifier.onnx.hex"
        }

        foreach ($singleFile in $singleFiles.Keys) {
                $source = $publicDataUrl + $singleFiles[$singleFile]
                $destination = $dataLakeStorageBlobUrl + $singleFiles[$singleFile] + $destinationSasKey
                Write-Information "Copying file $($source) to $($destination)"
                & $azCopyCommand copy $source $destination 
        }

        Write-Information "Copying sample sales raw data directories from the public data account..."

        $dataDirectories = @{
                salesmall = "wwi-02,wwi-02/sale-small/"
                analytics = "wwi-02,wwi-02/campaign-analytics/"
                factsale = "wwi-02,wwi-02/sale-csv/"
                security = "wwi-02,wwi-02-reduced/security/"
                salespoc = "wwi-02,wwi-02/sale-poc/"
        }

        foreach ($dataDirectory in $dataDirectories.Keys) {

                $vals = $dataDirectories[$dataDirectory].tostring().split(",");

                $source = $publicDataUrl + $vals[1];

                $path = $vals[0];

                $destination = $dataLakeStorageBlobUrl + $path + $destinationSasKey
                Write-Information "Copying directory $($source) to $($destination)"
                & $azCopyCommand copy $source $destination --recursive=true
        }

    $StartTime = Get-Date
    $EndTime = $startTime.AddDays(365)  
    $destinationSasKey = New-AzStorageContainerSASToken -Container "twitterdata" -Context $dataLakeContext -Permission rwdl -ExpiryTime $EndTime

    $AnonContext = New-AzStorageContext -StorageAccountName "solliancepublicdata" -Anonymous
    $singleFiles = Get-AzStorageBlob -Container "cdp" -Blob twitter* -Context $AnonContext | Where-Object Length -GT 0 | select-object @{Name = "SourcePath"; Expression = {"cdp/"+$_.Name}} , @{Name = "TargetPath"; Expression = {$_.Name}}

    foreach ($singleFile in $singleFiles) {
            Write-Information $singleFile
            $source = $publicDataUrl + $singleFile.SourcePath
            $destination = $dataLakeStorageBlobUrl + $singleFile.TargetPath + $destinationSasKey
            Write-Information "Copying file $($source) to $($destination)"
        
            & $azCopyCommand copy $source $destination 
    }

    $destinationSasKey = New-AzStorageContainerSASToken -Container "customcsv" -Context $dataLakeContext -Permission rwdl -ExpiryTime $EndTime
    $singleFiles = Get-AzStorageBlob -Container "cdp" -Blob customcsv* -Context $AnonContext | Where-Object Length -GT 0 | select-object @{Name = "SourcePath"; Expression = {"cdp/"+$_.Name}} , @{Name = "TargetPath"; Expression = {$_.Name}}

    foreach ($singleFile in $singleFiles) {
            Write-Information $singleFile
            $source = $publicDataUrl + $singleFile.SourcePath
            $destination = $dataLakeStorageBlobUrl + $singleFile.TargetPath + $destinationSasKey
            Write-Information "Copying file $($source) to $($destination)"
        
            & $azCopyCommand copy $source $destination 
    }

    $destinationSasKey = New-AzStorageContainerSASToken -Container "machine-learning" -Context $dataLakeContext -Permission rwdl -ExpiryTime $EndTime
    $singleFiles = Get-AzStorageBlob -Container "cdp" -Blob machine* -Context $AnonContext | Where-Object Length -GT 0 | select-object @{Name = "SourcePath"; Expression = {"cdp/"+$_.Name}} , @{Name = "TargetPath"; Expression = {$_.Name}}

    foreach ($singleFile in $singleFiles) {
            Write-Information $singleFile
            $source = $publicDataUrl + $singleFile.SourcePath
            $destination = $dataLakeStorageBlobUrl + $singleFile.TargetPath + $destinationSasKey
            Write-Information "Copying file $($source) to $($destination)"
        
            & $azCopyCommand copy $source $destination 
    }
}

Write-Information "Start the $($sqlPoolName) SQL pool if needed."

$result = Get-SQLPool -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -WorkspaceName $workspaceName -SQLPoolName $sqlPoolName
if ($result.properties.status -ne "Online") {
    Control-SQLPool -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -WorkspaceName $workspaceName -SQLPoolName $sqlPoolName -Action resume
    Wait-ForSQLPool -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -WorkspaceName $workspaceName -SQLPoolName $sqlPoolName -TargetStatus Online
}

#Write-Information "Scale up the $($sqlPoolName) SQL pool to DW3000c to prepare for baby MOADs import."

#Control-SQLPool -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -WorkspaceName $workspaceName -SQLPoolName $sqlPoolName -Action scale -SKU DW3000c
#Wait-ForSQLPool -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -WorkspaceName $workspaceName -SQLPoolName $sqlPoolName -TargetStatus Online

Ensure-ValidTokens $true

Write-Information "Create SQL logins in master SQL pool"

$params = @{ PASSWORD = $sqlPassword }
$result = Execute-SQLScriptFile -SQLScriptsPath $sqlScriptsPath -WorkspaceName $workspaceName -SQLPoolName "master" -FileName "01-create-logins" -Parameters $params
$result

Write-Information "Create SQL users and role assignments in $($sqlPoolName)"

$params = @{ USER_NAME = $userName }
$result = Execute-SQLScriptFile -SQLScriptsPath $sqlScriptsPath -WorkspaceName $workspaceName -SQLPoolName $sqlPoolName -FileName "02-create-users" -Parameters $params
$result

Write-Information "Create schemas in $($sqlPoolName)"

$params = @{}
$result = Execute-SQLScriptFile -SQLScriptsPath $sqlScriptsPath -WorkspaceName $workspaceName -SQLPoolName $sqlPoolName -FileName "03-create-schemas" -Parameters $params
$result

Write-Information "Create tables in the [wwi] schema in $($sqlPoolName)"

$params = @{}
$result = Execute-SQLScriptFile -SQLScriptsPath $sqlScriptsPath -WorkspaceName $workspaceName -SQLPoolName $sqlPoolName -FileName "04-create-tables-in-wwi-schema" -Parameters $params
$result


Write-Information "Create tables in the [wwi_ml] schema in $($sqlPoolName)"

$dataLakeAccountKey = List-StorageAccountKeys -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -Name $dataLakeAccountName
$params = @{ 
        DATA_LAKE_ACCOUNT_NAME = $dataLakeAccountName  
        DATA_LAKE_ACCOUNT_KEY = $dataLakeAccountKey 
}
$result = Execute-SQLScriptFile -SQLScriptsPath $sqlScriptsPath -WorkspaceName $workspaceName -SQLPoolName $sqlPoolName -FileName "05-create-tables-in-wwi-ml-schema" -Parameters $params
$result

Write-Information "Create tables in the [wwi_security] schema in $($sqlPoolName)"

$params = @{ 
        DATA_LAKE_ACCOUNT_NAME = $dataLakeAccountName  
        DATA_LAKE_ACCOUNT_KEY = $dataLakeAccountKey 
}
$result = Execute-SQLScriptFile -SQLScriptsPath $sqlScriptsPath -WorkspaceName $workspaceName -SQLPoolName $sqlPoolName -FileName "06-create-tables-in-wwi-security-schema" -Parameters $params
$result

Write-Information "Create tables in $($sqlPoolName)"

$result = Execute-SQLScriptFile -SQLScriptsPath $sqlScriptsPath -WorkspaceName $workspaceName -SQLPoolName $sqlPoolName -FileName "01-create-tables" -Parameters $params 
$result

Write-Information "Create storade procedures in $($sqlPoolName)"

$result = Execute-SQLScriptFile -SQLScriptsPath $sqlScriptsPath -WorkspaceName $workspaceName -SQLPoolName $sqlPoolName -FileName "04-create-stored-procedures" -Parameters $params 
$result

Write-Information "Loading data"

$dataTableList = New-Object System.Collections.ArrayList
$temp = "" | select-object @{Name = "CSV_FILE_NAME"; Expression = {"Dim_Customer"}} , @{Name = "TABLE_NAME"; Expression = {"Dim_Customer"}}, @{Name = "DATA_START_ROW_NUMBER"; Expression = {2}}
$dataTableList.Add($temp)
$temp = "" | select-object @{Name = "CSV_FILE_NAME"; Expression = {"MillennialCustomers"}} , @{Name = "TABLE_NAME"; Expression = {"MillennialCustomers"}}, @{Name = "DATA_START_ROW_NUMBER"; Expression = {2}}
$dataTableList.Add($temp)
$temp = "" | select-object @{Name = "CSV_FILE_NAME"; Expression = {"sale"}} , @{Name = "TABLE_NAME"; Expression = {"Sales"}}, @{Name = "DATA_START_ROW_NUMBER"; Expression = {2}}
$dataTableList.Add($temp)
$temp = "" | select-object @{Name = "CSV_FILE_NAME"; Expression = {"Products"}} , @{Name = "TABLE_NAME"; Expression = {"Products"}}, @{Name = "DATA_START_ROW_NUMBER"; Expression = {2}}
$dataTableList.Add($temp)
$temp = "" | select-object @{Name = "CSV_FILE_NAME"; Expression = {"TwitterAnalytics"}} , @{Name = "TABLE_NAME"; Expression = {"TwitterAnalytics"}}, @{Name = "DATA_START_ROW_NUMBER"; Expression = {2}}
$dataTableList.Add($temp)
$temp = "" | select-object @{Name = "CSV_FILE_NAME"; Expression = {"10millionrows"}} , @{Name = "TABLE_NAME"; Expression = {"IDS"}}, @{Name = "DATA_START_ROW_NUMBER"; Expression = {2}}
$dataTableList.Add($temp)
$temp = "" | select-object @{Name = "CSV_FILE_NAME"; Expression = {"TwitterRawData"}} , @{Name = "TABLE_NAME"; Expression = {"TwitterRawData"}}, @{Name = "DATA_START_ROW_NUMBER"; Expression = {2}}
$dataTableList.Add($temp)
$temp = "" | select-object @{Name = "CSV_FILE_NAME"; Expression = {"department_visit_customer"}} , @{Name = "TABLE_NAME"; Expression = {"department_visit_customer"}}, @{Name = "DATA_START_ROW_NUMBER"; Expression = {2}}
$dataTableList.Add($temp)
$temp = "" | select-object @{Name = "CSV_FILE_NAME"; Expression = {"Category"}} , @{Name = "TABLE_NAME"; Expression = {"Category"}}, @{Name = "DATA_START_ROW_NUMBER"; Expression = {2}}
$dataTableList.Add($temp)
$temp = "" | select-object @{Name = "CSV_FILE_NAME"; Expression = {"ProdChamp"}} , @{Name = "TABLE_NAME"; Expression = {"ProdChamp"}}, @{Name = "DATA_START_ROW_NUMBER"; Expression = {2}}
$dataTableList.Add($temp)
$temp = "" | select-object @{Name = "CSV_FILE_NAME"; Expression = {"WebsiteSocialAnalytics"}} , @{Name = "TABLE_NAME"; Expression = {"WebsiteSocialAnalytics"}}, @{Name = "DATA_START_ROW_NUMBER"; Expression = {2}}
$dataTableList.Add($temp)
$temp = "" | select-object @{Name = "CSV_FILE_NAME"; Expression = {"Campaigns"}} , @{Name = "TABLE_NAME"; Expression = {"Campaigns"}}, @{Name = "DATA_START_ROW_NUMBER"; Expression = {2}}
$dataTableList.Add($temp)
$temp = "" | select-object @{Name = "CSV_FILE_NAME"; Expression = {"Campaign_Analytics"}} , @{Name = "TABLE_NAME"; Expression = {"Campaign_Analytics"}}, @{Name = "DATA_START_ROW_NUMBER"; Expression = {2}}
$dataTableList.Add($temp)
$temp = "" | select-object @{Name = "CSV_FILE_NAME"; Expression = {"CampaignNew4"}} , @{Name = "TABLE_NAME"; Expression = {"CampaignNew4"}}, @{Name = "DATA_START_ROW_NUMBER"; Expression = {2}}
$dataTableList.Add($temp)
$temp = "" | select-object @{Name = "CSV_FILE_NAME"; Expression = {"CustomerVisitF"}} , @{Name = "TABLE_NAME"; Expression = {"CustomerVisitF"}}, @{Name = "DATA_START_ROW_NUMBER"; Expression = {2}}
$dataTableList.Add($temp)
$temp = "" | select-object @{Name = "CSV_FILE_NAME"; Expression = {"FinanceSales"}} , @{Name = "TABLE_NAME"; Expression = {"FinanceSales"}}, @{Name = "DATA_START_ROW_NUMBER"; Expression = {2}}
$dataTableList.Add($temp)
$temp = "" | select-object @{Name = "CSV_FILE_NAME"; Expression = {"LocationAnalytics"}} , @{Name = "TABLE_NAME"; Expression = {"LocationAnalytics"}}, @{Name = "DATA_START_ROW_NUMBER"; Expression = {2}}
$dataTableList.Add($temp)
$temp = "" | select-object @{Name = "CSV_FILE_NAME"; Expression = {"ProductLink2"}} , @{Name = "TABLE_NAME"; Expression = {"ProductLink2"}}, @{Name = "DATA_START_ROW_NUMBER"; Expression = {2}}
$dataTableList.Add($temp)
$temp = "" | select-object @{Name = "CSV_FILE_NAME"; Expression = {"ProductRecommendations"}} , @{Name = "TABLE_NAME"; Expression = {"ProductRecommendations"}}, @{Name = "DATA_START_ROW_NUMBER"; Expression = {2}}
$dataTableList.Add($temp)
$temp = "" | select-object @{Name = "CSV_FILE_NAME"; Expression = {"BrandAwareness"}} , @{Name = "TABLE_NAME"; Expression = {"BrandAwareness"}}, @{Name = "DATA_START_ROW_NUMBER"; Expression = {2}}
$dataTableList.Add($temp)
$temp = "" | select-object @{Name = "CSV_FILE_NAME"; Expression = {"ProductLink"}} , @{Name = "TABLE_NAME"; Expression = {"ProductLink"}}, @{Name = "DATA_START_ROW_NUMBER"; Expression = {2}}
$dataTableList.Add($temp)
$temp = "" | select-object @{Name = "CSV_FILE_NAME"; Expression = {"SalesMaster"}} , @{Name = "TABLE_NAME"; Expression = {"SalesMaster"}}, @{Name = "DATA_START_ROW_NUMBER"; Expression = {2}}
$dataTableList.Add($temp)
$temp = "" | select-object @{Name = "CSV_FILE_NAME"; Expression = {"SalesVsExpense"}} , @{Name = "TABLE_NAME"; Expression = {"SalesVsExpense"}}, @{Name = "DATA_START_ROW_NUMBER"; Expression = {2}}
$dataTableList.Add($temp)
$temp = "" | select-object @{Name = "CSV_FILE_NAME"; Expression = {"FPA"}} , @{Name = "TABLE_NAME"; Expression = {"FPA"}}, @{Name = "DATA_START_ROW_NUMBER"; Expression = {2}}
$dataTableList.Add($temp)
$temp = "" | select-object @{Name = "CSV_FILE_NAME"; Expression = {"Country"}} , @{Name = "TABLE_NAME"; Expression = {"Country"}}, @{Name = "DATA_START_ROW_NUMBER"; Expression = {2}}
$dataTableList.Add($temp)
$temp = "" | select-object @{Name = "CSV_FILE_NAME"; Expression = {"Books"}} , @{Name = "TABLE_NAME"; Expression = {"Books"}}, @{Name = "DATA_START_ROW_NUMBER"; Expression = {2}}
$dataTableList.Add($temp)
$temp = "" | select-object @{Name = "CSV_FILE_NAME"; Expression = {"BookConsumption"}} , @{Name = "TABLE_NAME"; Expression = {"BookConsumption"}}, @{Name = "DATA_START_ROW_NUMBER"; Expression = {2}}
$dataTableList.Add($temp)
$temp = "" | select-object @{Name = "CSV_FILE_NAME"; Expression = {"EmailAnalytics"}} , @{Name = "TABLE_NAME"; Expression = {"EmailAnalytics"}}, @{Name = "DATA_START_ROW_NUMBER"; Expression = {2}}
$dataTableList.Add($temp)
$temp = "" | select-object @{Name = "CSV_FILE_NAME"; Expression = {"DimDate"}} , @{Name = "TABLE_NAME"; Expression = {"DimDate"}}, @{Name = "DATA_START_ROW_NUMBER"; Expression = {2}}
$dataTableList.Add($temp)
$temp = "" | select-object @{Name = "CSV_FILE_NAME"; Expression = {"Popularity"}} , @{Name = "TABLE_NAME"; Expression = {"Popularity"}}, @{Name = "DATA_START_ROW_NUMBER"; Expression = {2}}
$dataTableList.Add($temp)
$temp = "" | select-object @{Name = "CSV_FILE_NAME"; Expression = {"FinalRevenue"}} , @{Name = "TABLE_NAME"; Expression = {"FinalRevenue"}}, @{Name = "DATA_START_ROW_NUMBER"; Expression = {2}}
$dataTableList.Add($temp)
$temp = "" | select-object @{Name = "CSV_FILE_NAME"; Expression = {"ConflictofInterest"}} , @{Name = "TABLE_NAME"; Expression = {"ConflictofInterest"}}, @{Name = "DATA_START_ROW_NUMBER"; Expression = {2}}
$dataTableList.Add($temp)
$temp = "" | select-object @{Name = "CSV_FILE_NAME"; Expression = {"CampaignAnalytics"}} , @{Name = "TABLE_NAME"; Expression = {"CampaignAnalytics"}}, @{Name = "DATA_START_ROW_NUMBER"; Expression = {2}}
$dataTableList.Add($temp)
$temp = "" | select-object @{Name = "CSV_FILE_NAME"; Expression = {"SiteSecurity"}} , @{Name = "TABLE_NAME"; Expression = {"SiteSecurity"}}, @{Name = "DATA_START_ROW_NUMBER"; Expression = {2}}
$dataTableList.Add($temp)
$temp = "" | select-object @{Name = "CSV_FILE_NAME"; Expression = {"BookList"}} , @{Name = "TABLE_NAME"; Expression = {"BookList"}}, @{Name = "DATA_START_ROW_NUMBER"; Expression = {2}}
$dataTableList.Add($temp)
$temp = "" | select-object @{Name = "CSV_FILE_NAME"; Expression = {"WebsiteSocialAnalyticsPBIData"}} , @{Name = "TABLE_NAME"; Expression = {"WebsiteSocialAnalyticsPBIData"}}, @{Name = "DATA_START_ROW_NUMBER"; Expression = {2}}
$dataTableList.Add($temp)
$temp = "" | select-object @{Name = "CSV_FILE_NAME"; Expression = {"CampaignAnalyticLatest"}} , @{Name = "TABLE_NAME"; Expression = {"CampaignAnalyticLatest"}}, @{Name = "DATA_START_ROW_NUMBER"; Expression = {2}}
$dataTableList.Add($temp)
$temp = "" | select-object @{Name = "CSV_FILE_NAME"; Expression = {"location_Analytics"}} , @{Name = "TABLE_NAME"; Expression = {"location_Analytics"}}, @{Name = "DATA_START_ROW_NUMBER"; Expression = {2}}
$dataTableList.Add($temp)
$temp = "" | select-object @{Name = "CSV_FILE_NAME"; Expression = {"DimData"}} , @{Name = "TABLE_NAME"; Expression = {"DimData"}}, @{Name = "DATA_START_ROW_NUMBER"; Expression = {2}}
$dataTableList.Add($temp)
$temp = "" | select-object @{Name = "CSV_FILE_NAME"; Expression = {"salesPBIData"}} , @{Name = "TABLE_NAME"; Expression = {"salesPBIData"}}, @{Name = "DATA_START_ROW_NUMBER"; Expression = {2}}
$dataTableList.Add($temp)
$temp = "" | select-object @{Name = "CSV_FILE_NAME"; Expression = {"Customer_SalesLatest"}} , @{Name = "TABLE_NAME"; Expression = {"Customer_SalesLatest"}}, @{Name = "DATA_START_ROW_NUMBER"; Expression = {2}}
$dataTableList.Add($temp)
$temp = "" | select-object @{Name = "CSV_FILE_NAME"; Expression = {"department_visit_customer"}} , @{Name = "TABLE_NAME"; Expression = {"department_visit_customer"}}, @{Name = "DATA_START_ROW_NUMBER"; Expression = {2}}
$dataTableList.Add($temp)

foreach ($dataTableLoad in $dataTableList) {
        Write-Information "Loading data for $($dataTableLoad.TABLE_NAME)"
        $result = Execute-SQLScriptFile -SQLScriptsPath $sqlScriptsPath -WorkspaceName $workspaceName -SQLPoolName $sqlPoolName -FileName "02-load-csv" -Parameters @{
                CSV_FILE_NAME = $dataTableLoad.CSV_FILE_NAME
                TABLE_NAME = $dataTableLoad.TABLE_NAME
                DATA_START_ROW_NUMBER = $dataTableLoad.DATA_START_ROW_NUMBER
         }
        $result
        Write-Information "Data for $($dataTableLoad.TABLE_NAME) loaded."
}

if($Load30Billion -eq 1)
{
        Write-Information "Loading 30 Billion Records"

        Write-Information "Scale up the $($sqlPoolName) SQL pool to DW3000c to prepare for 30 Billion Rows."
        
        Control-SQLPool -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -WorkspaceName $workspaceName -SQLPoolName $sqlPoolName -Action scale -SKU DW3000c
        Wait-ForSQLPool -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -WorkspaceName $workspaceName -SQLPoolName $sqlPoolName -TargetStatus Online
        
        $start = Get-Date
        [nullable[double]]$secondsRemaining = $null
        $maxIterationCount = 3000
        $secondsElapsed = 0

        For ($count=1; $count -le $maxIterationCount; $count++) {
        
                $percentComplete = ($count / $maxIterationCount) * 100
                $progressParameters = @{
                        Activity = "Loading data [$($count)/$($maxIterationCount)] $($secondsElapsed.ToString('hh\:mm\:ss'))"
                        Status = 'Processing'
                        PercentComplete = $percentComplete
                    }
        
                if ($secondsRemaining) {
                        $progressParameters.SecondsRemaining = $secondsRemaining
                    }
        
                Write-Progress @progressParameters
        
                $params = @{ }
                $result = Execute-SQLScriptFile -SQLScriptsPath $sqlScriptsPath -WorkspaceName $workspaceName -SQLPoolName $sqlPoolName -FileName "03-Billion_Records" -Parameters $params 
                $result
        
                $secondsElapsed = (Get-Date) - $start
                $secondsRemaining = ($secondsElapsed.TotalSeconds / ($count +1)) * ($maxIterationCount - $count)
        }

        Write-Information "Scale down the $($sqlPoolName) SQL pool to DW500c after 30 Billion Rows."

        Control-SQLPool -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -WorkspaceName $workspaceName -SQLPoolName $sqlPoolName -Action scale -SKU DW500c
        Wait-ForSQLPool -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -WorkspaceName $workspaceName -SQLPoolName $sqlPoolName -TargetStatus Online
}

Write-Information "Create linked service for SQL pool $($sqlPoolName) with user asa.sql.admin"

$linkedServiceName = $sqlPoolName.ToLower()
$result = Create-SQLPoolKeyVaultLinkedService -TemplatesPath $templatesPath -WorkspaceName $workspaceName -Name $linkedServiceName -DatabaseName $sqlPoolName `
                 -UserName "asa.sql.admin" -KeyVaultLinkedServiceName $keyVaultName -SecretName $keyVaultSQLUserSecretName
Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId

Write-Information "Create linked service for SQL pool $($sqlPoolName) with user asa.sql.highperf"

$linkedServiceName = "$($sqlPoolName.ToLower())_highperf"
$result = Create-SQLPoolKeyVaultLinkedService -TemplatesPath $templatesPath -WorkspaceName $workspaceName -Name $linkedServiceName -DatabaseName $sqlPoolName `
                 -UserName "asa.sql.highperf" -KeyVaultLinkedServiceName $keyVaultName -SecretName $keyVaultSQLUserSecretName
Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId

<# Day 1-3#>

Write-Information "Create data sets for data load in SQL pool $($sqlPoolName)"

$loadingDatasets = @{
        wwi02_date_adls = $dataLakeAccountName
        wwi02_product_adls = $dataLakeAccountName
        wwi02_sale_small_adls = $dataLakeAccountName
        wwi02_date_asa = $sqlPoolName.ToLower()
        wwi02_product_asa = $sqlPoolName.ToLower()
        wwi02_sale_small_asa = "$($sqlPoolName.ToLower())_highperf"
}

foreach ($dataset in $loadingDatasets.Keys) {
        Write-Information "Creating dataset $($dataset)"
        $result = Create-Dataset -DatasetsPath $datasetsPath -WorkspaceName $workspaceName -Name $dataset -LinkedServiceName $loadingDatasets[$dataset]
        Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId
}

Write-Information "Create pipeline to load the SQL pool"

$params = @{
        BLOB_STORAGE_LINKED_SERVICE_NAME = $blobStorageAccountName
}
$loadingPipelineName = "Setup - Load SQL Pool (global)"
$fileName = "load_sql_pool_from_data_lake"

Write-Information "Creating pipeline $($loadingPipelineName)"

$result = Create-Pipeline -PipelinesPath $pipelinesPath -WorkspaceName $workspaceName -Name $loadingPipelineName -FileName $fileName -Parameters $params
Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId

Write-Information "Running pipeline $($loadingPipelineName)"

$result = Run-Pipeline -WorkspaceName $workspaceName -Name $loadingPipelineName
$result = Wait-ForPipelineRun -WorkspaceName $workspaceName -RunId $result.runId
$result

Ensure-ValidTokens

Write-Information "Deleting pipeline $($loadingPipelineName)"

$result = Delete-ASAObject -WorkspaceName $workspaceName -Category "pipelines" -Name $loadingPipelineName
Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId

foreach ($dataset in $loadingDatasets.Keys) {
        Write-Information "Deleting dataset $($dataset)"
        $result = Delete-ASAObject -WorkspaceName $workspaceName -Category "datasets" -Name $dataset
        Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId
}

<# POC - Day 4 - Must be run after Day 3 content/pipeline loads#>

Write-Information "Create wwi_poc schema and tables in $($sqlPoolName)"

$params = @{}
$result = Execute-SQLScriptFile -SQLScriptsPath $sqlScriptsPath -WorkspaceName $workspaceName -SQLPoolName $sqlPoolName -FileName "16-create-poc-schema" -Parameters $params
$result

Write-Information "Create the [wwi_poc.Sale] table in SQL pool $($sqlPoolName)"

$result = Execute-SQLScriptFile -SQLScriptsPath $sqlScriptsPath -WorkspaceName $workspaceName -SQLPoolName $sqlPoolName -FileName "17-create-wwi-poc-sale-heap" -Parameters $params
$result

Write-Information "Create data sets for PoC data load in SQL pool $($sqlPoolName)"

$loadingDatasets = @{
        wwi02_poc_customer_adls = $dataLakeAccountName
        wwi02_poc_customer_asa = $sqlPoolName.ToLower()
}

foreach ($dataset in $loadingDatasets.Keys) {
        Write-Information "Creating dataset $($dataset)"
        $result = Create-Dataset -DatasetsPath $datasetsPath -WorkspaceName $workspaceName -Name $dataset -LinkedServiceName $loadingDatasets[$dataset]
        Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId
}

Write-Information "Create pipeline to load PoC data into the SQL pool"

$params = @{
        BLOB_STORAGE_LINKED_SERVICE_NAME = $blobStorageAccountName
}
$loadingPipelineName = "Setup - Load SQL Pool"
$fileName = "import_poc_customer_data"

Write-Information "Creating pipeline $($loadingPipelineName)"

$result = Create-Pipeline -PipelinesPath $pipelinesPath -WorkspaceName $workspaceName -Name $loadingPipelineName -FileName $fileName -Parameters $params
Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId

Write-Information "Running pipeline $($loadingPipelineName)"

$result = Run-Pipeline -WorkspaceName $workspaceName -Name $loadingPipelineName
$result = Wait-ForPipelineRun -WorkspaceName $workspaceName -RunId $result.runId
$result

Write-Information "Deleting pipeline $($loadingPipelineName)"

$result = Delete-ASAObject -WorkspaceName $workspaceName -Category "pipelines" -Name $loadingPipelineName
Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId

foreach ($dataset in $loadingDatasets.Keys) {
        Write-Information "Deleting dataset $($dataset)"
        $result = Delete-ASAObject -WorkspaceName $workspaceName -Category "datasets" -Name $dataset
        Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId
}



Write-Information "Create tables in wwi_perf schema in SQL pool $($sqlPoolName)"

$params = @{}
$scripts = [ordered]@{
        "07-create-wwi-perf-sale-heap" = "CTAS : Sale_Heap"
        "08-create-wwi-perf-sale-partition01" = "CTAS : Sale_Partition01"
        "09-create-wwi-perf-sale-partition02" = "CTAS : Sale_Partition02"
        "10-create-wwi-perf-sale-index" = "CTAS : Sale_Index"
        "11-create-wwi-perf-sale-hash-ordered" = "CTAS : Sale_Hash_Ordered"
}

foreach ($script in $scripts.Keys) {

        $refTime = (Get-Date).ToUniversalTime()
        Write-Information "Starting $($script) with label $($scripts[$script])"
        
        # initiate the script and wait until it finishes
        Execute-SQLScriptFile -SQLScriptsPath $sqlScriptsPath -WorkspaceName $workspaceName -SQLPoolName $sqlPoolName -FileName $script -ForceReturn $true
        Wait-ForSQLQuery -WorkspaceName $workspaceName -SQLPoolName $sqlPoolName -Label $scripts[$script] -ReferenceTime $refTime
}

#Write-Information "Scale down the $($sqlPoolName) SQL pool to DW500c after baby MOADs import."

#Control-SQLPool -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -WorkspaceName $workspaceName -SQLPoolName $sqlPoolName -Action scale -SKU DW500c
#Wait-ForSQLPool -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -WorkspaceName $workspaceName -SQLPoolName $sqlPoolName -TargetStatus Online

Write-Information "Create linked service for SQL pool $($sqlPoolName) with user asa.sql.import01"

$linkedServiceName = "$($sqlPoolName.ToLower())_import01"
$result = Create-SQLPoolKeyVaultLinkedService -TemplatesPath $templatesPath -WorkspaceName $workspaceName -Name $linkedServiceName -DatabaseName $sqlPoolName `
                 -UserName "asa.sql.import01" -KeyVaultLinkedServiceName $keyVaultName -SecretName $keyVaultSQLUserSecretName
Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId

Write-Information "Create linked service for SQL pool $($sqlPoolName) with user asa.sql.workload01"

$linkedServiceName = "$($sqlPoolName.ToLower())_workload01"
$result = Create-SQLPoolKeyVaultLinkedService -TemplatesPath $templatesPath -WorkspaceName $workspaceName -Name $linkedServiceName -DatabaseName $sqlPoolName `
                 -UserName "asa.sql.workload01" -KeyVaultLinkedServiceName $keyVaultName -SecretName $keyVaultSQLUserSecretName
Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId

Write-Information "Create linked service for SQL pool $($sqlPoolName) with user asa.sql.workload02"

$linkedServiceName = "$($sqlPoolName.ToLower())_workload02"
$result = Create-SQLPoolKeyVaultLinkedService -TemplatesPath $templatesPath -WorkspaceName $workspaceName -Name $linkedServiceName -DatabaseName $sqlPoolName `
                 -UserName "asa.sql.workload02" -KeyVaultLinkedServiceName $keyVaultName -SecretName $keyVaultSQLUserSecretName
Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId


Write-Information "Create data sets for Lab 08"

$datasets = @{
        wwi02_sale_small_workload_01_asa = "$($sqlPoolName.ToLower())_workload01"
        wwi02_sale_small_workload_02_asa = "$($sqlPoolName.ToLower())_workload02"
}

foreach ($dataset in $datasets.Keys) {
        Write-Information "Creating dataset $($dataset)"
        $result = Create-Dataset -DatasetsPath $datasetsPath -WorkspaceName $workspaceName -Name $dataset -LinkedServiceName $datasets[$dataset]
        Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId
}

Write-Information "Create pipelines for Lab 08"

$params = @{}
$workloadPipelines = [ordered]@{
        execute_business_analyst_queries = "Lab 08 - Execute Business Analyst Queries"
        execute_data_analyst_and_ceo_queries = "Lab 08 - Execute Data Analyst and CEO Queries"
}

foreach ($pipeline in $workloadPipelines.Keys) {
        Write-Information "Creating workload pipeline $($workloadPipelines[$pipeline])"
        $result = Create-Pipeline -PipelinesPath $pipelinesPath -WorkspaceName $workspaceName -Name $workloadPipelines[$pipeline] -FileName $pipeline -Parameters $params
        Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId
}

#data sets come BEFORE pipelines!
Write-Information "Create data sets for Lab 08"

$datasets = @{
        DestinationDataset_d89 = $dataLakeAccountName
        SourceDataset_d89 = $dataLakeAccountName
        AzureSynapseAnalyticsTable8 = $workspaceName + "-WorkspaceDefaultSqlServer"
        AzureSynapseAnalyticsTable9 = $workspaceName + "-WorkspaceDefaultSqlServer"
        DelimitedText1 = $dataLakeAccountName 
        TeradataMarketingDB = $dataLakeAccountName 
        MarketingDB_Stage = $dataLakeAccountName 
        Synapse = $workspaceName + "-WorkspaceDefaultSqlServer"
        OracleSalesDB = $workspaceName + "-WorkspaceDefaultSqlServer" 
        AzureSynapseAnalyticsTable1 = $workspaceName + "-WorkspaceDefaultSqlServer"
        Parquet1 = $dataLakeAccountName
        Parquet2 = $dataLakeAccountName
        Parquet3 = $dataLakeAccountName
        CampaignAnalyticLatest = "NA"
        CampaignNew4 = "NA"
        Campaigns = "NA"
        location_Analytics = "NA"
        WebsiteSocialAnalyticsPBIData = "NA"
        CustomerVisitF = "NA"
        FinanceSales = "NA"
        EmailAnalytics = "NA"
        ProductLink2 = "NA"
        ProductRecommendations = "NA"
        SalesMaster = "NA"
        CustomerVisitF_Spark = "NA"
        Customer_SalesLatest = "NA"
        Product_Recommendations_Spark_v2 = "NA"
        department_visit_customer = "NA"
        CustomCampaignAnalyticLatestDataset = $dataLakeAccountName 
        CustomCampaignCollection = $dataLakeAccountName 
        CustomCampaignSchedules = $dataLakeAccountName 
        CustomWebsiteSocialAnalyticsPBIData = $dataLakeAccountName 
        CustomLocationAnalytics = $dataLakeAccountName 
        CustomCustomerVisitF = $dataLakeAccountName 
        CustomFinanceSales = $dataLakeAccountName 
        CustomEmailAnalytics = $dataLakeAccountName 
        CustomProductLink2 = $dataLakeAccountName 
        CustomProductRecommendations = $dataLakeAccountName 
        CustomSalesMaster = $dataLakeAccountName 
        Department_Visits_DL = $dataLakeAccountName 
        Department_Visits_Predictions_DL = $dataLakeAccountName  
        Product_Recommendations_ML = $dataLakeAccountName  
        Customer_Sales_Latest_ML = $dataLakeAccountName  
        CustomCustomer_SalesLatest = $dataLakeAccountName  
        Customdepartment_visit_customer = $dataLakeAccountName  
}
$dataLakeAccountName 

foreach ($dataset in $datasets.Keys) {
        Write-Information "Creating dataset $($dataset)"
        $result = Create-Dataset -DatasetsPath $datasetsPath -WorkspaceName $workspaceName -Name $dataset -LinkedServiceName $datasets[$dataset]
        Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId
}


Write-Information "Create DataFlow for SAP to HANA Pipeline"
$params = @{
        LOAD_TO_SYNAPSE = "AzureSynapseAnalyticsTable8"
        LOAD_TO_AZURE_SYNAPSE = "AzureSynapseAnalyticsTable9"
        DATA_FROM_SAP_HANA = "DelimitedText1"
}
$workloadDataflows = [ordered]@{
        ingest_data_from_sap_hana_to_azure_synapse = "ingest_data_from_sap_hana_to_azure_synapse"
}

foreach ($dataflow in $workloadDataflows.Keys) {
        Write-Information "Creating dataflow $($workloadDataflows[$dataflow])"
        $result = Create-Dataflow -DataflowPath $dataflowsPath -WorkspaceName $workspaceName -Name $workloadDataflows[$dataflow] -Parameters $params
        Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId
}

Write-Information "Creating Spark notebooks..."

$notebooks = [ordered]@{
        "Activity 05 - Model Training" = "$notebooksPath"
        "Lab 06 - Machine Learning" = "$notebooksPath"
        "Lab 07 - Spark ML" = "$notebooksPath"
        "3 Campaign Analytics Data Prep"    = "$notebooksPath"
        "1 Products Recommendation"   = "$notebooksPath"
        "2 AutoML Number of Customer Visit to Department" = "$notebooksPath"
}

$cellParams = [ordered]@{
        "#SQL_POOL_NAME#" = $sqlPoolName
        "#SUBSCRIPTION_ID#" = $subscriptionId
        "#RESOURCE_GROUP_NAME#" = $resourceGroupName
        "#AML_WORKSPACE_NAME#" = $amlWorkspaceName
        "#DATA_LAKE_ACCOUNT_NAME#" = $dataLakeAccountName
        "#DATA_LAKE_NAME#" = $dataLakeAccountName
        "#DATA_LAKE_ACCOUNT_KEY#" = $dataLakeAccountKey
}

foreach ($notebookName in $notebooks.Keys) {

        $notebookFileName = "$($notebooks[$notebookName])\$($notebookName).ipynb"
        Write-Information "Creating notebook $($notebookName) from $($notebookFileName)"
        
        $result = Create-SparkNotebook -TemplatesPath $templatesPath -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName `
                -WorkspaceName $workspaceName -SparkPoolName $sparkPoolName -Name $notebookName -NotebookFileName $notebookFileName -CellParams $cellParams
        $result = Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId
        $result
}

#these have to run after datasetsa and notebook creation!!!
Write-Information "Create pipelines"

$pipelineList = New-Object System.Collections.ArrayList
$temp = "" | select-object @{Name = "FileName"; Expression = {"sap_hana_to_adls"}} , @{Name = "Name"; Expression = {"SAP HANA TO ADLS"}}
$pipelineList.Add($temp)
$temp = "" | select-object @{Name = "FileName"; Expression = {"marketing_db_migration"}} , @{Name = "Name"; Expression = {"MarketingDBMigration"}}
$pipelineList.Add($temp)
$temp = "" | select-object @{Name = "FileName"; Expression = {"sales_db_migration"}} , @{Name = "Name"; Expression = {"SalesDBMigration"}}
$pipelineList.Add($temp)
$temp = "" | select-object @{Name = "FileName"; Expression = {"twitter_data_migration"}} , @{Name = "Name"; Expression = {"TwitterDataMigration"}}
$pipelineList.Add($temp)
$temp = "" | select-object @{Name = "FileName"; Expression = {"customize_campaign_analytics"}} , @{Name = "Name"; Expression = {"Customize Campaign Analytics"}}
$pipelineList.Add($temp)
$temp = "" | select-object @{Name = "FileName"; Expression = {"customize_decomposition_tree"}} , @{Name = "Name"; Expression = {"Customize Decomposition Tree"}}
$pipelineList.Add($temp)
$temp = "" | select-object @{Name = "FileName"; Expression = {"customize_location_analytics"}} , @{Name = "Name"; Expression = {"Customize Location Analytics"}}
$pipelineList.Add($temp)
$temp = "" | select-object @{Name = "FileName"; Expression = {"customize_revenue_profitability"}} , @{Name = "Name"; Expression = {"Customize Revenue Profitability"}}
$pipelineList.Add($temp)
$temp = "" | select-object @{Name = "FileName"; Expression = {"ML_Department_Visits_Predictions"}} , @{Name = "Name"; Expression = {"ML Department Visits Predictions"}}
$pipelineList.Add($temp)
$temp = "" | select-object @{Name = "FileName"; Expression = {"ML_Product_Recommendation"}} , @{Name = "Name"; Expression = {"ML Product Recommendation"}}
$pipelineList.Add($temp)
$temp = "" | select-object @{Name = "FileName"; Expression = {"customize_recommendation_insights_ml"}} , @{Name = "Name"; Expression = {"Customize Recommendation Insights ML"}}
$pipelineList.Add($temp)
$temp = "" | select-object @{Name = "FileName"; Expression = {"customize_email_analytics"}} , @{Name = "Name"; Expression = {"Customize EMail Analytics"}}
$pipelineList.Add($temp)
$temp = "" | select-object @{Name = "FileName"; Expression = {"customize_all"}} , @{Name = "Name"; Expression = {"Customize All"}}
$pipelineList.Add($temp)
$temp = "" | select-object @{Name = "FileName"; Expression = {"customize_product_recommendations_ml"}} , @{Name = "Name"; Expression = {"Customize Product Recommendations ML"}}
$pipelineList.Add($temp)
$temp = "" | select-object @{Name = "FileName"; Expression = {"1_master_pipeline"}} , @{Name = "Name"; Expression = {"1 Master Pipeline"}}
$pipelineList.Add($temp)
$temp = "" | select-object @{Name = "FileName"; Expression = {"reset_ml_data"}} , @{Name = "Name"; Expression = {"Reset ML Data"}}
$pipelineList.Add($temp)

foreach ($pipeline in $pipelineList) {
        Write-Information "Creating workload pipeline $($pipeline.Name)"
        $result = Create-Pipeline -PipelinesPath $pipelinesPath -WorkspaceName $workspaceName -Name $pipeline.Name -FileName $pipeline.FileName -Parameters @{
                DATA_LAKE_STORAGE_NAME = $dataLakeAccountName
                DEFAULT_STORAGE = $workspaceName + "-WorkspaceDefaultStorage"
         }

         try
         {
        Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId
        }
        catch
        {
            write-host $_.exception;
        }
}

Write-Information "Create SQL scripts"

$sqlScripts = [ordered]@{
        "8 External Data To Synapse Via Copy Into" = "$sqlScriptsPath\workspace-artifacts"
        "1 SQL Query With Synapse"  = "$sqlScriptsPath\workspace-artifacts"
        "2 JSON Extractor"    = "$sqlScriptsPath\workspace-artifacts"
        "Reset"    = "$sqlScriptsPath\workspace-artifacts"
        "Lab 05 - Exercise 3 - Column Level Security" = "$sqlScriptsPath\workspace-artifacts"
        "Lab 05 - Exercise 3 - Dynamic Data Masking" = "$sqlScriptsPath\workspace-artifacts"
        "Lab 05 - Exercise 3 - Row Level Security" = "$sqlScriptsPath\workspace-artifacts"
        "Activity 03 - Data Warehouse Optimization" = "$sqlScriptsPath\workspace-artifacts"
}

if($Load30Billion -eq 1) {
        $salesRowNumberCount = "30,023,443,487"
} else {
        $salesRowNumberCount = "3,443,487"
}

$params = @{
        STORAGE_ACCOUNT_NAME = $dataLakeAccountName
        SAS_KEY = $destinationSasKey
        ROW_NUMBER_COUNT = $salesRowNumberCount
}

foreach ($sqlScriptName in $sqlScripts.Keys) {
        
        $sqlScriptFileName = "$($sqlScripts[$sqlScriptName])\$($sqlScriptName).sql"
        Write-Information "Creating SQL script $($sqlScriptName) from $($sqlScriptFileName)"
        
        $result = Create-SQLScript -TemplatesPath $templatesPath -WorkspaceName $workspaceName -Name $sqlScriptName -ScriptFileName $sqlScriptFileName -Parameters $params
        $result = Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId
        $result
}

#
# =============== COSMOS DB IMPORT - MUST REMAIN LAST IN SCRIPT !!! ====================
#                         

$download = $true;

#generate new one just in case...
$destinationSasKey = New-AzStorageContainerSASToken -Container "wwi-02" -Context $dataLakeContext -Permission rwdl

if ($download)
{
        Write-Information "Copying sample sales raw data directories from the public data account..."

        $dataDirectories = @{
                profile01 = "wwi-02,wwi-02/online-user-profiles-01/"
                profile02 = "wwi-02,wwi-02/online-user-profiles-02/"
        }

        foreach ($dataDirectory in $dataDirectories.Keys) {

                $vals = $dataDirectories[$dataDirectory].tostring().split(",");

                $source = $publicDataUrl + $vals[1];

                $path = $vals[0];

                $destination = $dataLakeStorageBlobUrl + $path + $destinationSasKey
                Write-Information "Copying directory $($source) to $($destination)"
                & $azCopyCommand copy $source $destination --recursive=true
        }
}

Write-Information "Counting Cosmos DB item in database $($cosmosDbDatabase), container $($cosmosDbContainer)"
$documentCount = Count-CosmosDbDocuments -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -CosmosDbAccountName $cosmosDbAccountName `
                -CosmosDbDatabase $cosmosDbDatabase -CosmosDbContainer $cosmosDbContainer

Write-Information "Found $documentCount in Cosmos DB container $($cosmosDbContainer)"

Install-Module -Name Az.CosmosDB

if ($documentCount -ne 100000) 
{
        # Increase RUs in CosmosDB container
        Write-Information "Increase Cosmos DB container $($cosmosDbContainer) to 10000 RUs"

        $container = Get-AzCosmosDBSqlContainer `
                -ResourceGroupName $resourceGroupName `
                -AccountName $cosmosDbAccountName -DatabaseName $cosmosDbDatabase `
                -Name $cosmosDbContainer

        Update-AzCosmosDBSqlContainer -ResourceGroupName $resourceGroupName `
                -AccountName $cosmosDbAccountName -DatabaseName $cosmosDbDatabase `
                -Name $cosmosDbContainer -Throughput 10000 `
                -PartitionKeyKind $container.Resource.PartitionKey.Kind `
                -PartitionKeyPath $container.Resource.PartitionKey.Paths

        $name = "wwi02_online_user_profiles_01_adal"
        Write-Information "Create dataset $($name)"
        $result = Create-Dataset -DatasetsPath $datasetsPath -WorkspaceName $workspaceName -Name $name -LinkedServiceName $dataLakeAccountName
        Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId

        Write-Information "Create Cosmos DB linked service $($cosmosDbAccountName)"
        $cosmosDbAccountKey = List-CosmosDBKeys -SubscriptionId $subscriptionId -ResourceGroupName $resourceGroupName -Name $cosmosDbAccountName
        $result = Create-CosmosDBLinkedService -TemplatesPath $templatesPath -WorkspaceName $workspaceName -Name $cosmosDbAccountName -Database $cosmosDbDatabase -Key $cosmosDbAccountKey
        Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId

        $name = "customer_profile_cosmosdb"
        Write-Information "Create dataset $($name)"
        $result = Create-Dataset -DatasetsPath $datasetsPath -WorkspaceName $workspaceName -Name $name -LinkedServiceName $cosmosDbAccountName
        Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId

        $name = "Setup - Import User Profile Data into Cosmos DB"
        $fileName = "import_customer_profiles_into_cosmosdb"
        Write-Information "Create pipeline $($name)"
        $result = Create-Pipeline -PipelinesPath $pipelinesPath -WorkspaceName $workspaceName -Name $name -FileName $fileName
        Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId

        Write-Information "Running pipeline $($name)"
        $pipelineRunResult = Run-Pipeline -WorkspaceName $workspaceName -Name $name
        $result = Wait-ForPipelineRun -WorkspaceName $workspaceName -RunId $pipelineRunResult.runId
        $result

        #
        # =============== WAIT HERE FOR PIPELINE TO FINISH - MIGHT TAKE ~45 MINUTES ====================
        #                         
        #                    COPY 100000 records to CosmosDB ==> SELECT VALUE COUNT(1) FROM C
        #

        $name = "Setup - Import User Profile Data into Cosmos DB"
        Write-Information "Delete pipeline $($name)"
        $result = Delete-ASAObject -WorkspaceName $workspaceName -Category "pipelines" -Name $name
        Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId

        $name = "customer_profile_cosmosdb"
        Write-Information "Delete dataset $($name)"
        $result = Delete-ASAObject -WorkspaceName $workspaceName -Category "datasets" -Name $name
        Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId

        $name = "wwi02_online_user_profiles_01_adal"
        Write-Information "Delete dataset $($name)"
        $result = Delete-ASAObject -WorkspaceName $workspaceName -Category "datasets" -Name $name
        Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId

        $name = $cosmosDbAccountName
        Write-Information "Delete linked service $($name)"
        $result = Delete-ASAObject -WorkspaceName $workspaceName -Category "linkedServices" -Name $name
        Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId
}

$container = Get-AzCosmosDBSqlContainer `
        -ResourceGroupName $resourceGroupName `
        -AccountName $cosmosDbAccountName -DatabaseName $cosmosDbDatabase `
        -Name $cosmosDbContainer

Update-AzCosmosDBSqlContainer -ResourceGroupName $resourceGroupName `
        -AccountName $cosmosDbAccountName -DatabaseName $cosmosDbDatabase `
        -Name $cosmosDbContainer -Throughput 400 `
        -PartitionKeyKind $container.Resource.PartitionKey.Kind `
        -PartitionKeyPath $container.Resource.PartitionKey.Paths

Write-Information "Starting PowerBI Artifact Provisioning"

$job = Get-AzStreamAnalyticsJob -ResourceGroupName $resourceGroupName -Name $asaName;
$principalId = (Get-AzADServicePrincipal -DisplayName $asaName).id

#$wsname = "asa-exp-$uniqueId";
$wsId = Get-PowerBiWorkspaceId "$resourceGroupName";

if (!$wsid)
{
    $wsId = New-PowerBIWS $resourceGroupName;
}

Add-PowerBIWorkspaceUser $wsId $principalId "Contributor" "App";

Write-Information "Uploading PowerBI Reports"

$reportList = New-Object System.Collections.ArrayList
$temp = "" | select-object @{Name = "FileName"; Expression = {"1. CDP Vision Demo"}}, 
                                @{Name = "Name"; Expression = {"1-CDP Vision Demo"}}, 
                                @{Name = "PowerBIDataSetId"; Expression = {""}}, 
                                @{Name = "SourceServer"; Expression = {"cdpvisionworkspace.sql.azuresynapse.net"}}, 
                                @{Name = "SourceDatabase"; Expression = {"AzureSynapseDW"}}
$reportList.Add($temp)
$temp = "" | select-object @{Name = "FileName"; Expression = {"2. Billion Rows Demo"}}, 
                                @{Name = "Name"; Expression = {"2-Billion Rows Demo"}}, 
                                @{Name = "PowerBIDataSetId"; Expression = {""}}, 
                                @{Name = "SourceServer"; Expression = {"cdpvisionworkspace.sql.azuresynapse.net"}}, 
                                @{Name = "SourceDatabase"; Expression = {"AzureSynapseDW"}}
$reportList.Add($temp)
$temp = "" | select-object @{Name = "FileName"; Expression = {"Phase2_CDP_Vision_Demo"}}, 
                                @{Name = "Name"; Expression = {"1-Phase2 CDP Vision Demo"}}, 
                                @{Name = "PowerBIDataSetId"; Expression = {""}},
                                @{Name = "SourceServer"; Expression = {"asaexpworkspacewwi543.sql.azuresynapse.net"}}, 
                                @{Name = "SourceDatabase"; Expression = {"SQLPool01"}}
$reportList.Add($temp)
$temp = "" | select-object @{Name = "FileName"; Expression = {"images"}}, 
                                @{Name = "Name"; Expression = {"Dashboard-Images"}}, 
                                @{Name = "PowerBIDataSetId"; Expression = {""}}
$reportList.Add($temp)

$powerBIDataSetConnectionTemplate = Get-Content -Path "$templatesPath/powerbi_dataset_connection.json"
$powerBIName = "asaexppowerbi$($uniqueId)"

foreach ($powerBIReport in $reportList) {

    Write-Information "Uploading $($powerBIReport.Name) Report"

    $i = Get-Item -Path "$reportsPath/$($powerBIReport.FileName).pbix"
    $reportId = Upload-PowerBIReport $wsId $powerBIReport.Name $i.fullname
    #Giving some time to the PowerBI Servic to process the upload.
    Start-Sleep -s 5
    $powerBIReport.PowerBIDataSetId = Get-PowerBIDatasetId $wsid $powerBIReport.Name
}

Write-Information "Create PowerBI linked service $($powerBIName)"

$result = Create-PowerBILinkedService -TemplatesPath $templatesPath -WorkspaceName $workspaceName -Name $powerBIName -WorkspaceId $wsid
Wait-ForOperation -WorkspaceName $workspaceName -OperationId $result.operationId

Refresh-Token -TokenType PowerBI

Write-Information "Setting PowerBI Report Data Connections" 

<# WARNING : Make sure Connection Changes are executed after report uploads are completed. 
             Based on testing so far, findings indicate that there has to be an unknown amount 
             of time between the two operations. Having those operations sequentially run in a 
             single loop resulted in inconsistent results. Pushing the two activities far away 
             from each other in separate loops helped. #>

$powerBIDataSetConnectionUpdateRequest = $powerBIDataSetConnectionTemplate.Replace("#TARGET_SERVER#", "asaexpworkspace$($uniqueId).sql.azuresynapse.net").Replace("#TARGET_DATABASE#", "SQLPool01") |Out-String

foreach ($powerBIReport in $reportList) {
        if($powerBIReport.Name -ne "Dashboard-Images")
        {
                Write-Information "Setting database connection for $($powerBIReport.Name)"
                $powerBIReportDataSetConnectionUpdateRequest = $powerBIDataSetConnectionUpdateRequest.Replace("#SOURCE_SERVER#", $powerBIReport.SourceServer).Replace("#SOURCE_DATABASE#", $powerBIReport.SourceDatabase) |Out-String
                Update-PowerBIDatasetConnection $wsId $powerBIReport.PowerBIDataSetId $powerBIReportDataSetConnectionUpdateRequest;
        }
}
