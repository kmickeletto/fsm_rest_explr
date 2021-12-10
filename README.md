# fsm_rest_explr
fsm_test_explr is a simple command line tool to view data from the FortiSIEM internal API.

## Requirements
Access to the Supervisor via HTTPS

## Options
For requests that fetch data from the API by Id, `/phoenix/exportReport?reportIds=123456`,
you can add multiple Id's separated by commas.  `/phoenix/exportReport?reportIds=123456,987654`

### Options as exported variables
You can export any of the following variables.
```
export fsmuser=org/myuser
export fsmhost=fortisiem.somecompany.com
```

### Options as switches
     --fsmdomain|-d,	LDAP domain for user account
	 --fsmorg|-o,		FortiSIEM org for user account
	 --fsmhost|-h,		FortiSIEM Supervisor
	 --passwd,		use is discouraged but if you need a completely automated solution it will work
	 --insecure|-i,		don't attempt to validate Supervisor certificate

## Usage
```
./fsm_rest_explr /phoenix/exportReport?reportIds=123456
```
