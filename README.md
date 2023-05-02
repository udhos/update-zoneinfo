# update-zoneinfo

update-zoneinfo is Perl script that keeps zoneinfo up-to-date.

It automatically:

1. Fetches zoneinfo definition from URL given in command line.
2. Compiles (with zic) and installs the new zoneinfo definition.
3. Adjusts the local timezone as specified in command line.
4. Optionally installs itself in the crontab for daily execution, so newer zoneinfo definitions can be automatically updated.

The script activity is issued both to stderr and to syslog.

Currently supported platforms:

    Linux
    Solaris

Previous home: http://nucleo.freeservers.com/update-zoneinfo/
