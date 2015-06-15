#!/bin/bash
#
# A FRITZ!-based Homematic presence detection script which can be regularly
# executed (e.g. via cron on a separate Linux system) and remotely queries a FRITZ!
# device about the registered LAN/WLAN devices.
#
# This script can be found at https://github.com/jens-maus/hm_pdetect
#
# Based on a device list specified in the config file (HM_USER_LIST) certain system
# variables are then set in the corresponding CCU so that users are being recognized
# as being present or away. In addition guests are being identified by also specifying
# other known devices in a separate list (HM_KNOWN_LIST) and if a device is found
# that is not either in the user list or known list it will be recognized as a
# guest device and the script will set a presence system variable for guests in the
# CCU as well.
#
# Copyright (C) 2015 Jens Maus <mail@jens-maus.de>
#
# This script is based on similar functionality and combines the functionality of
# these projects into a single script:
#
# https://github.com/jollyjinx/homematic
# https://github.com/max2play/webinterface
#
# Version history:
# 0.1 (2015-03-02): initial release
# 0.2 (2015-03-06): fixed bug in match for multiple user devices.
# 0.3 (2015-03-06): fixed bug where user devices were identified as guest devices
# 0.4 (2015-06-15): added functionality to generate an additional enum list and
#                   large general rework to have more stability fo querying and
#                   setting CCU variables
# 

CONFIG_FILE="hm_pdetect.conf"
NC="/bin/nc"

#####################################################
# Main script starts here, don't modify

# default settings (overwritten by config file)
HM_FRITZ_IP="fritz.box fritz.repeater"

# IP address/hostname of CCU2
HM_CCU_IP="homematic-ccu2.fritz.box"

# Name of a CCU variable we set for signaling general presence
HM_CCU_PRESENCE_VAR="Anwesenheit"

# used names within variables
HM_CCU_PRESENCE_GUEST="Gast"
HM_CCU_PRESENCE_NOBODY="Niemand"
HM_CCU_PRESENCE_PRESENT="anwesend"
HM_CCU_PRESENCE_AWAY="abwesend"

# declare all associative arrays first
declare -A HM_USER_LIST   # username<>MAC/IP tuple
declare -A deviceList     # MAC<>IP tuple

if [ -e "$(dirname $0)/${CONFIG_FILE}" ]; then
  source "$(dirname $0)/${CONFIG_FILE}"
else
  echo "ERROR: config file ${CONFIG_FILE} doesn't exist"
fi

RETURN_FAILURE=1
RETURN_SUCCESS=0

# function returning the current state of a homematic variable
# and returning success/failure if the variable was found/not
getVariableState()
{
  local name="$1"

  local result=$(wget -q -O - "http://${HM_CCU_IP}:8181/rega.exe?state=dom.GetObject('${name}').State()" | sed 's/.*<state>\(.*\)<\/state>.*/\1/')

  if [ "${result}" != "null" ]; then
    echo ${result}
    return $RETURN_SUCCESS
  else
    return $RETURN_FAILURE
  fi
}

# function setting the state of a homematic variable in case it
# it different to the current state and the variable exists
setVariableState()
{
  local name="$1"
  local newstate="$2"

  # before we going to set the variable state we
  # query the current state and if the variable exists or not
  curstate=$(getVariableState "${name}")
  if [ $? -eq 1 ]; then
    return $RETURN_FAILURE
  fi

  # only continue of the current state is different to the new state
  if [ "${curstate}" == "${newstate}" ]; then
    return $RETURN_SUCCESS
  fi

  # the variable should be set to a new state, so lets do it
  echo -n "Setting variable '${name}' to '${newstate}'... "
  local result=$(wget -q -O - "http://${HM_CCU_IP}:8181/rega.exe?state=dom.GetObject('${name}').State(${newstate})" | sed 's/.*<state>\(.*\)<\/state>.*/\1/')

  # if setting the variable succeeded the result will be always
  # 'true'
  if [ "${result}" == "true" ]; then
    echo "ok."
    return $RETURN_SUCCESS
  fi

  echo "ERROR."
  return $RETURN_FAILURE
}

