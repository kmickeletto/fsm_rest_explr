#!/bin/bash

while [[ $# -gt 0 ]]; do
  case $1 in
    --insecure|-i)
	validate_super_cert="false"
	shift 1
    ;;
    --fsmuser*|-u)
        if [[ $1 =~ = ]]; then
	  fsmuser=${1#*=}
	  shift 1
        else
          fsmuser=$2
  	  shift 2
	fi
    ;;
    --fsmdomain*|-d)
        if [[ $1 =~ = ]]; then
          fsmdomain=${1#*=}
          shift 1
	else
          fsmdomain=$2
  	  shift 2
	fi
	[[ ${fsmdomain,,} == empty ]] && fsmdomain=Empty
    ;;
    --fsmorg*|-o)
        if [[ $1 =~ = ]]; then
          fsmorg=${1#*=}
          shift 1
	else
	  fsmorg=$2
	  shift 2
	fi
    ;;
    --fsmhost*|-h)
        if [[ $1 =~ = ]]; then
          fsmhost=${1#*=}
          shift 1
	else
  	  fsmhost=$2
	  shift 2
	fi
    ;;
    --passwd*)
        if [[ $1 =~ = ]]; then
          pass=${1#*=}
          shift 1
        else
          pass=$2
          shift 2
        fi
        ;;
    /phoenix/*)
	url=$1
	shift 1
    ;;
    *)
	echo "Unknown option $1"
	exit 1
    ;;
  esac
done

if which jq &>/dev/null; then
  jq_enabled=true
else
  jq_enabled=false
fi
if which xmllint &>/dev/null; then
  xmllint_enabled=true
else
  xmllint_enabled=false
fi

shutdown() {
    exit $?
}
trap shutdown EXIT

help() {
  echo "Here are some sample endpoints to query"
## If you want to search through the FortiSIEM Apache logs instead, uncomment this line
#  zcat /etc/httpd/logs/ssl_request_log* 2>/dev/null | awk '{print $6"|"$7"|"$9}' | grep -Pv '\|4..$' | grep -P 'GET' | cut -f1 -d'?' | grep '\/rest\/' | grep -v '\/h5\/report\/' | awk -F'|' '{print $2}' | sort | uniq | pr -t3 -w$(tput cols)
## And comment this line out
  curl -Ss $secure https://raw.githubusercontent.com/kmickeletto/fsm_rest_explr/main/endpoints.list | sort | uniq | pr -t2 -w$(tput cols)
  exit 0
}

if [[ $1 =~ ^(--help|help)$ ]]; then
  help
fi
[[ -z $fsmhost ]] && fsmhost=localhost

$validate_super_cert || secure="-k"
get_user_salt() {
  local user=$1
  local org=$2
  local domain=$3
  local result

  result=$(curl -Ssf $secure "https://${fsmhost}/phoenix/rest/h5/sec/loginInfo?s=" -H 'Connection: keep-alive' -H 'Content-Type: text/plain;charset=UTF-8' --data-raw '{"userName":"'$user'","organization":"'$org'","domain":"'${domain:-Empty}'"}')
  if [[ $? -gt 0 ]]; then
    echo "Unable to make a valid connection to ${fsmhost}.  Please check your settings and try again" >&2
    return 1
  fi
  if [[ $result =~ ^\{\"salt\": ]]; then
    perl -pe 's/{"salt":"([^"]*)"}/\1/' <<< "$result"

## Externally authenticated users don't use salted passwords
  else
    result=
  fi    
  return 0
}

encrypt_string() {
  openssl enc -aes-256-cbc -pbkdf2 -k "$1" | base64 -w0 < /dev/stdin
}

decrypt_string() {
  base64 -d < /dev/stdin 2>/dev/null | openssl enc -d -aes-256-cbc -pbkdf2 -k "$1" 2>/dev/null
}

authenticate() {
  local cookie
  local result
  local salt
  local pass
  local password
  local domain
  local base64_domain
  local base64_session

## If user has already authenticated, attempt to read previous session from disk.  If session is no longer active, force re-auth
  if [[ $fsmuser =~ [-_A-Za-z0-9]+/[-_A-Za-z0-9]+ ]]; then
    fsmorg=${fsmuser%/*}
    fsmuser=${fsmuser#*/}
  fi
  if [[ -n $fsmuser ]] && [[ -z $fsmorg ]]; then
    echo "Org not specified.  You must specify your org and username."
    echo "ORG/USER"
    exit 1
  fi

