#!/bin/bash

#########################################################################################
#  Script     : FileVault_Sync.sh 
#  Version    : 2
#  Author     : Alan McCrossen <alan.mccrossen@wk.com>
#  Date       : 08/10/2015
#  Last Edited: 09/28/2016

# Script to add a user to filevault or update their password by removing then re-adding them.
# The local admin account will be used to do this. If it is not FV enabled it will be added first using the current logged in users credentials
# If the current logged in user is not FV enabled either the recovery key can be used to add both accounts providing the computer is running 10.9 or later
# logger -s is used to send information to the system log as well as stdout which can be viewed in the JSS policy log
# Run as root

#########################################################################################
# VARIABLES
#########################################################################################

loggedInUser=$(python -c 'from SystemConfiguration import SCDynamicStoreCopyConsoleUser; import sys; username = (SCDynamicStoreCopyConsoleUser(None, None, None) or [None])[0]; username = [username,""][username in [u"loginwindow", None, u""]]; sys.stdout.write(username + "\n");')
OSversionFull=$(sw_vers -productVersion)  # OS version
OSversionShort=$(sw_vers -productVersion | awk -F. '{print $2}') # Short OS version

######################################
#THE FOLLOWING ARE SET IN THE JSS
######################################

# Local Admin			 $4	 account that is used to re-add the user account to FileVault
# Local Admin Password	 $5	 local admin password
# Old Admin password	 $6	 use this if there are 2 potential admin passwords
# IT Contact Info		 $7	 appears in error message dialog box if there are any errors (help@wk.com or x7800)
# Icon					 $8	 custom icon that will appear in dialog box, if left empty the FV icon will be used
# Error Icon			 $9	 custom icon to display if there are any erros, if left empty $8 will be used						

if [[ ! "$4" = "" ]]; then
	adminAccount="${4}"
else	
	logger -s "FileVault Sync: adminAccount variable is not set"
	exit 1
fi

if [[ ! "$5" = "" ]]; then
	adminPassword="${5}"
else	
	logger -s "FileVault Sync: adminPassword variable is not set"
	exit 1
fi

if [[ ! "$6" = "" ]]; then
	oldAdminPassword="${6}"
else	
	logger -s "FileVault Sync: no old password set"
fi

if [[ ! "$7" = "" ]]; then
	ITcontact="${7}"
else	
	logger -s "FileVault Sync: ITcontact variable is not set"
	ITcontact=""
fi

# if the icon is not set use the FileVault icon
if [[ ! "$8" = "" ]]; then
	if [[ ! -e "$8" ]]; then
		logger "FileVault Sync: $8 cannot be found, using FV icon"
		iconFile="/:System:Library:PreferencePanes:Security.prefPane:Contents:Resources:FileVault.icns"
	else	
		iconFile=/$(echo "${8}" | sed 's#/#:#g')
	fi	
else	
	iconFile="/:System:Library:PreferencePanes:Security.prefPane:Contents:Resources:FileVault.icns"
fi

# if the icon is not set use the iconFile file
if [[ ! "$9" = "" ]]; then
	if [[ ! -e "$9" ]]; then
		logger "FileVault Sync: $9 cannot be found, using $8"
		errorIcon=$iconFile
	else	
		errorIcon=/$(echo "${9}" | sed 's#/#:#g')
	fi	
else	
	errorIcon=$iconFile
fi

echo "icon: $iconFile"
echo "errorIcon: $errorIcon"

#########################################################################################
# DO NOT EDIT BELOW THIS LINE
#########################################################################################
# FUNCTIONS
#########################################################################################

