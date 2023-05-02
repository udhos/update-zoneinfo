#! /usr/bin/env perl
#
# update-zoneconfig
# Copyright (C) 2003 Everton da Silva Marques
#
# update-zoneconfig is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License as
# published by the Free Software Foundation; either version 2, or (at
# your option) any later version.
#
# update-zoneconfig is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with update-zoneconfig; see the file COPYING. If not, write to
# the Free Software Foundation, Inc., 51 Franklin St, Fifth Floor,
# Boston, MA 02110-1301 USA.
#
# $Id$

# This script automatically:
# 1. Fetches zoneinfo definition from URL given in command line
# 2. Compiles (with zic) and installs the new zoneinfo definition
# 3. Adjusts the local timezone as specified in command line
# 4. Optionally installs itself in the crontab for daily execution,
#    so newer zoneinfo definitions can be automatically updated
# The script activity is issued both to stderr and to syslog

# Currently supported platforms:
# - Linux
# - Solaris

# Contact:
#
# Everton da Silva Marques <everton.marques@gmail.com>

# Version Changes
#
# 0.1     first release
# 0.2     try wget as fallback for missing LWP::Simple
# 0.3     support for locally available zoneinfo definition
# 0.4     multiple command-line URLs
# 0.5     option -pipe-filter= to extract zoneinfo from tarball
#         (see usage example for tzdata2007g.tar.gz)
# 0.6     option -ignore-unpack-failure to continue after
#         failures in the -pipe-filter= command
# 0.7     -install passes all cmd line arguments to crontab
#         -quiet option for silent operation
# 0.8     cmd-line brief help
# 0.9     debug for temporary directory
# 0.10    example URL to ftp://elsie.nci.nih.gov/pub/tzdata2007h.tar.gz
# 0.11    example URL to ftp://elsie.nci.nih.gov/pub/tzdata2007k.tar.gz
# 0.12    example URL to ftp://elsie.nci.nih.gov/pub/tzdata2008b.tar.gz
# 0.13    example URL to ftp://elsie.nci.nih.gov/pub/tzdata2008b.tar.gz
# 0.14    example URL to ftp://elsie.nci.nih.gov/pub/tzdata2008e.tar.gz
# 0.15    example URL to ftp://elsie.nci.nih.gov/pub/tzdata2008f.tar.gz
# 0.16    backup existing zoneinfo before running
#         -no-backup reverts to old (backup-less) behavior
# 0.17    example URL to ftp://elsie.nci.nih.gov/pub/tzdata2008g.tar.gz
#         now southamerica America/Sao_Paulo is correct up to year 2038

my $version = '0.17';

use warnings;
use strict;

###############
# Config Start
#

my $linux_tz_link = '/etc/localtime';
#my $linux_tz_link = 'localtime';

my $solaris_tz_def = '/etc/default/init';
#my $solaris_tz_def = 'TIMEZONE';

my $install_dir = '/usr/local/sbin';
#my $install_dir = 'sbin';

my %zoneinfo_table = (
		      #linux =>   'zoneinfo',
		      #solaris => 'zoneinfo',
		      linux =>   '/usr/share/zoneinfo',
		      solaris => '/usr/share/lib/zoneinfo',
		      );

#
# Config End
#############

my $timezone_file = '/tmp/timezones.zic';
my $crontab_file = '/tmp/crontab.tmp';

my $zic_path = '/usr/sbin/zic';
my $sed_path = '/bin/sed';
my $crontab_path = '/usr/bin/crontab';
my $logger_path = '/usr/bin/logger';
my $cp_path = '/bin/cp';
my $cmp_path = '/usr/bin/cmp';
my $mv_path = '/bin/mv';
my $cat_path = '/bin/cat';

#my $me = `basename $0`;
my $me = 'update-zoneinfo';
chomp $me;

my $install_path = "$install_dir/$me";

my $verbose = 1;

sub stderr_to_null {
    my ($cmd) = @_;
    if (!$verbose) {
	$cmd .= ' 2>/dev/null';
    }
    $cmd;
}

sub say {
    foreach (@_) {
	my $msg = "$me: $_\n";
	warn $msg;
	if ($msg =~ /\"/) {
	    warn "$me: internal failure: say() can't send lines with double-quotes (\") to syslog\n";
	    return;
	}
	-x $logger_path && system("$logger_path -- \"$msg\"");
    }
}

sub info {
    &say(@_) if $verbose;
}

my $perform_cleanup = 1; # true

