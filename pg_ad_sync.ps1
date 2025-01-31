# Parameters must be first
Param (
    [switch]$Help=$false,
    [switch]$DropAdRoles=$false,
    [switch]$NoCaseRoles=$false,
	[switch]$DryRun=$false,
    [string]$PgHost="",
	[string]$PgPort="",
	[string]$PgDatabase="postgres",
	[string]$PgUser="",
	[string]$PgPassword=""
)
$ErrorActionPreference = "Stop"

# By Hans Schou 2019-05-08

if ($Help) {
	Write-Host @"
PostgreSQL Active Directory synchronization
https://github.com/hanschou/pg_ad_sync

Tool for automatic creating roles (users) in PosgreSQL which is defined in a Windows Active Directory group.

Options:
	-Help
		This help.
	  
	-DropAdRoles
		Default: False
		Drop all roles which has a special commment:
			'Created by pg_ad_sync.'

	-NoCaseRoles
		Default: False
		Do not create roles case sensitive. If roles are created case sensitive one has to logon with the exactly same casing.

	-DryRun
		Default: False
		Run without dropping or creating users in postgres. Only create the SQL file pg_ad_sync.tmp.sql
		
	-PgHost
		Default: Empty
		Hostname of the PostgreSQL database.
		
	-PgPort
		Default: Blank
		Port number of the PostgreSQL port.
		
	-PgDatabase
		Default: postgres
		Name of the PostgreSQL database.
		
	-PgUser
		Default: Blank
		Name of the PostgreSQL administrator.
		
	-PgPassword
		Default: Blank
		Password for the PostgreSQL administrator.

To get a group from the AD, a group with the same name has be created in PosgreSQL as a role.
The role in PostgreSQL has to have special comment for the script to be recognized.
Example an AD group called "PG-USERS":
  CREATE ROLE "PG-USERS";
  COMMENT ON ROLE "PG-USERS" IS 'This role is in sync with Active Directory.';
Double quote is required as the group name has hyphen in it.

Credentials:
  Username and password for PostgreSQL can be given on command line, in the environment or in credentials file.
  Command line:
	powershell.exe -File pg_ad_sync.ps1 -PgUser postgres -PgPassword p4zzw0rd
  Environment:
	SET PGUSER=postgres
	SET PGPASSWORD=p4zzw0rd
  Credentials file:
	Save the file as: %APPDATA%\postgresql\pgpass.conf
	Content:
	  localhost:5432:template1:postgres:p4zzw0rd

Hint: Get a list of the groups you are member of in the AD.
Invoke from within Powershell:
  ([ADSISEARCHER]"samaccountname=$($env:USERNAME)").Findone().Properties.memberof

Example output:
  CN=PG-ADMIN,OU=Admin,OU=Acme Inc,DC=example,DC=org
  CN=PG-USERS,OU=INF,OU=Acme Inc,DC=example,DC=org

PostgreSQL configuration. Enable LDAP.
 Add the following line to pg_hba.conf:
   host all all 10.0.0.0/8 ldap ldapserver=example.org ldapprefix="" ldapsuffix="@example.org"
"@
	Exit
}

$DayOfWeek=$(Get-Date -UFormat "%w")
$LogFile = "pg_ad_sync.$DayOfWeek.log"
$SqlFile = "pg_ad_sync.tmp.$DayOfWeek.sql"
if (Test-Path $LogFile) {
	Remove-Item -Path $LogFile
}
if (Test-Path $SqlFile) {
	Remove-Item -Path $SqlFile
}
Get-Date -Format "o" | Add-Content $LogFile

"\set ON_ERROR_STOP 0"  | Add-Content $SqlFile

$psql = "psql.exe"

if ($PgHost) {
	$psql = "$psql --host=$PgHost"
}
if ($PgPort) {
	$psql = "$psql --port=$PgPort"
}
if ($PgDatabase) {
	$psql = "$psql --dbname=$PgDatabase"
}
if ($PgUser) {
	$psql = "$psql --username=$PgUser"
}
if ($PgPassword) {
	$Env:PGPASSWORD="$PgPassword"
}
if (-not (Test-Path 'Env:PGPASSWORD')) {
	"Error: Environment variable PGPASSWORD and command line parameter '-PgPassword' is not set." | Add-Content $LogFile
	Exit
}
"PostgreSQL invocation: $psql" | Add-Content $LogFile

If (Test-Path $SqlFile) {
    Remove-Item -Path $SqlFile
}
if ($DropAdRoles) {
	"Warning, existing roles are dropped." | Add-Content $LogFile
	$command1 = @"
"SELECT 'DROP ROLE IF EXISTS """"' || rolname || '"""";' FROM pg_roles r JOIN pg_shdescription s ON (r.oid=s.objoid) WHERE s.description='Created by pg_ad_sync.' ORDER BY oid;"
"@
	Invoke-Expression "$psql --tuples-only --no-align --command=$command1" 2>&1 | Add-Content $SqlFile
	if (0 -ne $LASTEXITCODE) {
		"Error: Code $LASTEXITCODE invoking psql.exe" | Add-Content $LogFile
		Exit
	}
}

"Getting list from AD:" | Add-Content $LogFile
Invoke-Expression "$psql --tuples-only --no-align --command=""SELECT rolname FROM pg_roles r JOIN pg_shdescription s ON (r.oid=s.objoid) WHERE s.description='This role is in sync with Active Directory.'""" |
    ForEach-Object {
        $role = $_
        "-- Role: $role" | Add-Content $SqlFile
        $search = [adsisearcher][ADSI]""
        $search.Filter = "(&(objectclass=group)(cn=$role))" # LDAP syntax
        $search.FindOne().GetDirectoryEntry() |
            select -ExpandProperty member | # expand to distinguishedname
                ForEach-object {  # for each member in the group
                    $searcher = [adsisearcher]"(distinguishedname=$_)"
                    $member = $searcher.FindOne().Properties.samaccountname
					if ($member -iMatch "postgres" -Or $member -iMatch "^Skabelon.*") {
						"-- Reserved word, skipping member: $member" | Add-Content $SqlFile
					} else {
						if (-Not $NoCaseRoles -Or $member -Match "-") {
							$member = """$member"""
						} else {
							$member = "$member".ToLower()
						}
						"CREATE ROLE $member WITH LOGIN;" | Add-Content $SqlFile
						"COMMENT ON ROLE $member IS 'Created by pg_ad_sync.';" | Add-Content $SqlFile
						"GRANT ""$role"" TO $member;" | Add-Content $SqlFile
					}
                }
    }
if (0 -ne $LASTEXITCODE) {
	"Error: Code $LASTEXITCODE invoking psql.exe" | Add-Content $LogFile
	Exit
}

if ($DryRun) {
	"-- Running: DryRun" | Add-Content $LogFile
} else {
	"Running '$SqlFile':" | Add-Content $LogFile
	# Ignore errors when user already exist
	$ErrorActionPreference = "Continue"
	Invoke-Expression "$psql --echo-all --file=$SqlFile" 2>&1 | Add-Content $LogFile
}
if (0 -ne $LASTEXITCODE) {
	"Error: Code $LASTEXITCODE invoking psql.exe" | Add-Content $LogFile
	Exit
}

Get-Date -Format "o" | Add-Content $LogFile