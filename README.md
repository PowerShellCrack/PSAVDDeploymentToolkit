# A toolkit to build azure images with applications "offline"

This toolkit originated from the [PSAIBDeploymentToolkit](https://github.com/PowerShellCrack/PSAIBDeploymentToolkit). I am also developing that, however I needed to develop a way to manage applications in an "offline" manor. This Toolkit does not use AIB instead it uses scripts that build images using the remote Powershell command invoked in a Azure VM. This can support both Azure IL5 and IL6.

The structure is similar to MDT's and each defined "sequenced" process is within the _Control_ folder and each "sequence" contains a **sequence.json** file. This file is not a schema that follows the Azure Image builder schema, however with this file in conjunction with a basic template file (within the _Template_ folder), the _Applications\applications.json_ will **build and capture** a reference image for AVD consumption.

> NOTE: I am working to merge this toolkit with my AIB toolkit allowing it to support both methods.

## Prereqs

- Azure Subscriptions
- Virtual network for reference image
- The rest can be built using _1_prep_azureenv.ps1_ script

## The Process

To support multiple environment and applications offline, these applications must be downloaded and staged in blob prior to running the image process. This process is not 100% automated at the moment and does require PowerShell scripts to run each **month**.

### Toolkit folders structure

```ascii
AVDDeploymentToolkit
    |-Applications
        |--fslogix
        |--lgpo
        |--office365
        |--onedrive
        |--teams
        |--etc...
    |-Control
        |--Win10AvdImage
            |---sequence.json
        |--Win11AvdImage
            |---sequence.json
    |-Scripts
        |--supporting scripts
        |--VM
            |--sequence scripts
    |-Templates
        |--json files
        |--template scripts*
    |-Tools
        |--7za.exe
        |--7za.dll
    |-Logs
        |--transaction logs for each script ran
```

## Scripts

Filename | Explanation | Access Requirements | Run Example | Recommended Cadence| Notes
--|--|--|--|--|--
1_prep_azureenv.ps1|Sets up azure environment to support this toolkit and AIB| must have tenant access and Global Admin|```PS .\1_prep_azureenv.ps1  -ControlSettings setting.gov.json```|Monthly for sastoken renewal.| Sastoken can be generated manually if preferred (paste token in _settings.json_)
2_download_applications.ps1|Downloads applications and zips them up| must have internet access|```PS .\2_download_applications.ps1 -ControlSettings setting.gov.json -CompressForUpload```| Monthly |Can be ran on a internet device and files transferred to a tenant connect device from a media
3_upload_to_azureblob.ps1|Uploads archived applications to blob using sastoken| must have network access to blob storage|```PS .\3_upload_to_azureblob.ps1  -ControlSettings setting.gov.json```| Monthly
4A_create_avd_ref_vm.ps1|Create Azure VM and runs prep script to install applications| must have tenant access and compute contributor role|```PS .\4A_create_avd_ref_vm.ps1 -ControlSettings setting.gov.json -Sequence Win11AvdGFEImage```| Monthly
5A_capture_vm_image_invokeposh.ps1|Sets up azure environment to support this toolkit and AIB| must have tenant access and compute contributor role|```PS .\5A_capture_vm_image_invokeposh.ps1 -ControlSettings setting.gov.test.json -ForceNewSasToken -Sequence Win11AvdGFEImage -VMName TEST-2306-REF -CleanUpVMOnCaptureSuccess```| Monthly |

>TIP: Each of these script has a dependency on at least one json file included in the toolkit.

## How to get started

1. Download repo
1. Edit the applications.json (or leave it be). See _application.json breakdown_ below
1. Copy TemplateImage folders in Control folder and name it to your image needs (or edit the existing ones)
1. Edit the sequence.json for the applications,scripts you want to install
    - See _sequence.json breakdown_ below
    - Edit all entries with arrows '\<\>' and choose an option with the pipe '\|'
1. Copy the settings.example.json and make new file.
    - Edit all entries with arrows '\<\>' and choose an option with the pipe '\|'
1. Run each script in order using the params (like in the examples)

### the workflow

>NOTE: Images may not reflect script names

![step1](/.images/a1_prep_azureenv.jpg)

![step2](/.images/a2_download_applications.jpg)

![step3](/.images/a3_upload_to_azureblob.jpg)

![step4](/.images/a4_create_avd_ref.jpg)

![step5](/.images/a5_create_vm_image.jpg)

## **application.json** breakdown

This is file contains a list applications and the method for downloading them and installing them

Supported parameters are:

- **enabled** – boolean. enables or disables this step entirely
- **download** – boolean. enables or disables the download step
- **appId** – guid. Use _New-Guid_ to get a guid,
- **productName** – string. Name of product (use what shows up in appwiz.cpl)
- **version** – string. Version of product (set to "latest") for latest download
- **localPath** – string. Path of where application will downloaded to
- **fileName** – string. The name of the file to be downloaded or executed
- **downloadURI** – url. the official url where files can be downloaded from
- **downloadUriType** – string. can be either webrequest, shortlink, shortlinkextract, linkId, or linkIdExtract. Used to determine the method of download
- **preDownloadScript** – string or array of strings. This is sequential. Each line will run in powershell before download starts. Typically used to get versions or release url
- **postDownloadScript** – string or array of strings. This is sequential. Each line will run in powershell after download is complete. Typically used to cleanup additional files or extract archive
- **installArguments** – string. the arguments used to install the application silently
- **preInstallScript** – string or array of strings. This is sequential. Each line will run in powershell before install starts. Typically used to setup dependencies.
- **postInstallScript** – string or array of strings. This is sequential. Each line will run in powershell after application is installed. Typically used to configure post settings for applications

### Example 1

```json
 [
    {
        "download": "false",
        "appId": "4f86a38b-0a06-4d08-94a0-aaeecb9c359f",
        "productName" : "Git For Windows",
        "version" : "[version]",
        "localPath" : "[ApplicationsPath]\\Git",
        "fileName": "Git-installer-x64.exe",
        "preDownloadScript": [
            "$releaseURI = Invoke-WebRequest \"https://github.com/git-for-windows/git/releases/latest\" -Headers @{\"Accept\" = \"application/json\" } -UseBasicParsing",
            "$json = $releaseURI.Content | ConvertFrom-Json",
            "$release = $json.tag_name",
            "$versionURI = Invoke-WebRequest \"https://github.com/git-for-windows/git/releases/tag/[release]\" -UseBasicParsing",
            "[xml]$xml = $versionURI | Select-String '(?s)(<table>.+?</table>)' | ForEach-Object { $_.Matches[0].Groups[1].Value }",
            "$hashtable = $xml.table.tbody.tr | ForEach-Object { [PSCustomObject]@{File = $_.td[0];Hash = $_.td[1] }}",
            "$version = $hashtable | Where file -like \"*64-bit.exe\" | Select -ExpandProperty file"
        ],
        "downloadURI" : "https://github.com/git-for-windows/git/releases/download/[release]/[version]",
        "downloadUriType" : "webrequest",
        "installArguments": "/VERYSILENT /NORESTART /COMPONENTS=\"ext,ext\\shellhere,ext\\guihere,gitlfs,assoc,assoc_sh\" /LOG"
    },
]
```

### Example 2

```json
 [
    {
        "download": "true",
        "appId": "73d9d3c6-0041-48dc-9866-55b6c1f2af33",
        "productName" : "Microsoft 365 Apps for enterprise - en-us",
        "version" : "latest",
        "localPath" : "[ApplicationsPath]\\M365",
        "fileName": "setup.exe",
        "downloadURI" : "https://www.microsoft.com/en-us/download/details.aspx?id=49117",
        "downloadUriType" : "linkIdExtract",
        "postDownloadScript": [
            "Remove-Item [localPath] -Recurse -Include *.xml -Force -ErrorAction SilentlyContinue | Out-Null",
            "Push-Location [localPath]",
            "$xml = @()",
            "$xml += '<Configuration>'",
            "$xml += '<Add OfficeClientEdition=\"64\" Channel=\"MonthlyEnterprise\">'",
            "$xml += '<Product ID=\"O365ProPlusRetail\">'",
            "$xml += '<Language ID=\"en-US\" />'",
            "$xml += '<Language ID=\"MatchOS\" />'",
            "$xml += '<ExcludeApp ID=\"Groove\" />'",
            "$xml += '<ExcludeApp ID=\"Lync\" />'",
            "$xml += '<ExcludeApp ID=\"OneDrive\" />'",
            "$xml += '<ExcludeApp ID=\"Teams\" />'",
            "$xml += '</Product>'",
            "$xml += '</Add>'",
            "$xml += '<Updates Enabled=\"FALSE\"/>'",
            "$xml += '<Display Level=\"None\" AcceptEULA=\"TRUE\" />'",
            "$xml += '<Property Name=\"FORCEAPPSHUTDOWN\" Value=\"TRUE\"/>'",
            "$xml += '<Property Name=\"SharedComputerLicensing\" Value=\"1\"/>'",
            "$xml += '</Configuration>'",
            "$xml | Out-file -FilePath \"[localPath]\\configuration.xml\"",
            "[outputPath] /download \"[localPath]\\configuration.xml\"",
            "$version = (Get-ChildItem -Path \"[localPath]\" -Recurse -Directory | Where BaseName -match \"\\d+(\\.\\d+){1,3}\").BaseName",
            "Pop-Location"
        ],
        "installArguments": "/configure \"[localPath]\\configuration.xml\""
    },
]
```

## **settings-\<org>.json** breakdown

This file should be located under the _Control_ folder.

- **Settings** – Specify paths and modules needed for toolkit to work
- **TenantEnvironment** – Used for tenant connection with Azure modules
- **AzureResources** – Resources need to manage the image build process. Some key ones to focus on
  - **storageAccount** – used during the application upload and download steps. Specify the storage account used
    - **storageContainer** – used during the application upload and download steps. Specify the container used
    - **containerSasToken** – used during the application upload and download steps. Can be autogenerated using script _A1_prep_azureenv.ps1_. Can use stored in keyvault
    - **keyVault** – Specify the keyvault to use or create
    > **Note** Some value can use \[Keyvault\]; this will securely store the values in keyvault during the process and use it throughout the process
- **AvdResources** – NOT USED YET
- **ManagedIdentity** – specified to appropiate assign roles to AIB
- **LogAnalytics** – Not used at the moment. Intended for sending build status to log analytics for viewing

### sequence.json file breakdown

This file should exist in each type of _sequence_ folder under _Control_. It determines what actions are done on the VM.

- **customSettings** – section is where the global settings will be.
- **customSequence** – section is used to specify each step the script will run through. Once the customSequence is complete the cleanup action and final action (from customSettings section) are ran
- **Template** – section is used for AIB process
- **imageDefinition** – section is used to build the reference image and provide the name of the image image in the gallery

There are three types of steps that can be ran during the customSequence: **Applications**, **Scripts**, and **Windows Updates**:

## Type: **Applications**

Supported parameters are:

- **enabled** – boolean. enables or disables the step in the csutomizations
- **type** – string. Set to "Application"
- **name** – string. Name of step
- **id** – guid. **Must match** that of the _application.json_ corresponding list,
- **workingDirectory** – string. Path of where application will installed from
- **validExitCodes** – array of integers. typically set to [0,3010]
- **continueOnError** – boolean. enables allows script to run even if do does not match the validExitCode
- **validateInstalled** – boolean. enables validates the application is installed using the application name
- **rebootOnSuccess** – boolean. Reboots the system after install. this will break the script from continuing. DON'T USE YET

### Example 1

```json
"customSequence":  [
        {
            "enabled": "true",
            "type": "Application",
            "name" : "Install FSLogix",
            "id": "5c97799b-78a8-466f-82e3-99bb04797fb1",
            "workingDirectory": "[localPath]\\FSlogix",
            "validExitCodes": [0,3010],
            "continueOnError": "true",
            "validateInstalled": "true",
            "rebootOnSuccess": "false"
        }
    ]
```

## Type: **Scripts**

Supported parameters are:

- **enabled** – boolean. enables or disables the step in the customizations
- **type** – string. Set to "Script"
- **name** – string. Name of step
- **id** – guid. can be anything. Not used
- **inlineScript** – string or array of strings. This is sequential. Each line will run in powershell
- **validExitCodes** – array of integers. typically set to [0,3010]
- **continueOnError** – boolean. enables allows script to run even if do does not match the validExitCode
- **rebootOnSuccess** – boolean. Reboots the system after script is ran. this will break the script from continuing. DON'T USE YET

### Example 1

```json
"customize":  [
      {
        "enabled": "true",
        "type": "Script",
        "name" : "Setup CMtrace",
        "id": "693c894c-58c4-4572-b5f0-fc86e40186f3",
        "inlineScript": [
            "Copy-Item -Path \"`[ToolsPath]\\CMTrace.exe\" -Destination \"$env:Windir\\System32\" -Force -ErrorAction Stop",
            "New-Item -Path 'HKLM:\\Software\\Classes\\.lo_' -type Directory -Force -ErrorAction SilentlyContinue | Out-Null",
            "New-Item -Path 'HKLM:\\Software\\Classes\\.log' -type Directory -Force -ErrorAction SilentlyContinue | Out-Null",
            "New-Item -Path 'HKLM:\\Software\\Classes\\.log.File' -type Directory -Force -ErrorAction SilentlyContinue | Out-Null",
            "New-Item -Path 'HKLM:\\Software\\Classes\\.Log.File\\shell' -type Directory -Force -ErrorAction SilentlyContinue | Out-Null",
            "New-Item -Path 'HKLM:\\Software\\Classes\\Log.File\\shell\\Open' -type Directory -Force -ErrorAction SilentlyContinue | Out-Null",
            "New-Item -Path 'HKLM:\\Software\\Classes\\Log.File\\shell\\Open\\Command' -type Directory -Force -ErrorAction SilentlyContinue | Out-Null",
            "New-Item -Path 'HKLM:\\Software\\Microsoft\\Trace32' -type Directory -Force -ErrorAction SilentlyContinue | Out-Null",
            "New-ItemProperty -LiteralPath 'HKLM:\\Software\\Classes\\.lo_' -Name '(default)' -Value 'Log.File' -PropertyType String -Force -ea SilentlyContinue | Out-Null",
            "New-ItemProperty -LiteralPath 'HKLM:\\Software\\Classes\\.log' -Name '(default)' -Value 'Log.File' -PropertyType String -Force -ea SilentlyContinue | Out-Null",
            "New-ItemProperty -LiteralPath 'HKLM:\\Software\\Classes\\Log.File\\shell\\open\\command' -Name '(default)' -Value  '$env:Windir\\System32\\CMTrace.exe \"\"%1\"\"' -PropertyType String -Force -ea SilentlyContinue | Out-Null",
            "New-Item -Path 'HKLM:\\SOFTWARE\\Microsoft\\Active Setup\\Installed Components\\CMtrace' -type Directory -Force | Out-Null",
            "New-ItemProperty 'HKLM:\\SOFTWARE\\Microsoft\\Active Setup\\Installed Components\\CMtrace' -Name 'Version' -Value 1 -PropertyType String -Force | Out-Null",
            "New-ItemProperty 'HKLM:\\SOFTWARE\\Microsoft\\Active Setup\\Installed Components\\CMtrace' -Name 'StubPath' -Value \"reg.exe add HKCU\\Software\\Microsoft\\Trace32 /v 'Register File Types' /d 0 /f\" -PropertyType ExpandString -Force | Out-Null"
        ],
        "continueOnError": "true",
        "rebootOnSuccess": "false"
        }
  ],