AddUser(){
 
expect -c "
log_user 0
spawn fdesetup add -usertoadd $userToAdd
expect \"Enter a password for '/', or the recovery key:\"
send ${fvEnabledPassword}\r
expect \"Enter the password for the added user \'${userToAdd}\':\"
send \"${userToAddPassword}\r\"
log_user 1
expect eof
" > /tmp/filevault.log

# check the log for errors, if found notify the user including the error message
if cat /tmp/filevault.log | grep Error; then
	ErrorMessage=`cat /tmp/filevault.log`
	/usr/bin/osascript << FVaddFail
set errorIcon to do shell script "echo '$errorIcon'"
set UserToAdd to do shell script "echo '$userToAdd'"
set ITcontact to do shell script "echo '$ITcontact'"
set ErrorMessage to do shell script "echo '$ErrorMessage'"
tell application "System Events"
	Activate
	display dialog "" & UserToAdd & " was not added to FileVault. Please contact IT at " & ITcontact & "." & return & "" & return &  "" & ErrorMessage & "" with title "FileVault Sync" buttons {"OK"} default button {"OK"} with icon file errorIcon
end tell
FVaddFail
	# remove the log file
	rm -rf /tmp/filevault.log
	logger -s "FileVault Sync: $userToAdd was not added."
	logger -s "FileVault Sync: $ErrorMessage"
	exit 1
else
	logger -s "FileVault Sync: $userToAdd successfully added"
	rm -rf /tmp/filevault.log
fi

}

#########################################################################################

GetUserPassword(){
# Prompt for the users password
logger -s "FileVault Sync: Prompting $loggedInUser for password"
userPassword=`/usr/bin/osascript << UserPassword
set iconFile to do shell script "echo '$iconFile'"
set loggedInUser to do shell script "echo '$loggedInUser'"
tell app "System Events"
	Activate
	set foo to text returned of (display dialog "Enter the current password for " & loggedInUser & "" buttons {"OK"} default button {"OK"} default answer "" with title "FileVault Sync" with hidden answer with icon file iconFile )
end tell
UserPassword`

# Check the password entered is correct, the user will get 3 attempts
TRY=1
until dscl /Search -authonly "${loggedInUser}" "${userPassword}" &> /dev/null; do
    let TRY++
    logger -s "FileVault Sync: Prompting $loggedInUser for password (attempt $TRY)..."
    userPassword="$(/usr/bin/osascript -e 'set errorIcon to do shell script "echo '$errorIcon'"' -e 'set Attempt to do shell script "echo '$TRY'"' -e 'tell application "System Events" to display dialog "Sorry, that password was incorrect. Please try again:" & return & "" & return & "Attempt " & Attempt & " of 3" default answer "" with title "FileVault Sync" buttons {"Cancel", "OK"} default button {"OK"} with hidden answer with icon file errorIcon' -e 'text returned of result')"
    if [[ "${userPassword}" == "" ]]; then
		logger -s "FileVault Sync: User cancelled"
		exit 0
	fi
	# after 3 unsuccessful attempts prompt the user to contact IT
    if [[ $TRY -ge 4 ]]; then
		/usr/bin/osascript <<-FAIL
set errorIcon to do shell script "echo '$errorIcon'"
set ITcontact to do shell script "echo '$ITcontact'"
tell application "System Events"
	activate
	display dialog "You entered your password incorrectly too many times. Please contact IT at " & ITcontact & "." with title "FileVault Sync" buttons {"OK"} default button {"OK"} with icon file errorIcon
end tell
FAIL
		logger -s "FileVault Sync: ${loggedInUser} password incorrect after 3 attempts."
		exit 1
    fi
done
	
}

#########################################################################################

# inform user that the admin password for the management account is incorrect and to contact IT
IncorrectAdminPass(){
/usr/bin/osascript << AdminPasswordError
set errorIcon to do shell script "echo '$errorIcon'"
set adminAccount to do shell script "echo '$adminAccount'"
set ITcontact to do shell script "echo '$ITcontact'"
tell app "System Events"
	Activate
	display dialog "The password for " & adminAccount & " is incorrect." & return & "" & return & "Please contact IT at " & ITcontact & "." with title "FileVault Sync" buttons {"OK"} default button {"OK"} with hidden answer with icon file errorIcon
end tell
AdminPasswordError
logger -s "FileVault Sync: Incorrect password for $adminAccount, cannot continue"
exit 1
}

