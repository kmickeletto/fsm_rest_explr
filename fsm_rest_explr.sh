#!/bin/bash

if which jq &>/dev/null; then
  jq_enabled=true
else
  jq_enabled=false
fi

shutdown() {
  if [[ -n $cookie ]]; then
    rm -f $cookie
    exit $1
  fi
}
trap shutdown EXIT

help() {
  echo "Here are some sample endpoints to query"
## If you want to search through the FortiSIEM Apache logs instead, uncomment this line
#  zcat /etc/httpd/logs/ssl_request_log* 2>/dev/null | awk '{print $6"|"$7"|"$9}' | grep -Pv '\|4..$' | grep -P 'GET' | cut -f1 -d'?' | grep '\/rest\/' | grep -v '\/h5\/report\/' | awk -F'|' '{print $2}' | sort | uniq | pr -t3 -w$(tput cols)
## And comment this line out
  curl https://raw.githubusercontent.com/kmickeletto/fsm_rest_explr/main/endpoints.list | sort | uniq | pr -t2 -w$(tput cols)
  exit 0
}

if [[ $1 =~ ^(--help|help)$ ]]; then
  help
fi

get_user_salt() {
  local user=$1
  local org=$2
  local domain=$3
  local result

  result=$(curl -sk 'https://localhost/phoenix/rest/h5/sec/loginInfo?s=' -H 'Connection: keep-alive' -H 'Content-Type: text/plain;charset=UTF-8' --data-raw '{"userName":"'$user'","organization":"'$org'","domain":"'${domain:-Empty}'"}')
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
  if [[ -f .${fsmorg,,}_${fsmuser,,}.cred ]]; then
    domain=$(awk -F'#' '{print $2}' ".${fsmorg,,}_${fsmuser,,}.cred" | base64 -d 2>/dev/null)
    salt=$(get_user_salt "${fsmuser,,}" "${fsmorg,,}" "${domain}")
    [[ $? -gt 0 ]] && rm -f ".${fsmorg,,}_${fsmuser,,}.cred" && exec $(basename $0) $url 
    session=($(awk -F'#' '{print $3}' ".${fsmorg,,}_${fsmuser,,}.cred" | decrypt_string $salt))
    logged_in=$(curl --fail -sk "https://localhost/phoenix/rest/h5/sec/isLoggedIn?s=${session[2]}" --compressed -H "Cookie: JSESSIONID=${session[1]}; s=${session[0]}" -H 'Content-Type: application/json;charset=UTF-8' -H 'Accept: application/json, text/plain, */*' -H 'user-agent: FortiSIEM Rest Explorer' | perl -pe 's/.*loggedIn":"([^"]*).*/\1/')
    if [[ ${logged_in,,} == true ]]; then
      return
    else
      echo "Session timed out, please authenticate to continue"
    fi
  fi
  if [[ -z $fsmuser ]] || [[ -z $fsmorg ]]; then
    echo "If you export your username and org, you can bypass authenticating each time."
    echo "export user=org/user"
    echo
  fi
  [[ -z $fsmuser ]] && read -p 'Enter your username: ' fsmuser || echo "Username: $fsmuser"
  read -sp 'Enter your password: ' pass && echo
  [[ -z $fsmorg ]] && read -e -i Super -p 'Enter your org: ' fsmorg
  [[ -z $domain ]] && read -p 'Enter your LDAP domain, blank for none: ' domain

## Fetch salt for password encryption
  salt=$(get_user_salt "$fsmuser" "$fsmorg" "${domain:-Empty}")
  if [[ -z $salt ]]; then
    password="$pass"
  else
## If the salt is empty, we assume it is a LDAP user and send the plain text password to the Super to digest.
    password=$(echo -n "${salt}${pass}" | openssl dgst -sha1 | awk '{print $NF}' | tr '[:lower:]' '[:upper:]')
  fi
  cred='{"username":"'$fsmuser'","password":"'$password'","domain":"'$fsmorg'","userDomain":'"${domain:-Empty}"'}'
  cookie=$(mktemp -u cookie.XXXXX)

## Send salted password to Super and if successful, store session variables
  result=$(curl -sk --http1.1 -c $cookie -H 'Content-Type: text/plain;charset=UTF-8' -H 'Connection: keep-alive' -XPOST 'https://localhost/phoenix/rest/h5/sec/login?s=' --data-raw $cred | xargs)
  if [[ ${result,,} == "success" ]]; then
    session=($(grep -Pv '^(# |^$)' < $cookie | awk '{print $7}'))
    session[2]=$(echo -n "${session[0]}" | xxd -c 64 -u -p)
    base64_domain=$(base64 -w0 <<<"${domain:-Empty}")
    base64_session=$(encrypt_string "$salt" <<<"${session[@]}")
    echo "#${base64_domain}#${base64_session}" > .${fsmorg,,}_${fsmuser,,}.cred
  else
    echo "$result"
    rm -f $cookie .${fsmorg,,}_${fsmuser,,}.cred
    exit 1
  fi  
}