```

## Type: **WindowsUpdate**

Supported parameters are:

- **enabled** – boolean. enables or disables the step in the customizations
- **type** – string. Set to "WindowsUpdate"
- **name** – string. Name of step
- **id** – guid. can be anything. Not used
- **preUpdateScript** – string or array of strings. This is sequential. Each line will run in powershell before updates start
- **postUpdateScript** – string or array of strings. This is sequential. Each line will run in powershell after updates are installed
- **restartTimeout** – integer. typically set to 0
- **continueOnError** – boolean. enables allows script to run even if do does not match the validExitCode
- **rebootOnSuccess** – boolean. Reboots the system after script is ran. this will break the script from continuing. DON'T USE YET

### Example 1

```json
"customize":  [
      {
            "enabled": "true",
            "type": "WindowsUpdate",
            "name" : "Install Windows Update",
            "id": "03fc164d-a1cd-4ba3-aa60-249f39a5fff7",
            "restartTimeout": "0",
            "continueOnError": "true",
            "rebootOnSuccess": "false"
      }
  ],
```

## Dynamic variable support

As each json object is processed, the scripts are looking for bracketed values to convert to variables. This allows to the script to be more dynamic.

### Example 1

If the script already has a variable _$localpath = "c:\windows\temp\apps"_ the script will look for any property using _\[localPath\]_ and replace it with _"c:\windows\temp\apps"_.

### Example 2

Since the json has _key:value_ properties in it such as: ```"filename":"setup.exe"```; during the process, if the script sees a bracketed value of _\[filename\]_ it will be replaced with _"setup.exe"_

## Security concerns

- Storage account has public access but to certain virtual networks
- Container must be anonymous access with SASTokens

## TODOs

- Build process to use Azure Key vault with rotating storage keys
- Use Azure Automation with Managed Identities
- Develop a MDT-like User Interface to allow easier configurations or use MDT then convert for AIB to consume
- Build language pack support using the _Packages_ folder (https://docs.microsoft.com/en-us/azure/virtual-desktop/language-packs)
- Develop a method to document definition version (eg after each build using custom table in log analytics to store output)
- Azure Image Version cleanup
- Azure Virtual Machine host cycle

## contributing

If you are contributing, testing or using the code. Please create a copy of the _Settings.json_ file in control folder and name it something like _Settings-\<user\>\.json_. (keep the **Settings-** in the filename); this file will be ignored during pull request.
> You don't want your secrets to be public.

## Output

There is a _Logs_ folder that will contain a dated transcript of the AIB sequence called and the json arm template is generated there for reference.

## Known Issues

- Please submit issues for me to track

## References

- https://github.com/danielsollondon/azvmimagebuilder/tree/master/quickquickstarts/0_Creating_a_Custom_Windows_Managed_Image
- https://docs.microsoft.com/en-us/azure/virtual-machines/linux/image-builder-json?tabs=azure-powershell
- https://docs.microsoft.com/en-us/azure/virtual-desktop/set-up-customize-master-image
- https://docs.microsoft.com/en-us/azure/virtual-desktop/set-up-golden-image
- https://docs.microsoft.com/en-us/azure/virtual-machines/windows/image-builder-powershell

## DISCLAIMER

> Even though I have tested this to the extend that I could, I want to ensure your aware of Microsoft’s position on developing custom scripts.

This Sample Code is provided for the purpose of illustration only and is not intended to be used in a production environment.  THIS SAMPLE CODE AND ANY RELATED INFORMATION ARE PROVIDED "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER EXPRESSED OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE IMPLIED WARRANTIES OF MERCHANTABILITY AND/OR FITNESS FOR A PARTICULAR PURPOSE.  We grant You a nonexclusive, royalty-free right to use and modify the Sample Code and to reproduce and distribute the object code form of the Sample Code, provided that You agree: (i) to not use Our name, logo, or trademarks to market Your software product in which the Sample Code is embedded; (ii) to include a valid copyright notice on Your software product in which the Sample Code is embedded; and (iii) to indemnify, hold harmless, and defend Us and Our suppliers from and against any claims or lawsuits, including attorneys’ fees, that arise or result from the use or distribution of the Sample Code.

This posting is provided "AS IS" with no warranties, and confers no rights. Use of included script samples are subject to the terms specified
at <https://www.microsoft.com/en-us/legal/copyright>.