sub cleanup {
    #
    # use '-no-cleanup' to disable this in order to ease debugging
    #
    if ($perform_cleanup) {
	-f $timezone_file && unlink $timezone_file;
	-f $crontab_file && unlink $crontab_file;
    }
}

sub abort {
    &say(@_);
    &say("aborting");
    &cleanup;
    exit(1);
}

sub set_timezone {
    my ($osname, $zoneinfo_dir, $timezone_name) = @_;

    my $tz_file = "$zoneinfo_dir/$timezone_name";

    -f $tz_file || &abort("missing timezone file: $tz_file");

    if ($osname eq 'linux') {

	if (-l $linux_tz_link) {
	    my $old_dst = readlink $linux_tz_link;

	    if (!defined($old_dst)) {
		&abort("could not read linux timezone link: $linux_tz_link: $!");
	    }

	    if ($old_dst eq $tz_file) {
		&info("nothing to do, linux timezone link is already correct: $linux_tz_link->$tz_file");
		return;
	    }
	}

	&info("removing old timezone link: $linux_tz_link");
	my $deleted = unlink $linux_tz_link;
	if ($deleted != 1) {
	    &abort("could not remove old timezone link: $linux_tz_link: $!");
	}

	&info("creating new linux timezone link: $linux_tz_link->$tz_file");

	symlink($tz_file,$linux_tz_link) || &abort("could not create new timezone link: $linux_tz_link->$tz_file: $!");
	return;
    }

    if ($osname eq 'solaris') {

	my $tz_def = "TZ=$timezone_name";

	my $done = 0;
	local *IN;
	open(IN, "<$solaris_tz_def") || &abort("could not read solaris timezone definition: $solaris_tz_def: $!");
	while (<IN>) {
	    chomp;
	    next if /^\s*($|\#)/;
	    if (/^TZ=(.+)/) {
		if ($1 eq $timezone_name) {
		    ++$done;
		    last;
		}
	    }
	}
	close IN;
	if ($done) {
	    &info("solaris timezone is correctly set as $tz_def in: $solaris_tz_def");
	    return;
	}

	&info("adding $tz_def to $solaris_tz_def");

	my $cmd = "$^X -pi'.bak' -e 's{TZ=.+}{$tz_def}' $solaris_tz_def";

	&info("$cmd");

	system($cmd);
	{
	    my $ret = $?;
	    if ($ret) {
		&abort("TZ replacement failed: $cmd: status: $?");
	    }
	}

	return;
    }

    &say("can't set timezone for OS: $osname");
}

sub search_wget {
    my $wget_path = `which wget`;
    chomp $wget_path;
    $wget_path;
}

sub http_download {
    my ($zoneinfo_url, $timezone_file) = @_;

    &info("fetching timezone definition from URL $zoneinfo_url to file $timezone_file");

    if (-e $timezone_file) {
	if (! -w $timezone_file) {
	    &say("WARNING: can't overwrite existing temporary file, download will fail: $timezone_file");
	}
    }

    if (-r $zoneinfo_url) {

	&info("$zoneinfo_url is available on filesystem");

	my $cmd = "$cp_path $zoneinfo_url $timezone_file";
	&info($cmd);
	system($cmd);
	{
	    my $ret = $?;
	    if ($ret) {
		&say("copy failed: $cmd: status: $?");
		return 1;
	    }
	}

	&info("timezone definition copied");

	return 0; # success
    }

    if (eval "require LWP::Simple") {

	&info("downloading with: LWP::Simple");

	my $http_response = LWP::Simple::getstore($zoneinfo_url, $timezone_file);
	if (LWP::Simple::is_error($http_response)) {
	    &say("error fetching timezone definition: HTTP response: $http_response");
	    return 1;
	}
	if (!LWP::Simple::is_success($http_response)) {
	    &say("could not fetch timezone definition: HTTP response: $http_response");
	    return 1;
	}

	&info("timezone definition downloaded - HTTP response: $http_response");

	return 0; # success
    }

    &say("LWP::Simple unavailable");

    my $wget_path = &search_wget;
    if ($wget_path !~ /\S/) {
	&say("wget unavailable - program not found");
	return 1;
    }
    if (! -x $wget_path) {
	&say("wget unavailable - could not execute: $wget_path");
	return 1;
    }

    my $cmd = "$wget_path -O $timezone_file $zoneinfo_url";
    &info("downloading with wget: $cmd");

    my $full_cmd = "$cmd 2>&1";
    if (!open(IN, "$full_cmd |")) {
	&say("could not run wget: $full_cmd: $!");
	return 1;
    }

    my $http_response;
    my $saved = 0; # false

    while (<IN>) {
	chomp;
	if (/^HTTP request sent, awaiting response\.\.\. (.*)$/) {
	    $http_response = $1;
	    next;
	}
	if (/ saved \[/) {
	    $saved = 1; # true
	    next;
	}
    }

    close IN;

    if (defined($http_response)) {
	&info("HTTP response: $http_response");
    }

    if ($saved) {
	&info("timezone definition downloaded");
	return 0; # success
    }

    &say("wget failed fetching URL $zoneinfo_url to file $timezone_file");

    1; # failure
}

my $pipe_filter;
my $abort_on_unpack_failure = 1; # true

sub zoneinfo_unpack {
    my ($timezone_file) = @_;

    return 0 unless defined($pipe_filter);

    my $orig = $timezone_file . '.orig.tgz';

    &info("applying pipe filter [$pipe_filter] to: $timezone_file");

    my $cmd;

    if (-e $orig) {
        if (! -w $orig) {
            &say("WARNING: can't overwrite existing unfiltered file, pipe filter will fail: $timezone_file");
        }
    }

    $cmd = "$mv_path -f $timezone_file $orig";
    &info($cmd);
    system($cmd);
    {
        my $ret = $?;
        if ($ret) {
	    &say("zoneinfo_unpack failed: $cmd: ret=$?");
	    return 1;
        }
    }

    my $result = 0;

    $cmd = "$cat_path $orig | $pipe_filter > $timezone_file";
    $cmd = &stderr_to_null($cmd);
    &info($cmd);
    system($cmd);
    {
        my $ret = $?;
        if ($ret) {
	    &say("zoneinfo_unpack failed: $cmd: ret=$?");
            if ($abort_on_unpack_failure) {
                &say("aborting after unpack failure... (consider option -ignore-unpack-failure)");
                $result = 1;
            }
            else {
                &say("persisting after unpack failure... (using option -ignore-unpack-failure)");
            }
        }
    }

    if ($perform_cleanup) {
	&info("removing temporary file: $orig");
	my $deleted = unlink $orig;
	if ($deleted != 1) {
	    &say("could not remove temporary file: $linux_tz_link: $!");
	}
    }

    $result;
}

my @zoneinfo_url_list;

my $backup_old_zoneinfo = 1; # defaults to true

sub fetch_timezone {
    my ($zoneinfo_url, $timezone_file, $timezone_name, $zoneinfo_dir) = @_;

    if (&http_download($zoneinfo_url, $timezone_file)) {
	# failure downloading
	return 0;
    }

    if (&zoneinfo_unpack($timezone_file)) {
	# failuring applying unpack pipe filter
	return 0;
    }
    
    # # Zone  NAME                    GMTOFF  RULES/SAVE      FORMAT  [UNTIL]
    # Zone    Brazil/DeNoronha        -2:00   Brazil          BRE%sT
    # Zone    posix/Brazil/DeNoronha  -2:00   Brazil          BRE%sT
    
    my $tz_offset;
    local *IN;
    if (!open(IN, "<$timezone_file")) {
	&say("could not read timezone file: $timezone_file: $!");
	return 0;
    }
    while (<IN>) {
	chomp;
	next if /^\s*($|\#)/;
	if (/Zone\s+(\S+)\s+(\S+)/) {
	    my ($tz_name, $tz_off) = ($1, $2);
	    if ($tz_name eq $timezone_name) {
		$tz_offset = $tz_off;
		last;
	    }
        }
    }
    close IN;
    if (!defined($tz_offset)) {
        &say("timezone $timezone_name not found in definition file: $timezone_file");
	return 0;
    }
    &info("standard GMT offset for timezone $timezone_name: $tz_offset");

    if ($backup_old_zoneinfo) {
	my $now = `date +%Y%m%d-%H%M%S`; chomp $now;
	my $backup_zoneinfo_dir = "$zoneinfo_dir.backup-$now";
	&info("saving old zoneinfo dir $zoneinfo_dir into backup dir: $backup_zoneinfo_dir");
	my $cmd = "$mv_path $zoneinfo_dir $backup_zoneinfo_dir";
	&info($cmd);
	system($cmd);
	{
	    my $ret = $?;
	    if ($ret) {
		&say("could not save old zoneinfo dir: $cmd: ret=$?");
		return 0;
	    }
	}
    }
    
    &info("compiling timezone definition from file $timezone_file to zoneinfo dir: $zoneinfo_dir");
    
    my $cmd = "$zic_path -d $zoneinfo_dir $timezone_file";
    &info($cmd);
    system($cmd);
    {
        my $ret = $?;
        if ($ret) {
	    &say("zic compilation failed: $cmd: ret=$?");
	    return 0;
        }
    }

    1; # successfully fetched
}

sub get_file_size {
    my ($dev,$ino,$mode,$nlink,$uid,$gid,$rdev,$size,
     $atime,$mtime,$ctime,$blksize,$blocks)
	= stat($_[0]);

    if (defined($size)) {
	return $size;
    }

    -1; # could not get file size
}

sub copy_script {

    if (-f $install_path) {
	my $cmd = "$cmp_path $0 $install_path >/dev/null";
	$cmd = &stderr_to_null($cmd);
	&info($cmd);
	system($cmd);
	my $ret = $?;
	if (!$ret) {
	    &info("script at $install_path is up to date");
	    return;
	}

	&info("updating script at $install_path");
    }

    my $cmd = "$cp_path $0 $install_path";
    &info($cmd);
    system($cmd);
    {
        my $ret = $?;
        if ($ret) {
	    &abort("copy failed: $cmd: status: $?");
        }
    }

}

sub install_crontab {
    my ($timezone_name, @url_list) = @_;

    &info("installing script in crontab as $install_path");

    #
    # Save crontab size
    #

    my $crontab_size = 0;
    local *IN;
    my $in_pipe = "$crontab_path -l";
    $in_pipe = &stderr_to_null($in_pipe);
    open (IN, "$in_pipe |") || &abort("can't open pipe for reading: $in_pipe: $!");
    while (<IN>) {
	$crontab_size += length;
    }
    close IN;
    &info("current crontab size: $crontab_size bytes");

    #
    # Copy script to install dir
    #

    &copy_script;

    #
    # Dump crontab to disk
    #

    my $ctab_empty = 0; # false
    
    my $cmd = "$crontab_path -l >$crontab_file";
    $cmd = &stderr_to_null($cmd);
    &info($cmd);
    system($cmd);
    {
        my $ret = $?;
	if ($ret == 256) {
	    &info("proceeding with empty crontab: $cmd: status: $ret");
	    $ctab_empty = 1; # true
	}
        elsif ($ret) {
	    &abort("crontab dump failed: $cmd: status: $ret");
        }
    }

    #
    # Check crontab size
    #

    my $size = &get_file_size($crontab_file);
    if ($size < 0) {
	&abort("could not get crontab dump size");
    }

    if ($size != $crontab_size) {
	&abort("incorrect crontab dump size: $size bytes");
    }

    if ($ctab_empty) {
	if ($size != 0) {
	    &abort("crontab is empty but dump file has a size (!)");
	}
    }

    #
    # Already installed in crontab?
    #

    my $already_installed = 0;
    open (IN, "<$crontab_file") || &abort("can't open for reading: $in_pipe: $!");
    while (<IN>) {
	next if /^\s*($|\#)/;
	my ($a, $b, $c, $d, $e, $path) = split;
	if ($path eq $install_path) {
	    ++$already_installed;
	}
    }
    close IN;

    if ($already_installed) {
	&info("no need to reinstall script in crontab");
	return;
    }

    #
    # Append crontab command to crontab file
    #

    my $ctab_line = "0 0 * * * $install_path";
    foreach my $arg (@ARGV) {
	next if ($arg =~ /-install/); # skip install option
	if ($arg =~ /\s/) {
	    $ctab_line .= " '" . $arg . "'"; # quote-escaped
	}
	else {
	    $ctab_line .= ' ' . $arg;
	}
    }
    $ctab_line .= ' >/dev/null';
    $ctab_line = &stderr_to_null($ctab_line);

    local *OUT;
    open(OUT, ">>$crontab_file") || &abort();
    print OUT $ctab_line, "\n";
    close OUT;

    #
    # Install new crontab
    #

    $cmd = "$crontab_path $crontab_file";
    &info($cmd);
    system($cmd);
    {
        my $ret = $?;
        if ($ret) {
	    &abort("crontab installation failed: $cmd: status: $?");
        }
    }

    &info("installed in crontab as: $ctab_line");
}

sub show_usage {
    my ($out) = @_;

    print $out <<__EOF__;
usage: $me [-help] [-version] [-install] [-quiet] [-no-backup] [-pipe-filter=cmd] [-ignore-unpack-failure] timezone zoneinfo_url_1 [ ... zoneinfo_url_n ]

  -install:     if given, the script will install itself in the
                crontab so new zoneinfo definitions can be
                automatically updated in a daily basis

  -pipe-filter: shell command to extract zoneinfo from tarball

examples:

  $me America/Sao_Paulo http://avi.alkalay.net/software/zoneinfo/Brazil.txt

  $me -pipe-filter='gunzip -c | tar xOf - southamerica' America/Sao_Paulo ftp://elsie.nci.nih.gov/pub/tzdata2008g.tar.gz

notice: in the -pipe-filter example, the tar 'O' option requires GNU tar

__EOF__
}

#
# Check environment
#

my @tmp_env = ('TMPDIR', 'TMP', 'TEMP');
my @tmp_list;
foreach (@tmp_env) {
    my $dir = $ENV{$_};
    if (defined($dir)) {
	push @tmp_list, $dir;
    }
}

my $tmp_dir;
foreach (@tmp_list, '/tmp') {
    if (! -d $_) {
	&say("temporary directory: $_: not a directory");
	next;
    }
    if (! -w $_) {
	&say("temporary directory: $_: missing write permission");
	next;
    }
    $tmp_dir = $_;
    last;
}
defined($tmp_dir) || &abort("undefined temporary directory");

# override defaults
$timezone_file = "$tmp_dir/timezones.zic";
$crontab_file = "$tmp_dir/crontab.tmp";

-x $zic_path || &abort("zic compiler not found: $zic_path");
-x $sed_path || &abort("sed not found: $sed_path");
-x $logger_path || &abort("logger not found: $logger_path");
my $osname = $^O;
my $zoneinfo_dir = $zoneinfo_table{$osname};
defined($zoneinfo_dir) || &abort("unknown OS: $osname");
-d $zoneinfo_dir || &abort("zoneinfo dir not found: $zoneinfo_dir");

if ($osname eq 'linux') {
    -f $linux_tz_link || &abort("missing linux timezone link: $linux_tz_link");
}
elsif ($osname eq 'solaris') {
    -f $solaris_tz_def || &abort("missing solaris timezone definition: $solaris_tz_def");
}
else {
    &abort("refusing to proceed on unknown OS: $osname");
}

#
# Parse command-line arguments
#

if ($#ARGV < 0) {
    &show_usage(*STDERR{IO});
    die;
}

my $timezone_name;
my $perform_install = 0; # defaults to false

foreach (@ARGV) {
    if ($_ eq '-help') {
	&show_usage(*STDOUT{IO});
	die;
    }
    if ($_ eq '-version') {
	&say("version $version");
	die;
    }
    if ($_ eq '-quiet') {
	$verbose = 0; # false
	next;
    }
    if ($_ eq '-no-cleanup') {
	$perform_cleanup = 0; # false
	next;
    }
    if ($_ eq '-install') {
	$perform_install = 1; # true
	next;
    }
    if ($_ eq '-no-backup') {
	$backup_old_zoneinfo = 0; # false
	next;
    }
    if (/^-pipe-filter=(.*)$/) {
	$pipe_filter = $1;
	next;
    }
    if ($_ eq '-ignore-unpack-failure') {
	$abort_on_unpack_failure = 0; # false
	next;
    }
    if (!defined($timezone_name)) {
	$timezone_name = $_;
	next;
    }

    push @zoneinfo_url_list, $_;
}

if ($perform_install) {

    foreach (@zoneinfo_url_list) {
	if (/\.(net|gov)/i) {
	    &abort("PLEASE do not install a crontab job pointing to a public server");
	}
    }

    -x $crontab_path || &abort("crontab not found: $crontab_path");
    -d $install_dir || &abort("install dir not found: $install_dir");
    -x $cp_path || &abort("cp not found: $cp_path");
    -x $cmp_path || &abort("cmp not found: $cmp_path");
}

if (defined($pipe_filter)) {
    -x $mv_path || &abort("mv not found: $mv_path");
    -x $cat_path || &abort("cat not found: $cat_path");
}

&info("version $version");

&info("temporary directory: $tmp_dir (set with " . join(',', @tmp_env) . ")");

#
# Fetch timezone definition
#
my $fetched = 0;
foreach my $url (@zoneinfo_url_list) {
    $fetched = &fetch_timezone($url, $timezone_file, $timezone_name, $zoneinfo_dir);
    last if $fetched;
}
$fetched || &abort("could not fetch any zoneinfo");

#
# Set timezone
#

&set_timezone($osname, $zoneinfo_dir, $timezone_name);

#
# Install crontab
#

if ($perform_install) {
    &install_crontab($timezone_name, @zoneinfo_url_list);
}

&cleanup;

&info("done");
