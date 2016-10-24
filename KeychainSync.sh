#!/bin/sh

#########################################################################################
#  Script     : Keychain_Sync.sh 
#  Author     : Alan McCrossen <alan.mccrossen@wk.com>
#  Date       : 01/11/2016

# Script used to update the users login.keychain password with their current login password if they are not in sync.
# The user will be prompted for their current password and their old password in order for it to work.
# If the user does not know their old password login.keychain is moved into ~/Library/Keychains/Old Keychains and a timestamp is added to the name
# Local Items keychain is also deleted
# A restart is then required in order to create a new keychain at login
# Only works on 10.10 and later

##########################################################################################
##########################################################################################
#VARIABLES
ITcontact=""		# contact info used in dialog box
iconFile1=""		# icon used in dialog box
iconFile2=""		# icon used in dialog box
ErrorIconFile=""	# icon used in dialog box if there is a problem
SelfServiceName=""	# name of the self service app, we name it DIY. Used to quit the app if a restart is required.

loggedInUser=`python -c 'from SystemConfiguration import SCDynamicStoreCopyConsoleUser; import sys; username = (SCDynamicStoreCopyConsoleUser(None, None, None) or [None])[0]; username = [username,""][username in [u"loginwindow", None, u""]]; sys.stdout.write(username + "\n");'`
DATE=`date +%Y%m%d%H%M%S`
UUID=`system_profiler SPHardwareDataType | grep 'Hardware UUID' | awk '{print $3}'`
SelfServiceNamepid=`ps -ax | grep "$SelfServiceName" | grep -v grep | head -n 1 | awk '{print $1}'`
minor_OS_vers=`sw_vers -productVersion | awk -F. '{ print $2 }'`

##########################################################################################
##########################################################################################
# DO NOT MODIFY BELOW THIS LINE
##########################################################################################
##########################################################################################
# FUNCTIONS

# Check if the keychain is locked
CheckKeychainLockStatus(){

logger -s "KeychainSync: checking if the keychain is locked"
# check if the keychain is locked by trying to open it using the current password
security unlock-keychain -p "$UserPass" "/Users/$loggedInUser/Library/Keychains/login.keychain"
if [ ! $? -eq 0 ]; then
	logger -s "KeychainSync: keychain is locked"
	keychain=LOCKED
else
	logger -s "KeychainSync: keychain is open"
	keychain=OPEN
fi	
}

##########################################################################################

# Update the keychain password using the old password and current password
UpdateKeychainPassword(){
logger -s "KeychainSync: trying to update the keychain password"
security set-keychain-password -o "$OldUserPass" -p "$UserPass" "/Users/$loggedInUser/Library/Keychains/login.keychain"
}

##########################################################################################

# Get the user to try re-entering their old password or create a new one
RetryOldPassword(){
logger -s "KeychainSync: old password is incorrect"
OldUserPassDialogBox=`/usr/bin/osascript << OldPasswordRetry
tell app "System Events"
	Activate
	set iconFile to do shell script "echo '$ErrorIconFile'"
	set foo to {button returned, text returned} of (display dialog "That password did not work!" & return & "" & return & "Try entering the password again or try a different password." & return & "" & return & "If you do not know the password we can create a new keychain." default answer "" with title "Keychain Sync" with text buttons {"Create New Keychain", "Try Again"} default button {"Try Again"} with hidden answer with icon file iconFile )
	end tell
OldPasswordRetry`

# $OldUserPassDialogBox will contain the old password the user wants to try as well as the button returned from the dialog box
# put each of these into their own variable
RetryOldPassword_button_returned=`echo $OldUserPassDialogBox | awk 'BEGIN { FS = "," } ; { print $1 }' | sed 's/,//'`
OldUserPass=`echo $OldUserPassDialogBox | awk '{ print $NF }'`

if [[ "$RetryOldPassword_button_returned" == "Try Again" ]]; then
	logger -s "KeychainSync: trying again"
	UpdateKeychainPassword
	# if the password update was successful check the keychain is unlocked
	if [ $? -eq 0 ]; then
		CheckKeychainLockStatus
		if [[ $keychain == "LOCKED" ]]; then
			logger -s "KeychainSync: keychain is still locked"
			RetryOldPassword
		elif [[ $keychain == "OPEN" ]]; then
			DeleteiCloudKeychain
			SuccessfulKeychainUpdate	
		fi	
	else
		RetryOldPassword
	fi
elif [[ $RetryOldPassword_button_returned == "Create New Keychain" ]]; then
	logger -s "KeychainSync: user chose to create new keychain"
	DeleteOldLoginKeychain
	DeleteiCloudKeychain
	RestartNow
fi		
}

##########################################################################################

