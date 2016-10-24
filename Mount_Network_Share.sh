#!/bin/bash

# This is set as parameter value 4 in the JSS policy, for example smb://fileshare.company.com/ShareName
server_address="$4"

# check for a trailing /, if one is found we need to print the second field, if not print the first field
if [ $( echo "$server_address" | rev | head -c 1 | grep -c "/" ) -gt 0 ]; then
	share_name=$(echo $server_address | rev | awk -F'/' '{print $2}' | rev)
else
	share_name=$(echo $server_address | rev | awk -F'/' '{print $1}' | rev)
fi		

# if the share is for the users individual network home folder the users name has to be added to the server address
if [[ $share_name == Homes ]]; then
	loggedInUser=$(python -c 'from SystemConfiguration import SCDynamicStoreCopyConsoleUser; import sys; username = (SCDynamicStoreCopyConsoleUser(None, None, None) or [None])[0]; username = [username,""][username in [u"loginwindow", None, u""]]; sys.stdout.write(username + "\n");')
	server_address="${server_address}"/"$loggedInUser"
	volume_to_open=/Volumes/"${loggedInUser}"
else
	volume_to_open=/Volumes/"${share_name}"
fi	

# mount the drive
osascript > /dev/null << EOT
	tell application "Finder" 
	activate
	mount volume "${server_address}"
	end tell
EOT

if [ -d "${volume_to_open}" ]; then
	# open the volume
	open "${volume_to_open}"
fi

exit 0