# function to check if a certain boolean system variable exists
# at a CCU and if not creates it accordingly
createVariable()
{
  local vaname=$1
  local valist=$2

  # if the variable exists already, exit immediately!
  getVariableState ${vaname} >/dev/null
  if [ $? -eq 0 ]; then
    return $RETURN_SUCCESS
  fi
    
  # if not we check if the 'nc' is present and if not we
  # quit here since we can only create the variable using that tool
  if [ ! -f ${NC} ]
  then
    echo "WARNING: ${NC} does not exist. You need to create variable '${vaname}' on CCU2 manually"
    return $RETURN_FAILURE
  fi
    
  if [ -n "${valist}" ]; then
    echo "Creating '${vaname}' (list) with values '${valist}'"
    local postbody="string v='${vaname}';boolean f=true;string i;foreach(i,dom.GetObject(ID_SYSTEM_VARIABLES).EnumUsedIDs()){if(v==dom.GetObject(i).Name()){f=false;}};if(f){object s=dom.GetObject(ID_SYSTEM_VARIABLES);object n=dom.CreateObject(OT_VARDP);n.Name(v);s.Add(n.ID());n.ValueType(ivtInteger);n.ValueSubType(istEnum);n.DPInfo('presence enum list');n.ValueList('${valist}');n.State(0);dom.RTUpdate(0);}"
  else
    echo "Creating '${vaname}' (bool)"
    local name=$(echo ${vaname} | cut -d '.' -f2)
    if [ "${name}" == "${vaname}" ]; then
      name="general presence"
    fi
    local postbody="string v='${vaname}';boolean f=true;string i;foreach(i,dom.GetObject(ID_SYSTEM_VARIABLES).EnumUsedIDs()){if(v==dom.GetObject(i).Name()){f=false;}};if(f){object s=dom.GetObject(ID_SYSTEM_VARIABLES);object n=dom.CreateObject(OT_VARDP);n.Name(v);s.Add(n.ID());n.ValueType(ivtBinary);n.ValueSubType(istBool);n.DPInfo('${name} @ home');n.ValueName1('${HM_CCU_PRESENCE_PRESENT}');n.ValueName0('${HM_CCU_PRESENCE_AWAY}');n.State(false);dom.RTUpdate(0);}"
  fi

  local postlength=$(echo "$postbody" | wc -c)
  echo -e "POST /tclrega.exe HTTP/1.0\r\nContent-Length: $postlength\r\n\r\n$postbody" | ${NC} "${HM_CCU_IP}" 80 >/dev/null 2>&1

  # check if the variable exists now and return an appropriate
  # return value
  getVariableState ${vaname} >/dev/null
  if [ $? -eq 0 ]; then
    return $RETURN_SUCCESS
  else
    return $RETURN_FAILURE
  fi
}