#########################################################################################

ValidateRecoveryKey(){

# check the recovery key is correct, expect is used as fdesetup validaterecovery requires manual input of the recovery key. The output is written to /tmp/filevault.log
expect -c " spawn fdesetup validaterecovery; expect \"Enter the current recovery key:\"; send \"${fvEnabledPassword}\r\"; expect \"true\"; puts [open /tmp/filevault.log w] \$expect_out(buffer); interact "
			
# check the validaterecovery output, if successful the output will be true
if cat /tmp/filevault.log | grep true; then
	logger -s "FileVault Sync: Recovery key is good"
	AddUser
else
	logger -s "FileVault Sync: Recovery key is incorrect"
	fvEnabledPassword="$(/usr/bin/osascript -e 'set errorIcon to do shell script "echo '$errorIcon'"' -e 'tell application "System Events" to display dialog "Sorry, that recovery key was incorrect. Please try again:" default answer "" with title "FileVault Sync" buttons {"Cancel", "OK"} default button {"OK"} with hidden answer with icon file errorIcon' -e 'text returned of result')"
	if [[ "${fvEnabledPassword}" == "" ]]; then
		logger -s "FileVault Sync: User cancelled"
		rm -rf /tmp/filevault.log
		exit 0
	else	
		ValidateRecoveryKey
	fi
fi

# variables used to determine what the final message to the user will say
AddedAdmin="YES"
AddedUser="YES"

rm -rf /tmp/filevault.log	

}

#########################################################################################
# SCRIPT
#########################################################################################


# if OS is 10.7 or older the script will not work
if [[ $OSversionShort -le 7 ]]; then
	logger -s "FileVault Sync: $OSversionFull is too old, cannot continue"
	exit 1
fi	

# check that the logged in user is not the local admin account, if it is exit
if [[ "${adminAccount}" == "${loggedInUser}" ]]; then

	/usr/bin/osascript << LoggedInUser
set iconFile to do shell script "echo '$iconFile'"
set loggedInUser to do shell script "echo '$loggedInUser'"
tell app "System Events"
	Activate
	display dialog "You are logged in as " & loggedInUser & ", please log in as the user." buttons {"OK"} default button {"OK"} with title "FileVault Sync" with icon file iconFile
end tell
LoggedInUser
	logger -s "FileVault Sync: Logged in as ${adminAccount}, exiting"
	exit 0
else
	logger -s "FileVault Sync: Logged in as ${loggedInUser}"
fi

# check that the admin account password is correct, if it fails check for and if set try the old password
dscl /Search -authonly "${adminAccount}" "${adminPassword}" &> /dev/null
if [ ! $? -eq 0 ]; then
	# check for old password
	if [[ ! "${oldAdminPassword}" == "" ]]; then
	adminPassword="${oldAdminPassword}"
	dscl /Search -authonly "${adminAccount}" "${adminPassword}" &> /dev/null
		if [ ! $? -eq 0 ]; then
			IncorrectAdminPass
		else
			logger -s "FileVault Sync: Using old password for ${adminAccount}"
		fi
	else
		IncorrectAdminPass		
	fi	
fi	

# check the admin account is a fv enabled user, if it's not then we need to add it first
userCheck=$(fdesetup list | awk -v usrN="${adminAccount}" -F, 'index($0, usrN) {print $1}')
if [ "${userCheck}" != "${adminAccount}" ]; then
	# check the current user is FV enabled, if it is then this account can be used to add the admin account
	userCheck=$(fdesetup list | awk -v usrN="${loggedInUser}" -F, 'index($0, usrN) {print $1}')
	if [ "${userCheck}" = "${loggedInUser}" ]; then
		logger -s "FileVault Sync: ${adminAccount} is not FV enabled - ${loggedInUser} is FV enabled"