## If user session file is detected, read it and check if user is still logged in
  if [[ -f .${fsmorg,,}_${fsmuser,,}.cred ]]; then
    domain=$(awk -F'#' '{print $2}' ".${fsmorg,,}_${fsmuser,,}.cred" | base64 -d 2>/dev/null)
    salt=$(get_user_salt "${fsmuser,,}" "${fsmorg,,}" "${domain}")
    [[ $? -gt 0 ]] && rm -f ".${fsmorg,,}_${fsmuser,,}.cred" && exec $(basename $0) $url 
    session=($(awk -F'#' '{print $3}' ".${fsmorg,,}_${fsmuser,,}.cred" | decrypt_string $salt))
    logged_in=$(curl --fail -Ss $secure "https://${fsmhost}/phoenix/rest/h5/sec/isLoggedIn?s=${session[2]}" --compressed -H "Cookie: JSESSIONID=${session[1]}; s=${session[0]}" -H 'Content-Type: application/json;charset=UTF-8' -H 'Accept: application/json, text/plain, */*' -H 'user-agent: FortiSIEM Rest Explorer' | perl -pe 's/.*loggedIn":"([^"]*).*/\1/')
    if ${logged_in,,}; then
      return
    else
      echo "Session timed out, please authenticate to continue" >&2
    fi
  fi
  if [[ -z $fsmuser ]] || [[ -z $fsmorg ]]; then
    echo "If you export your username and org, you can bypass authenticating each time."
    echo "export user=org/user"
    echo
  fi
  [[ -z $fsmuser ]] && read -p 'Enter your username: ' fsmuser || echo "Username: $fsmuser" >&2
  [[ -z $pass ]] && printf 'Enter your password: ' >&2 && read -es pass && printf '\n' >&2
  if [[ $fsmuser =~ [-_A-Za-z0-9]+/[-_A-Za-z0-9]+ ]]; then
    fsmorg=${fsmuser%/*}
    fsmuser=${fsmuser#*/}
  fi
  [[ -z $fsmorg ]] && read -e -i Super -p 'Enter your org: ' fsmorg
  if [[ -z $domain ]] && [[ -z $fsmdomain ]]; then
    read -p 'Enter your LDAP domain, blank for none: ' domain
  else
     domain=$fsmdomain
   fi

## Fetch salt for password encryption
  salt=$(get_user_salt "$fsmuser" "$fsmorg" "${domain:-Empty}")
  if [[ $? -gt 0 ]]; then
    echo "Unable to validate user $fsmuser"
  fi
  if [[ -n $salt ]]; then
## If the salt is empty, we assume it is a LDAP user and send the plain text password to the Super to digest.
    salted_password=$(echo -n "${salt}${pass}" | openssl dgst -sha1 | awk '{print $NF}' | tr '[:lower:]' '[:upper:]')
  fi
  cred='{"username":"'$fsmuser'","password":"'${salted_password:-$pass}'","domain":"'$fsmorg'","userDomain":'"${domain:-Empty}"'}'
  cookie=$(mktemp -u cookie.XXXXX)

## Send salted password to Super and if successful, store session variables
  result=$(curl -Ss $secure --http1.1 -c $cookie -H 'Content-Type: text/plain;charset=UTF-8' -H 'Connection: keep-alive' -XPOST "https://${fsmhost}/phoenix/rest/h5/sec/login?s=" --data-raw $cred | xargs)
  if [[ ${result,,} == "success" ]]; then
    session=($(grep -Pv '^(# |^$)' < $cookie | awk '{print $7}'))
    session[2]=$(echo -n "${session[0]}" | xxd -c 64 -u -p)
    base64_domain=$(base64 -w0 <<<"${domain:-Empty}")
    base64_session=$(encrypt_string "$salt" <<<"${session[@]}")