# Delete the login keychain
DeleteOldLoginKeychain(){

/usr/bin/osascript <<EOD
 tell application "System Events" to display dialog "This will delete your current keychain and create a new keychain." & return & "" & return & "Any passwords you have saved in the keychain will be lost so this should only be done as a last resort." & return & "" & return & "If you are unsure please contact IT at $ITcontact" with title "Keychain Sync" with text buttons {"Exit", "Continue"} cancel button {"Exit"} default button {"Continue"} with icon file "$ErrorIconFile"
EOD
if [ ! $? -eq 0 ]; then
	echo "KeychainSync: user cancelled"
	exit 0	
fi	

if [ ! -d "/Users/$loggedInUser/Library/Keychains/Old Keychains" ]; then
	logger -s "KeychainSync: making Old Keychains directory"
	mkdir "/Users/$loggedInUser/Library/Keychains/Old Keychains"
	chown -Rf "$loggedInUser" "/Users/$loggedInUser/Library/Keychains/Old Keychains"
fi
logger -s "KeychainSync: moving the login keychain"
mv /Users/$loggedInUser/Library/Keychains/login.keychain "/Users/$loggedInUser/Library/Keychains/Old Keychains/login.$DATE.keychain"
}

##########################################################################################

# Delete the local items keychain
DeleteiCloudKeychain(){
if [ -d "/Users/$loggedInUser/Library/Keychains/$UUID" ]; then
	logger -s "KeychainSync: deleting the iCloud keychain"
	# use the UUID to remove the local items keychain
	rm -rf "/Users/$loggedInUser/Library/Keychains/$UUID"
fi	
}

##########################################################################################

# restart function
RestartNow(){

/usr/bin/osascript <<RestartDialog
 tell application "System Events" to display dialog "Your old keychain has been deleted. You must restart now to create a new keychain." & return & "" & return & "Make sure to save any work before hitting restart." & return & "" & return & "Please dismiss any Local Items keychain prompts." with title "Keychain Sync" with text buttons {"Later", "Restart Now"} cancel button {"Later"} default button {"Restart Now"} with icon file "$iconFile1"
RestartDialog
if [ $? -eq 0 ]; then
	logger -s "KeychainSync: restarting"
	# if the user chose restart now quit Self Service if it's running and restart
	if [[ ! "$SelfServiceNamepid" == "" ]]; then
		kill -9 "$SelfServiceNamepid"
	fi	
	/usr/bin/osascript -e 'tell application "System Events"' -e 'restart' -e 'end tell'
else
	logger -s "KeychainSync: user cancelled restart"	
fi
}

SuccessfulKeychainUpdate(){
logger -s "KeychainSync: keychain password successfully updated"
/usr/bin/osascript <<Success
 tell application "System Events" to display dialog "Your keychain password has successfully been updated." & return & "" & return & "You should restart now." with title "Keychain Sync" with text buttons {"Later", "Restart Now"} cancel button {"Later"} default button {"Restart Now"} with icon file "$iconFile2"
Success
if [ $? -eq 0 ]; then
	logger -s "KeychainSync: restarting"
	# if the user chose restart now quit SelfServiceNamepid if it's running and restart
	if [[ ! "$SelfServiceNamepid" == "" ]]; then
		kill -9 "$SelfServiceNamepid"
	fi	
	/usr/bin/osascript -e 'tell application "System Events"' -e 'restart' -e 'end tell'
else
	logger -s "KeychainSync: user chose not to restart"	
fi
}

##########################################################################################
##########################################################################################
# CHECKS

# if OS is 10.9 or older the script will not work so inform the user and quit.
if [[ $minor_OS_vers -le 9 ]]; then
	logger -s "KeychainSync: requires Os X 10.10 or later to run"
	/usr/bin/osascript <<OldOS
tell application "System Events" to display dialog "Your OS is too old to run this. Mac OS X 10.10 or later is required." & return & "" & return & "Please contact IT at $ITcontact" with title "Keychain Sync" with text buttons {"OK"} default button {"OK"} with icon file "$ErrorIconFile"
OldOS
	exit 0
fi	


if [[ ${ITcontact} == "" ]]; then
	logger -s "KeychainSync: ITContact variable not set"
	exit 1
fi

if [[ ${iconFile1} == "" ]]; then
	iconFile1="/:Applications:Utilities:Keychain Access.app:Contents:Resources:AppIcon.icns"
fi

if [[ ${iconFile2} == "" ]]; then
	iconFile2="$iconFile1"
fi

if [[ ${ErrorIconFile} == "" ]]; then
	ErrorIconFile="$iconFile1"
fi

if [[ ${SelfServiceName} == "" ]]; then
	logger -s "KeychainSync: SelfServiceName variable not set, using Self Service"	
	SelfServiceName="Self Service"
fi

##########################################################################################
##########################################################################################
# SCRIPT

# get the users Password
logger -s "KeychainSync: getting users password"
UserPass=`/usr/bin/osascript << UserPassword
set iconFile to do shell script "echo '$iconFile1'"
tell app "System Events"
	Activate
	set foo to text returned of (display dialog "Enter your password:" buttons {"Cancel", "OK"} default button {"OK"} default answer "" with title "Keychain Sync" with hidden answer with icon file iconFile )
end tell
UserPassword`
if [ ! $? -eq 0 ]; then
	logger -s "KeychainSync: User cancelled"	
	exit 0