addAdmin=$(/usr/bin/osascript << CheckAdmin
set errorIcon to do shell script "echo '$errorIcon'"
set adminAccount to do shell script "echo '$adminAccount'"
set ITcontact to do shell script "echo '$ITcontact'"
tell app "System Events"
	Activate
	set question to display dialog "" & adminAccount & " is not a FileVault enabled user." & return & "" & return & "If you continue " & adminAccount & " will be enabled first or contact IT at " & ITcontact & "." with title "FileVault Sync" buttons {"Exit", "Continue"} cancel button {"Exit"} default button {"Continue"} with icon file errorIcon
	set answer to button returned of question
end tell
CheckAdmin)

		if [[ "$addAdmin" == "Continue" ]]; then
			userToAdd="${adminAccount}"
			userToAddPassword="${adminPassword}"
			if [[ "${fvEnabledPassword}" == "" ]]; then
				# get the current users password to be used in xml to add admin account to FV
				GetUserPassword
				fvEnabledPassword="${userPassword}"
			fi

			# If the user password is entered incorrectly 3 times the GetUserPassword function will return the password as button returned:OK or if the password is empty the user cancelled. In either case exit.
			if [[ "${fvEnabledPassword}" == "button returned:OK" ]]; then
				exit 1
			elif [[ "${fvEnabledPassword}" == "" ]]; then
				exit 0	
			fi
			# set the UserPassword variable so the user is not prompted for their password again later	
			UserPassword="${fvEnabledPassword}"
			logger -s "FileVault Sync: Using ${loggedInUser} to add ${adminAccount}"
			AddUser
			AddedAdmin="YES"
		else
			logger -s "FileVault Sync: User cancelled"
			exit 0
		fi
	else
		# If the current account and the management account are not FV enabled and the OS is 10.8 then there is nothing we can do, fdesetup validaterecovery was introduced in 10.9
		if [[ $OSversionShort -eq 8 ]]; then
			logger -s "FileVault Sync: ${adminAccount} and ${loggedInUser} are not FV enabled"
			logger -s "FileVault Sync: $OSversionFull does not support recovery key validation, cannot continue"
/usr/bin/osascript << CheckAdmin
set errorIcon to do shell script "echo '$errorIcon'"
set adminAccount to do shell script "echo '$adminAccount'"
set ITcontact to do shell script "echo '$ITcontact'"
set loggedInUser to do shell script "echo '$loggedInUser'"
tell app "System Events"
	Activate
	display dialog "" & adminAccount & " and " & loggedInUser & " are not FileVault enabled users." & return & "" & return &  "Please contact IT at " & ITcontact & "." with title "FileVault Sync" buttons {"OK"} default button {"OK"} with icon file errorIcon
end tell
CheckAdmin
			exit 1	
		else
			# If the OS is 10.9 or later we can use any account that is FV enabled along with the recovery key instead of a password to add users
			logger -s "FileVault Sync: $adminAccount and $loggedInUser are not FV enabled"	
addAdmin=$(/usr/bin/osascript << CheckAdmin
set errorIcon to do shell script "echo '$errorIcon'"
set adminAccount to do shell script "echo '$adminAccount'"
set ITcontact to do shell script "echo '$ITcontact'"
set loggedInUser to do shell script "echo '$loggedInUser'"
tell app "System Events"
	Activate
	set question to display dialog "" & adminAccount & " and " & loggedInUser & " are not FileVault enabled users." & return & "" & return &  "You can continue using the recovery key if you have it or contact IT at " & ITcontact & "." with title "FileVault Sync" buttons {"Exit", "Continue"} cancel button {"Exit"} default button {"Continue"} with icon file errorIcon
	set answer to button returned of question
end tell
CheckAdmin)
		fi
		if [[ $addAdmin == "Continue" ]]; then
			logger -s "FileVault Sync: Using recovery key to add $adminAccount"
			userToAdd="${adminAccount}"
			userToAddPassword="${adminPassword}"
			# get the name of the first available FV enabled user
			# prompt for the recovery key to be used instead of a user password
			fvEnabledPassword="$(/usr/bin/osascript -e 'set iconFile to do shell script "echo '$iconFile'"' -e 'tell application "System Events" to display dialog "Please enter the recovery key:" default answer "" with title "FileVault Sync" with text buttons {"OK"} default button 1 with hidden answer with icon file iconFile' -e 'text returned of result')"
			# check the correct key has been entered
			ValidateRecoveryKey	
		else
			logger -s "FileVault Sync: User cancelled"
			exit 0
		fi
	fi