## We only want to store the users active session to file.  No credentials are ever saved to disk.
    echo "#${base64_domain}#${base64_session}" > .${fsmorg,,}_${fsmuser,,}.cred
    rm -f "$cookie"
  else
    echo "$result"
    rm -f .${fsmorg,,}_${fsmuser,,}.cred
    exit 1
  fi  
}

jq_lightvalueobjects='if .headerData.methodNames != null then
                         .headerData.methodNames as $header | 
                         .lightValueObjects |
                         map(([$header,.data] | transpose |
                         map({(first):(if last == "" then null else last end)}) | add) + del(.data))
		      else . end'

fsmapi() {
  local uri=$1

## If session variables are not valid, force user to authenticate
[[ -z ${session[0]} || -z ${session[1]} || -z ${session[2]} ]] && authenticate

## If uri contains a ?, make additional parameters start with &
  [[ $uri =~ \?[A-Za-z0-9]+\= ]] && query_joiner="&" || query_joiner="?"
  if [[ $uri =~ \/h5\/device\/query ]]; then
    curl --fail -Ss $secure "https://${fsmhost}${uri}${query_joiner}s=${session[2]}" --compressed -H "Cookie: JSESSIONID=${session[1]}; s=${session[0]}" -H 'Content-Type: application/json;charset=UTF-8' -H 'Accept: application/json, text/plain, */*' -H 'user-agent: FortiSIEM Rest Explorer' --data-raw '{"groupId":0}'
  else
    curl --fail -Ss $secure "https://${fsmhost}${uri}${query_joiner}s=${session[2]}" --compressed -H "Cookie: JSESSIONID=${session[1]}; s=${session[0]}" -H 'Content-Type: application/json;charset=UTF-8' -H 'Accept: application/json, text/plain, */*' -H 'user-agent: FortiSIEM Rest Explorer'
  fi
}

if [[ -z $url ]]; then
  echo "You must specify a base URL, example /h5/device/query"
  help
else
  if [[ $url =~ , ]]; then
    baseUrl=$(perl -pe 's/([^=]*[=\/]).*/\1/' <<< "$url")
    objects=($(perl -pe 's/[^=]*[=\/](.*)/\1/' <<< "$url" | tr ',' ' '))
    for i in ${!objects[@]}; do
      out_response[$i]=$(fsmapi ${baseUrl}${objects[$i]})
    done
  else
    out_response=$(fsmapi $url)
  fi
fi

## Once we have a valid repsonse, we check to see if it is an XML response and parse the output based on the content
if [[ $fetch_status == false ]]; then
  echo "Failed to fetch data from $uri"
  perl -pe 's/.*<h1>(.*)<\/h1>.*/\1\n/' <<< "${out_response[@]}"
  exit 1
fi
if [[ "$out_response" =~ ^\<\?xml|^\< ]]; then
  if $xmllint_enabled; then
    echo "${out_response[@]}" | xmllint --format -
  else
    echo "${out_response[@]}"
  fi

## If it is not XML then we can safely assume it is JSON.  If the system has jq installed, we will pipe the output through it for better visibility
## We are also using jq's slurp functionality to create one JSON payload.  If you would prefer seperate lines per record, remove the jq | -s below
elif [[ $out_response =~ ^\{|^\[ ]] && $jq_enabled; then
  jq "$jq_lightvalueobjects" <<< "${out_response[@]}" | jq -s
elif [[ $out_response =~ ^\{|^\[ ]]; then
  IFS=$'\n'
  echo "${out_response[*]}"
  echo
  echo "You can install jq for cleaner JSON output"
  echo "yum install -y jq"
else
  echo "${out_response[@]}"
fi