# function that logs into a FRITZ! device and stores the MAC and IP address of all devices
# in an associative array which have to bre created before calling this function
retrieveFritzBoxDeviceList()
{
  local ip=$1
  local user=$2
  local secret=$3

  # retrieve login challenge
  local challenge=$(wget -O - "http://${ip}/login_sid.lua" 2>/dev/null | sed 's/.*<Challenge>\(.*\)<\/Challenge>.*/\1/')

  # process login and hash it with our password
  local cpstr="${challenge}-${secret}"
  local md5=$(echo -n ${cpstr} | iconv -f ISO8859-1 -t UTF-16LE | md5sum -b | awk '{print substr($0,1,32)}')
  local response="${challenge}-${md5}"
  local url_params="username=${user}&response=${response}"
  
  # send login request and retrieve SID return
  local sid=$(wget -O - "http://${ip}/login_sid.lua?${url_params}" 2>/dev/null | sed 's/.*<SID>\(.*\)<\/SID>.*/\1/')
 
  # retrieve the network device list from the fritzbox and filter it
  # to show only the part between "uiLanActive" and "uiLanPassive" which should include all
  # currently connected devices.
  local devices=$(wget -O - "http://${ip}/net/network_user_devices.lua?sid=${sid}" 2>/dev/null | grep uiLanActive | sed 's/.*uiLanActive\(.*\)uiLanPassive.*/\1/')

  # extract the mac addresses of devices being active
  local maclist=($(echo ${devices} | egrep -o '>[0-9a-fA-F]{2}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}<' | tr -d '><'))
  local iplist=($(echo ${devices} | egrep -o '>[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}<' | tr -d '><'))

  # modify the global associative array
  for (( i = 0; i < ${#maclist[@]} ; i++ )); do
    deviceList[${maclist[$i]}]=${iplist[$i]}
  done
}

# function that creats a list of tupels from an input string
# of individual users. This tuple list can then be used to be set for the
# presence.list variable type when constructing it
createUserTupleList()
{
  local a="$1"

  # constract the brace expansion string from the input
  # string so that we end up with something like '{1,}{2,}{3,}', etc.
  local b=""
  local i=0
  for Y in $a; do
    ((i = i + 1))
    b=$b{$i,}
  done

  # lets apply the brace expansion string and sort it
  # according to numbers and not have it in the standard sorting
  local c=$(for X in `eval echo\ $b;`; do echo $X; done | sort -n)

  # lets construct tupels for every number (1-9) in
  # the brace expansion
  local tuples=""
  for X in $c; do
    if [ -n "${tuples}" ]; then
      tuples="${tuples};"
    fi
    tuples="${tuples}`echo $X | fold -w1 | paste -sd\,  -`"
  done

  # now we replace each number (1-9) with the appropriate
  # string of the input array
  local i=0
  for Z in ${a}; do
    ((i = i + 1))
    tuples=`echo ${tuples} | sed "s/${i}/${Z}/g"`
  done

  # now add Guest to each tuple
  IFS=';'
  local guestTuples="${HM_CCU_PRESENCE_GUEST}"
  for U in ${tuples}; do
    guestTuples="${guestTuples};${U},${HM_CCU_PRESENCE_GUEST}"
  done
  IFS=' '

  tuples="${HM_CCU_PRESENCE_NOBODY};${tuples};${guestTuples}"

  echo "${tuples}"
}

################################################
# main processing starts here
#

echo "hm_pdetect 0.4 - a FRITZ!-based homematic presence detection script"
echo "(Jun 15 2015) Copyright (C) 2015 Jens Maus <mail@jens-maus.de>"
echo


# lets retrieve all mac<>ip addresses of currently
# active devices in our network
echo -n "querying fritz devices:"
for ip in ${HM_FRITZ_IP[@]}; do
  echo -n " ${ip}"
  retrieveFritzBoxDeviceList ${ip} ${HM_FRITZ_USER} ${HM_FRITZ_SECRET}
done
echo ", devices online: ${#deviceList[@]}."

# lets identify user presence
presence=0
numusers=0
echo "checking user presence: "
for user in "${!HM_USER_LIST[@]}"; do
  ((numusers = numusers + 1))
  echo -n "${user}[$numusers]: "
  stat="false"

  # prepare the device list of the user as a regex
  userDeviceList=$(echo ${HM_USER_LIST[${user}]} | tr ' ' '|')

  # try to match MAC address first
  if [[ ${deviceList[@]} =~ ${userDeviceList} ]]; then
    stat="true"
  else
    # now match the IP address list instead
    if [[ ${!deviceList[@]} =~ ${userDeviceList} ]]; then
      stat="true"
    fi
  fi

  if [ "${stat}" == "true" ]; then
    echo present
    ((presence = presence + numusers))
  else
    echo away
  fi

  # remove checked user devices from deviceList so that
  # they are not recognized as guest devices
  for device in ${HM_USER_LIST[${user}]}; do
    # try to match MAC address first
    if [[ ${!deviceList[@]} =~ ${device} ]]; then
      unset deviceList[${device}]
    else
      # now match the IP address list instead
      if [[ ${deviceList[@]} =~ ${device} ]]; then
        for dev in ${!deviceList[@]}; do
          if [ ${deviceList[${dev}]} == ${device} ]; then
            unset deviceList[${dev}]
            break
          fi
        done
      fi
    fi
  done

  # set status in homematic CCU
  createVariable ${HM_CCU_PRESENCE_VAR}.${user}
  setVariableState ${HM_CCU_PRESENCE_VAR}.${user} ${stat}

done

# lets identify guest presence by ruling out
# devices in our list that are not listed in our HM_KNOWN_LIST
# array
for device in ${HM_KNOWN_LIST[@]}; do

  # try to match MAC address first
  if [[ ${!deviceList[@]} =~ ${device} ]]; then
    unset deviceList[${device}]
  else
    # now match the IP address list instead
    if [[ ${deviceList[@]} =~ ${device} ]]; then
      for dev in ${!deviceList[@]}; do
        if [ ${deviceList[${dev}]} == ${device} ]; then
          unset deviceList[${dev}]
          break
        fi
      done
    fi
  fi

done

echo "${#deviceList[@]} guest devices found: ${!deviceList[@]}"

# create/set presence system variable in CCU if guest devices
# were found
guestoffset=$((2**numusers))
echo -n "${HM_CCU_PRESENCE_GUEST}[${guestoffset}]: "
createVariable ${HM_CCU_PRESENCE_VAR}.${HM_CCU_PRESENCE_GUEST}
if [ ${#deviceList[@]} -gt 0 ]; then
  # set status in homematic CCU
  echo present
  setVariableState ${HM_CCU_PRESENCE_VAR}.${HM_CCU_PRESENCE_GUEST} true
  ((presence = presence + guestoffset))
else
  echo away
  setVariableState ${HM_CCU_PRESENCE_VAR}.${HM_CCU_PRESENCE_GUEST} false
fi

# we set the global presence variable (if configured) to
# the value of the user+guest combination
userList="${!HM_USER_LIST[@]}"
userTupleList=`createUserTupleList "${userList}"`
createVariable ${HM_CCU_PRESENCE_VAR}.list ${userTupleList}
setVariableState ${HM_CCU_PRESENCE_VAR}.list ${presence}

# set the global presence variable to true/false depending
# on the general presence of people in the house
createVariable ${HM_CCU_PRESENCE_VAR}
if [ ${presence} -gt 0 ]; then
  setVariableState ${HM_CCU_PRESENCE_VAR} true
else
  setVariableState ${HM_CCU_PRESENCE_VAR} false
fi