else
	logger -s "FileVault Sync: ${adminAccount} is FV enabled"		
fi

# if we don't already have it get the users password
if [[ "${userPassword}" == "" ]]; then
	GetUserPassword
fi

# if the password field is empty the user has cancelled
if [[ "${userPassword}" == "" ]]; then
	logger -s "FileVault Sync: User cancelled"
	exit 0
fi	

# if the user is FV enabled remove them so they can be re-added using the new password
userCheck=$(fdesetup list | awk -v usrN="${loggedInUser}" -F, 'index($0, usrN) {print $1}')
if [ "${userCheck}" = "$loggedInUser" ]; then
	fdesetup remove -user "$loggedInUser"
	logger -s "FileVault Sync: $loggedInUser removed from FV"
else
	logger -s "FileVault Sync: $loggedInUser is not FV enabled"
	AddedUser="YES"	
fi

# set variables to be used
userToAdd="$loggedInUser"
userToAddPassword="${userPassword}"
fvEnabledPassword="${adminPassword}"

AddUser

# check to see if the logged in account was successfully added to the FV users list
userCheck=$(fdesetup list | awk -v usrN="${loggedInUser}" -F, 'index($0, usrN) {print $1}')
if [ "${userCheck}" != "${loggedInUser}" ]; then	
	# if checkFVusers fails display dialog
		/usr/bin/osascript << Fail
set errorIcon to do shell script "echo '$errorIcon'"
set loggedInUser to do shell script "echo '$loggedInUser'"
set ITcontact to do shell script "echo '$ITcontact'"
tell application "System Events"
	Activate
	display dialog "" & loggedInUser & " was not added to FileVault. Please contact IT at " & ITcontact & "." with title "FileVault Sync" buttons {"OK"} default button {"OK"} with icon file errorIcon
end tell
Fail
	logger -s "FileVault Sync: $loggedInUser was not added to FV"
else
	# if checkFVusers passes display a dialog informing the user, it will go away after 20 seconds
	# the message will be based on what has been done
	# if the variable is empty set to NO
	if [[ $AddedAdmin == "" ]]; then
		AddedAdmin="NO"
	fi

	if [[ $AddedUser == "" ]]; then
		AddedUser="NO"
	fi		

	# work out the final dialog box based on what was done
	if [[ $AddedAdmin == "NO" ]] && [[ $AddedUser == "YES" ]]; then
		FinalMessage="${loggedInUser} has been added to FileVault."
	elif [[ $AddedAdmin == "YES" ]] && [[ $AddedUser == "YES" ]]; then
		FinalMessage="${loggedInUser} and ${adminAccount} have been added to FileVault."
	elif [[ $AddedAdmin == "NO" ]] && [[ $AddedUser == "NO" ]]; then
		FinalMessage="The FileVault password for ${loggedInUser} has been updated."
	elif [[ $AddedAdmin == "YES" ]] && [[ $AddedUser == "NO" ]]; then
		FinalMessage="The Filevault password for ${loggedInUser} has been updated and $adminAccount has been added."
	fi		

	/usr/bin/osascript << Success
set FinalMessage to do shell script "echo '${FinalMessage}'"
set iconFile to do shell script "echo '$iconFile'"
tell application "System Events"
	Activate
	display dialog "" & FinalMessage & "" with title "FileVault Sync" buttons {"OK"} default button {"OK"} with icon file iconFile giving up after 20
end tell
Success
	logger -s -s "FileVault Sync: DONE"
fi

exit 0

exit 0