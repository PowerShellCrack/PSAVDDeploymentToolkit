# Change log for AVDToolkitToolkit

## 1.1.3 Aug 29, 2023

- Moved 7Zip cmdlets to a seperate file; calls when needed; updated dependencies
- Fixe M365 part extraction. Move extracted files that may be in an additional folder to one level up

## 1.1.2 Aug 28, 2023

- Changed aib.json to sequence.json; account Intune app management sequence
- Fixed App upload for multiple parts; checks if part exists
- Increased app downloads from blob using azcopy instead of webrequest.
- Fixed Azure VM invoke-runcommand output; had null errors

## 1.1.1 Aug 16, 2023

- Added to Application.json to support multiple versions of teams
- fixed version check logic; an issue exist when no version exist in EXE (eg. Azcopy.exe)
- Added Get-7zipUtilities function; not needed yet

## 1.1.0 Aug 14, 2023

- Updated powershell scripts naming. Updates readme to reflect that
- Fixed download application logic to process multiple files.
- Added ApplicationsOverrideFile parameter to ensure only updates apps exist and not older.
- fixed some errors with sastoken processing in azure prep script
- removed offline module control; no needed.
- removed detection rule from application.json
- added zone fix for downloading apps from network; added unblock-file to fix warning message

## 1.0.2 July 14, 2023

- Added split compression support for large applications
- Added upload to Azure blob support for large applications

## 1.0.1 June 16, 2023

- Added diagram images to readme
- Build intuneapp builder script. Not working
- Added detection rule to Application.json

## 1.0.0 June 13, 2023

- Uploaded initial. Code originated from https://github.com/PowerShellCrack/PSAIBDeploymentToolkit