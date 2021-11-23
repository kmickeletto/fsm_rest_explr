#!/bin/bash

if which jq &>/dev/null; then
  jq_enabled=true
fi

help() {
  echo "Here are some sample endpoints to query"
  zcat /etc/httpd/logs/ssl_request_log* 2>/dev/null | awk '{print $6"|"$7"|"$9}' | grep -Pv '\|4..$' | grep -P 'GET' | cut -f1 -d'?' | grep '\/rest\/' | grep -v '\/h5\/report\/' | awk -F'|' '{print $2}' | sort | uniq | pr -t3 -w$(tput cols)
  exit 0
}

if [[ $1 =~ ^(--help|help)$ ]]; then
  help
fi

authenticate() {
  local cookie
  local result
  local salt
  local pass
  local password
  local domain

## If user has already authenticated, attempt to read previous session from disk.  If session is no longer active, force re-auth
  if [[ -f .${org,,}_${user,,}.cred ]]; then
    session=($(<.${org,,}_${user,,}.cred))
    logged_in=$(curl --fail -sk "https://localhost/phoenix/rest/h5/sec/isLoggedIn?s=${session[2]}" --compressed -H "Cookie: JSESSIONID=${session[1]}; s=${session[0]}" -H 'Content-Type: application/json;charset=UTF-8' -H 'Accept: application/json, text/plain, */*' -H 'user-agent: FortiSIEM Rest Explorer' | perl -pe 's/.*loggedIn":"([^"]*).*/\1/')
    if ${logged_in,,}; then
      return
    else
      echo "Session timed out, please authenticate to continue"
    fi
  else
    echo "If you export your username and org, you can bypass authenticating each time."
    echo "export user="
    echo "export org="
    echo
  fi
  [[ -z $user ]] && read -p 'Enter your username: ' user || echo "Username: $user"
  read -sp 'Enter your password: ' pass && echo
  [[ -z $org ]] && read -e -i Super -p 'Enter your org: ' org
  read -p 'Enter your LDAP domain, blank for none: ' domain

## Fetch salt for password encryption
  salt=$(curl -sk 'https://localhost/phoenix/rest/h5/sec/loginInfo?s=' -H 'Connection: keep-alive' -H 'Content-Type: text/plain;charset=UTF-8' --data-raw '{"userName":"'$user'","organization":"'$org'","domain":"'${domain:-Empty}'"}' | perl -pe 's/{"salt":"([^"]*)"}/\1/')
  password=$(echo -n "${salt}${pass}" | openssl dgst -sha1 | awk '{print $NF}' | tr '[:lower:]' '[:upper:]')
  cred='{"username":"'$user'","password":"'$password'","domain":"'$org'","userdomain":'"${domain:-Empty}"'}'
  cookie=$(mktemp -u cookie.XXXXX)

## Send salted password to Super and if successful, store session variables
  result=$(curl -sk --http1.1 -c $cookie -H 'Content-Type: text/plain;charset=UTF-8' -H 'Connection: keep-alive' -XPOST 'https://localhost/phoenix/rest/h5/sec/login?s=' --data-raw $cred | xargs)
  if [[ ${result,,} == "success" ]]; then
    session=($(grep -Pv '^(# |^$)' < $cookie | awk '{print $7}'))
    session[2]=$(echo -n "${session[0]}" | xxd -c 64 -u -p)
    echo ${session[@]} > .${org,,}_${user,,}.cred
  else
    echo "$result"
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
#  [[ $uri =~ ^\/phoenix ]] && uri=${uri#/phoenix}
#  [[ $uri =~ ^\/rest ]] && uri=${uri#/rest}
#  [[ $uri =~ ^\/h5 ]] && uri=${uri#/h5}
  if [[ $uri =~ \/device\/query$ ]]; then
    response=$(curl --fail -sk "https://localhost${uri}?s=${session[2]}" --compressed -H "Cookie: JSESSIONID=${session[1]}; s=${session[0]}" -H 'Content-Type: application/json;charset=UTF-8' -H 'Accept: application/json, text/plain, */*' -H 'user-agent: FortiSIEM Rest Explorer' --data-raw '{"groupId":0}')
    $jq_enabled && response=$(jq "$device_query_jq" <<< $response)
  else
    response=$(curl --fail -sk "https://localhost${uri}?s=${session[2]}" --compressed -H "Cookie: JSESSIONID=${session[1]}; s=${session[0]}" -H 'Content-Type: application/json;charset=UTF-8' -H 'Accept: application/json, text/plain, */*' -H 'user-agent: FortiSIEM Rest Explorer')
  fi
  if [[ $? -gt 0 ]] && [[ $jq_enabled ]]; then
    echo "Failed to fetch data from $uri"
    curl -sk "https://localhost${uri}?s=${session[2]}" --compressed -H "Cookie: JSESSIONID=${session[1]}; s=${session[0]}" -H 'Content-Type: application/json;charset=UTF-8' -H 'Accept: application/json, text/plain, */*' -H 'user-agent: FortiSIEM Rest Explorer' | perl
-pe 's/.*<h1>(.*)<\/h1>.*/\1\n/'
  fi

## Once we have a valid repsonse, we check to see if it is an XML response and parse the output based on the content
  if [[ "$response" =~ ^\<\?xml|^\< ]]; then
        echo "$response" | xmllint --format -

## If it is not XML then we can safely assume it is JSON.  If the system has jq installed, we will pipe the output through it for better visibility
  elif $jq_enabled; then
      jq . <<< $response
  else
    echo $response
    echo
    echo "You can install jq for cleaner JSON output"
    echo "yum install -y jq"
  fi
}

if [[ -z $1 ]]; then
  echo "You must specify a base URL, example /h5/device/query"
  help
else
  fsmapi $1
fi
