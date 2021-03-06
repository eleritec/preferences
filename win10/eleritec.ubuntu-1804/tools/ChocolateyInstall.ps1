function Setup-Prerequisites {
    # ensure WSL is enabled
    if(-Not (Is-WSL-Enabled)) {
        Enable-WindowsOptionalFeature -Online -FeatureName  Microsoft-Windows-Subsystem-Linux -NoRestart |Out-Null
        if (Test-PendingReboot) {
            $Boxstarter.RebootOk=$true
            Invoke-Reboot
        }
    }

    # utility packages
    choco install dos2unix -y

    # download and install ubuntu 18.04 with Chocolatey
    choco install wsl-ubuntu-1804 -y
}

function Validate-Environment {
    # make sure we're running Win10 build 14393 or greater
    $os = [Environment]::OSVersion.Version
    if(-Not (($os.Major -ge 10) -And ($os.Build -ge 14393))) {
        return $false
    }

    # ensure we're running with admin privileges
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Is-WSL-Enabled {
    $feature = (Get-WindowsOptionalFeature -Online -FeatureName  Microsoft-Windows-Subsystem-Linux)
    if([String]::IsNullOrEmpty($feature)) {
        return $false
    }
    return $feature.State -eq "Enabled"
}

function Configure-User {
    $distro = "Ubuntu-18.04"

    # create the user if they don't exist
    $user_check = wsl -d $distro -u root id -u $env:username 2>&1
    if($user_check -like "*no such user") {
        # calling `wsl -d Ubuntu-18.04 adduser` chokes on --geocos for some reason, 
		# so instead we'll dump the creation to a bash script that we can execute as root
		$pw_params = $env:username + ':password'
		Out-File -InputObject "#!/bin/bash" -Encoding "ASCII" -FilePath _user_init.sh
		Out-File -InputObject "adduser --disabled-password --gecos '' $env:username" -Encoding "ASCII"  -FilePath _user_init.sh -Append
		Out-File -InputObject "echo '$pw_params' | chpasswd" -Encoding "ASCII" -FilePath _user_init.sh -Append
		dos2unix _user_init.sh
		wsl -d $distro chmod 744 ./_user_init.sh
		wsl -d $distro ./_user_init.sh
        rm _user_init.sh
        
        # force them to change their password on next login
		wsl -d $distro passwd --expire $env:username
    }

    # if they're not part of the sudo group, then try to add them to default expected groups
    $group_check = (wsl -d $distro -u root groups $env:username) -split ' ' | Where-Object { $_ -eq 'sudo' }
    if($group_check -ne 'sudo') {
        Write-Output "Configuring groups for $env:username ..."
        $target_groups = @("adm", "dialout", "cdrom", "floppy", "sudo", "audio", "dip", "video", "plugdev", "lxd", "netdev")
        foreach ($group in $target_groups) {
            wsl -d $distro -u root usermod -aG $group $env:username
        }
    }

    # setup the default user for the distro if it's currently set to root (default for choco install)
    $default_user = wsl -d $distro whoami
    if($default_user -eq 'root') {
        $ubuntu_path = Get-Ubuntu-Path
		if(-Not ($env:path -like '*wsl-ubuntu-1804*')) {
			$env:path += ";$ubuntu_path"
		}	
		ubuntu1804 config --default-user $env:username
    }
}

function Configure-Host-Permissions {
    # choco package installs under C:\ProgramData, which is restricted to admin.
	# in order to run ubuntu without elevated privileges, we need to grant the
	# current user full control to $ubuntu_path
    Write-Output "Setting up Windows Host filesystem access ..."
    $self = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $ubuntu_path = Get-Ubuntu-Path
	$acl = Get-Acl $ubuntu_path
	$AccessRule = New-Object System.Security.AccessControl.FileSystemAccessRule($self, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
	$acl.SetAccessRule($AccessRule)
	$acl | Set-Acl $ubuntu_path
}

function Configure-Shortcuts {
	# place a shortcut on the desktop
	# TODO: figure out how to pin this shortcut to the taskbar
    Write-Output "Creating Ubuntu-18.04 Desktop shortcut..."
    $ubuntu_path = Get-Ubuntu-Path
	$launcher = "$ubuntu_path\ubuntu1804.exe"
	$shortcut_file = [Environment]::GetFolderPath("Desktop") + "\Ubuntu-18_04.lnk"
	if(([System.IO.File]::Exists($launcher)) -And (-Not [System.IO.File]::Exists($shortcut_file))) {
		Create-Shortcut $launcher $shortcut_file
	}
}

function Get-Ubuntu-Path {
    $choco_path = Get-Choco-Path
    return "$choco_path\lib\wsl-ubuntu-1804\tools\unzipped"
}

function Get-Choco-Path {
    # note, don't call 'Get-Command choco' to obtain the location of the choco executable.
    # if running under boxstarter, calls to choco are intercepted and will result in garbled output.
    # instead, parse the $env:path to obtain our chocolatey path
	$choco_path = ($env:Path -split ';' | Where-Object { $_ -like '*chocolatey\bin' })
	$choco_path = $choco_path.split("\\") | Where-Object { $_ -ne "choco.exe" -And $_ -ne "bin" }
	return $choco_path -join "\"
}

function Create-Shortcut($source_exe, $dest_link) {
	$WScriptShell = New-Object -ComObject WScript.Shell
	$Shortcut = $WScriptShell.CreateShortcut($dest_link)
	$Shortcut.TargetPath = $source_exe
	$Shortcut.Save()
}

if(Validate-Environment) {
    Setup-Prerequisites
    Configure-User
    Configure-Host-Permissions
    Configure-Shortcuts
}