device_query_jq='.headerData.methodNames as $header | 
                 .lightValueObjects |
                 map(([$header,.data] | transpose |
                 map({(first):(if last == "" then null else last end)}) | add) + del(.data))'

fsmapi() {
  local uri=$1

## If session variables are not valid, force user to authenticate
  [[ -z $session[0] || $session[1] || $session[2] ]] && authenticate
  if [[ $uri =~ \/device\/query$ ]]; then
    response=$(curl --fail -sk "https://localhost${uri}?s=${session[2]}" --compressed -H "Cookie: JSESSIONID=${session[1]}; s=${session[0]}" -H 'Content-Type: application/json;charset=UTF-8' -H 'Accept: application/json, text/plain, */*' -H 'user-agent: FortiSIEM Rest Explorer' --data-raw '{"groupId":0}')
    $jq_enabled && response=$(jq "$device_query_jq" <<< $response)
  else
    response=$(curl --fail -sk "https://localhost${uri}?s=${session[2]}" --compressed -H "Cookie: JSESSIONID=${session[1]}; s=${session[0]}" -H 'Content-Type: application/json;charset=UTF-8' -H 'Accept: application/json, text/plain, */*' -H 'user-agent: FortiSIEM Rest Explorer')
  fi
  if [[ $? -gt 0 ]]; then
    echo "Failed to fetch data from $uri"
    curl -sk "https://localhost${uri}?s=${session[2]}" --compressed -H "Cookie: JSESSIONID=${session[1]}; s=${session[0]}" -H 'Content-Type: application/json;charset=UTF-8' -H 'Accept: application/json, text/plain, */*' -H 'user-agent: FortiSIEM Rest Explorer' | perl -pe 's/.*<h1>(.*)<\/h1>.*/\1\n/'
    exit 1
  fi

## Once we have a valid repsonse, we check to see if it is an XML response and parse the output based on the content
  if [[ "$response" =~ ^\<\?xml|^\< ]]; then
        echo "$response" | xmllint --format -

## If it is not XML then we can safely assume it is JSON.  If the system has jq installed, we will pipe the output through it for better visibility
  elif [[ $response =~ ^\{|^\[ ]] && $jq_enabled; then
      jq . <<< $response
  elif [[ $response =~ ^\{|^\[ ]]; then
    echo $response
    echo
    echo "You can install jq for cleaner JSON output"
    echo "yum install -y jq"
  else
    echo $response
  fi
}

url=$1
if [[ -z $url ]]; then
  echo "You must specify a base URL, example /h5/device/query"
  help
else
  if [[ $u =~ , ]]; then
    baseUrl=$(perl -pe 's/(.*\/).*/\1/'  <<< "$url")
    objects=($(perl -pe 's/.*\/(.*)/\1/'  <<< "$url" | tr ',' ' '))
    for object in ${objects[@]}; do
      fsmapi ${baseUrl}${object}
    done
  else
    fsmapi $url
  fi
fi