fi

# Check that password is correct, user has 3 attempts
# checking users password is correct
TRY=1
until dscl /Search -authonly "$loggedInUser" "$UserPass" &> /dev/null; do
    let TRY++
UserPass=`/usr/bin/osascript << UserPass
set iconFile to do shell script "echo '$ErrorIconFile'"
set Attempt to do shell script "echo '$TRY'"
tell app "System Events"
	Activate
	set foo to text returned of (display dialog "Sorry, that password was incorrect. Please try again:" & return & "" & return & "Attempt: " & Attempt & " of 3" default answer "" with title "Keychain Sync" with text buttons {"Cancel", "OK"} default button {"OK"} with hidden answer with icon file iconFile )
end tell
UserPass`
	if [ ! $? -eq 0 ]; then
		logger -s "KeychainSync: Keychain Sync: [$loggedInUser] User cancelled"		
		exit 0
	fi
	if [[ $TRY -ge 3  ]]; then
/usr/bin/osascript <<PasswordLimitReached
 tell application "System Events" to display dialog "You entered your password incorrectly too many times." & return & "" & return & "Please contact IT at $ITcontact" with title "Keychain Sync" with text buttons {"OK"} default button {"OK"} with icon file "$ErrorIconFile"
PasswordLimitReached
        logger -s "KeychainSync: password prompt unsuccessful after 3 attempts."
        exit 1
	fi
done

CheckKeychainLockStatus

# if the keychain is locked prompt for the users old password and use it to update the keychain
if [[ $keychain == "LOCKED" ]]; then

OldUserPassDialogBox=`/usr/bin/osascript << OldPass
tell app "System Events"
	Activate
	set iconFile to do shell script "echo '$iconFile1'"
	set foo to {button returned, text returned} of (display dialog "If you know your old password we can try and fix the keychain using it." & return & "" & return & "Enter the password you want to try below." & return & "" & return & "If you do not know the password we can create a new keychain." default answer "" with title "Keychain Sync" with text buttons {"Create New Keychain", "Try Password"} default button {"Try Password"} with hidden answer with icon file iconFile )
	end tell
OldPass`

	# $OldUserPassDialogBox will contain the old password the user wants to try as well as the button returned from the dialog box
	# put each of these into their own variable
	OldPassword_button_returned=`echo "$OldUserPassDialogBox" | awk 'BEGIN { FS = "," } ; { print $1 }' | sed 's/,//'`
	OldUserPass=`echo "$OldUserPassDialogBox" | awk '{ print $NF }'`

	if [[ $OldPassword_button_returned == "Try Password" ]]; then

		UpdateKeychainPassword
		# if the password update was successful check the keychain is unlocked
		CheckKeychainLockStatus
		# if unsuccessful ask the user if they would like to try again
		if [[ $keychain == "LOCKED" ]]; then
			RetryOldPassword
		elif [[ $keychain == "OPEN" ]]; then
			DeleteiCloudKeychain
			SuccessfulKeychainUpdate
		fi	
		
	elif [[ $OldPassword_button_returned == "Create New Keychain" ]]; then
		logger -s "KeychainSync: user chose not to try an old password."
		DeleteOldLoginKeychain
		DeleteiCloudKeychain
		RestartNow
	fi
elif [[ $keychain == "OPEN" ]]; then
	if [ -d "/Users/$loggedInUser/Library/Keychains/$UUID" ]; then
DeleteiCloudKeychainButton=`/usr/bin/osascript << DeleteiCloudKeychain
tell app "System Events"
	Activate
	set iconFile to do shell script "echo '$iconFile1'"
	set foo to {button returned} of (display dialog "Your login keychain is not locked." & return & "" & return & "If you are still getting keychain errors it is probably the Local Items keychain." & return & "" & return & "Do you want to delete the Local Items keychain?" with title "Keychain Sync" buttons {"Delete Local Items keychain", "Not At The Moment"} default button {"Not At The Moment"} with icon file iconFile )
	end tell
DeleteiCloudKeychain`
		if [[ $DeleteiCloudKeychainButton == "Delete Local Items keychain" ]]; then
			DeleteiCloudKeychain
/usr/bin/osascript <<LocalItemsDeleted
 tell application "System Events" to display dialog "Your Local Items keychain has been deleted." & return & "" & return & "If the alerts continue please restart." with title "Keychain Sync" with text buttons {"OK"} default button {"OK"} with icon file "$iconFile1"
LocalItemsDeleted
			exit 0
		else
			logger -s "KeychainSync: user chose not to delete Local Items keychain."		
		fi
	else
/usr/bin/osascript <<KeychainNotLocked
 tell application "System Events" to display dialog "Your keychain is not locked." with title "Keychain Sync" with text buttons {"OK"} default button {"OK"} with icon file "$iconFile1"
KeychainNotLocked
		exit 0	
	fi		
fi


