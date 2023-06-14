param(
    [string]$EnvironmentSettings
)

# Add AZ PS modules to support AzUserAssignedIdentity and Az AIB
Import-Module 'Az.Accounts','Az.ImageBuilder', 'Az.ManagedServiceIdentity'

#=======================================================
# CONNECT TO AZURE
#=======================================================
Connect-AzAccount -Environment AzureUSGovernment
Set-AzContext -Subscription $SubscriptionName

# Step 2: get existing context
$currentAzContext = Get-AzContext
# your subscription, this will get your current subscription
$subscriptionID=$currentAzContext.Subscription.Id

#Requires -Modules Az.Accounts,Az.Resources,Az.Network
Set-Item Env:\SuppressAzurePowerShellBreakingChangeWarnings "true" | Out-Null
