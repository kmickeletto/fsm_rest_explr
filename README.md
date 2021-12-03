# fsm_rest_explr
fsm_test_explr is a simple command line tool to view data from the FortiSIEM internal API.

## Requirements
Access to the Supervisor via HTTPS

## Options

### Options as exported variables
You can export any of the following variables.
1. export fsmuser=myuser
2. export fsmorg=myorg
3. export fsmhost=fortisiem.somecompany.com

### Options as switches
     --fsmdomain|-d, LDAP domain for user account
	 --fsmorg|-o, FortiSIEM org for user account
	 --fsmhost|-h, FortiSIEM Supervisor
	 --passwd, use is discouraged but if you need a completely automated solution it will work
	 --insecure|-i, don't attempt to validate Supervisor certificate