<#
NAME: SymantecFix3.0.ps1
DEFINITON: Fix symantec out of date definitions
DATE MODIFIED: 1/03/2018
AUTHOR: Austin Vargason
#>


#initiate script function, aka main
Function Initiate-SymantecRepair
{
     <#  
        .SYNOPSIS
            Initiate-SymantecRepair repairs SEP 12 clients from a SEP Manager definitions export spreadsheet

        .DESCRIPTION
            Initiate-SymantecRepair takes a spreadsheet of assets with SEP information and then pings each asset using Test-ComputerConnection.
            The online assets are shown in an out-gridview window to select which assets to repair. A repair is then carried out on the selected
            assets after the definitions date is verified as "out of date". Symantec is repaired by deleting virus definitions and registry entries.
            The SEP service is then restarted and a repair is done via MSIEXEC. The repair is finished by a forced heartbeat to the Symantec Server.

        .PARAMETER Path
            The name or path to the asset spreadsheet. The spreadsheet should be obtained via out of date email report.

        .EXAMPLE
            Initiate-SymantecRepair -Path ProblemSystems.csv

            Conducts Symantec repair on assets from spreadsheet

    #>
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true)]
        [String]$Path
    )
    
    Begin
    {

        #function to ping systems quickly, returns resultArray
        Function Test-ComputerConnection 
        {
            <#  
                .SYNOPSIS
                    Test-ComputerConnection sends a ping to the specified computer or IP Address specified in the ComputerName parameter.

                .DESCRIPTION
                    Test-ComputerConnection sends a ping to the specified computer or IP Address specified in the ComputerName parameter. Leverages the System.Net object for ping
                    and measures out multiple seconds faster than Test-Connection -Count 1 -Quiet.

                .PARAMETER ComputerName
                    The name or IP Address of the computer to ping.

                .EXAMPLE
                    Test-ComputerConnection -ComputerName "THATPC"

                    Tests if THATPC is online and returns a custom object to the pipeline.

                .EXAMPLE
                    $MachineState = Import-CSV .\computers.csv | Test-ComputerConnection -Verbose

                    Test each computer listed under a header of ComputerName, MachineName, CN, or Device Name in computers.csv and
                    and stores the results in the $MachineState variable.

            #>
            [CmdletBinding()]
            param
            (
                [Parameter(Mandatory=$True,
                ValueFromPipeline=$True, ValueFromPipelinebyPropertyName=$true)]
                [alias("CN","MachineName","Device Name")]
                [string[]]$arrayComputers   
            )


            Begin
            {
                [int]$timeout = 20
                [switch]$resolve = $true
                [int]$TTL = 128
                [switch]$DontFragment = $false
                [int]$buffersize = 32
                $options = new-object system.net.networkinformation.pingoptions
                $options.TTL = $TTL
                $options.DontFragment = $DontFragment
                $buffer=([system.text.encoding]::ASCII).getbytes("a"*$buffersize)   
            }
            Process
            {       
                $ResultArray = @();
                $i = 0;
        
                foreach ($ComputerName in $arrayComputers)
                {
                    $ping = new-object system.net.networkinformation.ping
                    try
                    {
                        $reply = $ping.Send($ComputerName,$timeout,$buffer,$options)    
                    }
                    catch
                    {
                        $ErrorMessage = $_.Exception.Message
                    }
                    if ($reply.status -eq "Success")
                    {
                        $props = @{ComputerName=$ComputerName
                                    Online=$True
                        }
                    }
                    else
                    {
                        $props = @{ComputerName=$ComputerName
                                    Online=$False           
                        }
                    }
        
                    $object = New-Object -TypeName PSObject -Property $props

                    $ResultArray += $object
                    $i++

                    Write-Progress -Activity "Pinging Computers" -Status "Done Pinging: $ComputerName" -PercentComplete ( ($i / $arrayComputers.Length) * 100)

                }

                Write-Progress -Activity "Pinging Computers" -Status "Ready" -Completed

                return $ResultArray
        
            }
            End
            {
            }

        }     

        #function to ping systems, accepts a filepath for a csv, return ping status
        Function Get-OnlineAssets
        {
            param
            (
                [Parameter(Mandatory=$true)]
                [String]$Path
            )

            #declare variables
            $csv = Import-Csv -Path $Path
            $computerNames = $csv| Select -ExpandProperty System
  
            $pingStatus = Test-ComputerConnection -arrayComputers $computerNames

            $pingStatus = $pingStatus| Where {$_.Online -eq $true}| Select ComputerName, Online

            $ResultArray = @()

            foreach ($asset in $pingStatus.ComputerName)
            {
                $definitionDate = $csv|Where {$_.System -eq $asset}| Select -ExpandProperty Definitions
                $properties = 
                @{
                    "ComputerName"=$asset;
                    "DefinitionDate"=$definitionDate
                }
        
                $object = New-Object -TypeName PsObject -Property $properties

                $ResultArray += $object

            }

            return $ResultArray

        }

        #function to choose repair assets from out-gridview
        function Choose-RepairAssets
        {
        
            param
            (
            [Parameter(Mandatory=$true)]
            [String]$Path
            )

            $onlineAssets = Get-OnlineAssets -Path $Path

            $repairAssets = $onlineAssets| Out-GridView -Title "Online Assets" -PassThru

            $repairAssets = $repairAssets| Select -ExpandProperty ComputerName

            return $repairAssets
    
        }

        #repair function
        function Fix-Symantec () 
        {

            param
            (
               [Parameter(Mandatory=$true)]
               [String[]]$assetList,
               [Parameter(Mandatory=$true)]
               [bool[]]$Confirm
             )

            $content = $assetList

            #nested functions

            #function to remove virus definitions
    	    Function RemoveVirusDefs ()
    	    {
    		    Write-Host -ForegroundColor Cyan "Deleting Virus Defintions...."
    		    Get-ChildItem -Path "\\$computer\C$\ProgramData\Symantec\Symantec Endpoint Protection\CurrentVersion\Data\Definitions\VirusDefs" -Recurse -Force -ErrorAction silentlycontinue|
    		    Remove-Item -Force -Verbose -Recurse -ErrorAction silentlycontinue;
    		    Write-Host -ForegroundColor Cyan "Virus Definitions Deleted"
    		    Sleep -Seconds 10;
    		    Write-Host -ForegroundColor Cyan "Deleting Registry Values...";
    		    REG DELETE "\\$computer\HKLM\Software\Symantec\Symantec Endpoint Protection\CurrentVersion\SharedDefs" /va /f;
    		    Write-Host -ForegroundColor Cyan "Registry Values Deleted";
            }

            #function to stop Symantec-Service
            Function Stop-SymantecService ()
            {
                    param
                    (
                        [Parameter(Mandatory=$true)]
                        [String]$Path,
                        [Parameter(Mandatory=$true)]
                        [String]$ComputerName
                    )

                    Write-Host -ForegroundColor Cyan "Stopping Symantec Service"    
    			    .\psexec.exe \\$ComputerName -h -s -i "$Path" -stop;
    			    Write-Host -ForegroundColor Cyan "Symantec Service Stopped"
    			    Sleep -Seconds 10;
            }

            #function to start Symantec Service
            Function Start-SymantecService ()
            {
                    param
                    (
                        [Parameter(Mandatory=$true)]
                        [String]$Path,
                        [Parameter(Mandatory=$true)]
                        [String]$ComputerName
                    )

                    Write-Host -ForegroundColor Cyan "Starting Symantec Service"    
    			    .\psexec.exe \\$ComputerName -h -s -i "$Path" -start;
    			    Write-Host -ForegroundColor Cyan "Symantec Service Started"
    			    Sleep -Seconds 10;
            }

            #function to update config
            Function Update-Config
            {
                    param
                    (
                        [Parameter(Mandatory=$true)]
                        [String]$Path,
                        [Parameter(Mandatory=$true)]
                        [String]$ComputerName
                    )

                    Write-Host -ForegroundColor Cyan "Updating Config..."
    			    .\psexec.exe \\$ComputerName -h -s "$Path" -updateconfig;
    			    Write-Host -ForegroundColor Cyan "Config Updated"
            }


            #restart symantec function
            Function Restart-Symantec
            {
                    param
                    (
                        [Parameter(Mandatory=$true)]
                        [String]$Path,
                        [Parameter(Mandatory=$true)]
                        [String]$ComputerName
                    )

                    Write-Host -ForegroundColor Cyan "restarting service"
    			    .\psexec.exe \\$ComputerName -h -s -i "$Path" -stop;
    			    Sleep -Seconds 10;
    			    .\psexec.exe \\$ComputerName -h -s -i "$Path" -start;
    			    Sleep -Seconds 10;
    			    Write-Host -ForegroundColor Cyan "Service Restarted";
    			    .\psexec.exe \\$ComputerName -h -s "$Path" -updateconfig;
    			    Write-Host -ForegroundColor Cyan "Config Updated";

            }

            #Function used to repair
            Function Invoke-SymantecRepair
            {
                        param
                        (
                            [Parameter(Mandatory=$true)]
                            [String]$ComputerName,
                            [Parameter(Mandatory=$true)]
                            [String]$msiPath,
                            [Parameter(Mandatory=$true)]
                            [String]$SMCPath

                        )
                        #shutdown Gui if open				
    			        If (Get-Process -ComputerName $computer| WHERE {$_.ProcessName -eq "SymCorpUI"})
    			        {
    				        .\psexec.exe \\$ComputerName -h -s -i "$SMCPath" -dismissgui;
    				        Sleep -Seconds 10
    			        }
    			

                        #stop symantec service
    		            Stop-SymantecService -Path $SMCPath -ComputerName $ComputerName

                        #Remove virus defs
    			        RemoveVirusDefs

    	                #Start Symantec Service and update the config
                        Start-SymantecService -Path $SMCPath -ComputerName $ComputerName
                        Update-Config -Path $SMCPath -ComputerName $ComputerName
    			
                        #run msi repair
                        Write-Host -ForegroundColor Cyan "Repairing SEP via MSIEXEC"
                        Invoke-Command -ComputerName $ComputerName -ScriptBlock {param($msiPathLoc) cmd /c MSIEXEC.exe /quiet /norestart /f $msiPathLoc} -ArgumentList $msiPath
                        Write-Host -ForegroundColor Cyan "Repair Completed"

                        #restart Symantec Service and update config
                        Restart-Symantec -Path $SMCPath -ComputerName $ComputerName
    			        Update-Config -Path $SMCPath -ComputerName $ComputerName

    			
    			        Write-Host -ForegroundColor Cyan "continuing"
              }

            Function Check-DefintionDate
            {
                    param
                    (
                        [Parameter(Mandatory=$true)]
                        [String]$ComputerName

                    )

                    $3daysago = (Get-Date).AddDays(-3)
                    Try 
                    {
                        $Reg = [Microsoft.Win32.RegistryKey]::OpenRemoteBaseKey('LocalMachine', $computer)
    		            $RegKey= $Reg.OpenSubKey("SOFTWARE\\Wow6432Node\\Symantec\\Symantec Endpoint Protection\\CurrentVersion\\SharedDefs")
    		            $path = $RegKey.GetValue("DEFWATCH_10")
                    }
                    catch
                    {
                        write-host "could not open remote base key for $ComputerName"
                    }



                    #check if remote path is null
                    if ($path -ne $null)
                    {
                        $remotepath = $path.Replace("C:","\\" + $computer + "\C$")
                        $writetime = [datetime](Get-ItemProperty -path $remotepath -Name LastWriteTime).lastwritetime
                    }
                    else
                    {
    		            $writetime = " NULL "
                    }
    		
    		        If ($writetime -gt $3daysago -and $writetime -ne " NULL ")
    		        {
    			        Write-Host -ForegroundColor Cyan "The Definitions are current for asset: $computer";
    			        Write-Host -ForegroundColor Cyan "WriteTime = $writetime";
    			        $OutofDate = $false
    		        }

    		        Elseif ($writetime -lt $3daysago -and $writetime -ne " NULL ")
    		        {
    			        Write-Host -ForegroundColor Cyan "The Definitions for asset: $computer are out of date";
    			        Write-Host -ForegroundColor Cyan "WriteTime = $writetime";
    			        $OutofDate = $true
    		        }

                    else
                    {
                        Write-Host -ForegroundColor Yellow "Could not get definitions date for $ComputerName" -BackgroundColor Black
                        $OutofDate = $null
                    }

                    return $OutofDate;
             }
      
            ForEach ($c in $content)
            {
    
    	        $computer = $c

    	        #conditional statements

                #quickly chek if asset is still online
    	        If (Test-ComputerConnection -arrayComputers $computer -ErrorAction SilentlyContinue)
    	        {
                    $OutofDate = Check-DefintionDate -ComputerName $computer

                    #Repair if out of date
    	            If ($OutofDate -eq $true)
    	            {
    	                    #Save the current location
    			            Push-Location;
                
                            #Write to the Console
                            Write-Host -ForegroundColor Cyan "Repairing Symantec Definitions"

    
                            #install location
    			            $inst = "C:\Program Files (x86)\Symantec\Symantec Endpoint Protection\Smc.exe"

                            #get msi location
    			            $msi = Get-ChildItem -Path "\\$computer\C$\ProgramData\Symantec\Symantec Endpoint Protection\CurrentVersion\Data\Cached Installs\"|
    			            Where-Object {$_.Name -like "Sep*.msi"}| Select -ExpandProperty FullName| Out-String
    			            $msiloc = $msi.Replace("\\$computer\C$","C:")
    			            $msiloc = $msiloc.Trim()
    			            $msilocindex = ($msiloc).lastindexof('\')
    			            $msilocdir = ($msiloc).substring(0,$msilocindex)
                

                            #initiate repair function
                            Invoke-SymantecRepair -ComputerName $computer -msiPath $msiloc -SMCPath $inst
    	            }

        
                    #ask if you want to repair for current assets
    	            Elseif ($OutofDate -eq $false)
    	            {
                        If ($Confirm)
                        {
    		                $response = Read-Host "Would you like to run a repair?(y/n)"
                        }
                        else
                        {
                            $response = "n"
                        }
    	    
                        #continue if you do not wnat to repair
    		            If ($response -eq "n")
    		            {
    			            Write-Host -ForegroundColor Green "continuing"
    		            }

                        #repair if answer is yes
    		            ElseIf ($response -eq "y")
    		            {
    	                    #Save the current location
    			            Push-Location;
                    
                            #install location
    			            $inst = "C:\Program Files (x86)\Symantec\Symantec Endpoint Protection\Smc.exe"

                            #get msi location
    			            $msi = Get-ChildItem -Path "\\$computer\C$\ProgramData\Symantec\Symantec Endpoint Protection\CurrentVersion\Data\Cached Installs\"|
    			            Where-Object {$_.Name -like "Sep*.msi"}| Select -ExpandProperty FullName| Out-String
    			            $msiloc = $msi.Replace("\\$computer\C$","C:")
    			            $msiloc = $msiloc.Trim()
    			            $msilocindex = ($msiloc).lastindexof('\')
    			            $msilocdir = ($msiloc).substring(0,$msilocindex)
                

                            #initiate repair function
                            Invoke-SymantecRepair -ComputerName $computer -msiPath $msiloc -SMCPath $inst
                        }
                    }

                    Elseif ($OutofDate -eq $null)
                    {
                        Write-Host -ForegroundColor Green "continuing"
                    }

                    Else
                    {
                        Write-Error "Unknown OutOfDate Response"
                    }
    	         }

    	        Else
    	        {
    		        Write-Host -ForegroundColor Cyan "Could not ping asset: $computer"
    	        }
    		

            }
        }



        #declare variables used as arguments

        $assetList = Choose-RepairAssets -Path $Path

        #clear the screen
        Clear-Host

        if ($assetList.Contains("US*" -or "COSD*"))
        {
            Write-Warning "Your asset list contains server names!"
        }

        $pop = new-object -comobject wscript.shell
        $intAnswer = $pop.popup("Do you want to run in confirm mode?", 0,"Script Mode",4)
        If ($intAnswer -eq 6) 
        {
            $ConfirmQ = $true
        } 
        else 
        {
            $ConfirmQ = $false
        }
    }
    Process
    {
        Fix-Symantec -assetList $assetList -Confirm $ConfirmQ
    }
    End
    {
        Write-Host "Repair Completed"
    }
}

Initiate-SymantecRepair -Path .\ProblemSystems.csv
