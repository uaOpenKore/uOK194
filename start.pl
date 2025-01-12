#!/usr/bin/env perl
# Win32 Perl script launcher
# This file is meant to be compiled by PerlApp. It acts like a mini-Perl interpreter.
#
# Your script's initialization and main loop code should be placed in a function
# called __start() in the main package. That function will be called by this
# launcher. The reason for this is that otherwise, the perl interpreter will be
# in "eval" all the time while running your script. It will break __DIE__ signal
# handlers that check for the value of $^S.
#
# If your script is run by this launcher, the environment variable INTERPRETER is
# set. Your script should call __start() manually if this environment variable is not
# set.
#
# Example script:
# our $quit = 0;
#
# sub __start {
#	print "Hello world initialized.\n";
#	while (!$quit) {
#		...
#	}
# }
#
# __start() unless defined $ENV{INTERPRETER};
package StarterScript;

use strict;
use Config;

if ($^O ne 'MSWin32') {
	# We are not on Windows, so tell the user about it
	print "\nThis file is meant to be compiled by PerlApp.\n";
	print "To run kore, execute openkore.pl instead.\n\n";
	exit 1;
}


# PerlApp 6's @INC doesn't contain '.', so add it
my $hasCurrentDir;
foreach (@INC) {
	if ($_ eq ".") {
		$hasCurrentDir = 1;
		last;
	}
}
push @INC, "." if (!$hasCurrentDir);

if (0) {
	# Force PerlApp to include the following modules
	use FindBin;
	require base;
	require bytes;
	require lib;
	require integer;
	require warnings;
	require Exporter;
	require Fcntl;
	require Carp;
	require Math::Trig;
	require Text::Wrap;
	require Text::ParseWords;
	require Time::HiRes;
	require IO::Socket::INET;
	require Getopt::Long;
	require Digest::MD5;
	require SelfLoader;
	require Data::Dumper;
	require Win32;
	require Win32::Console;
	require Win32::Process;
	require XSTools;
	require Encode;
	require encoding;
	require Storable;
	require Compress::Zlib;
	require "unicore/lib/gc_sc/SpacePer.pl";
	require "unicore/lib/gc_sc/Word.pl";
	require "unicore/lib/gc_sc/Digit.pl";
	require "unicore/lib/gc_sc/Cntrl.pl";
	require "unicore/lib/gc_sc/ASCII.pl";
	require HTML::Entities;
}


if ($PerlApp::TOOL eq "PerlApp") {
	$ENV{INTERPRETER} = PerlApp::exe();
	if (PerlApp::exe() =~ /wxstart\.exe$/i) {
		$ENV{OPENKORE_DEFAULT_INTERFACE} = 'Wx';
	}
} else {
	print "Do not run start.pl directly! If you're using Perl then run openkore.pl instead!\n";
	<STDIN>;
	exit 1;
}

my $file = "openkore.pl";
if ($ARGV[0] eq '!') {
	shift;
	while (@ARGV) {
		if ($ARGV[0] =~ /^-I(.*)/) {
			unshift @INC, $1;
		} else {
			last;
		}
		shift;
	}
	$file = shift;
}

$0 = $file;
FindBin::again();

{
	package main;
	do $file;
}
if ($@) {
	print $@;
	print "\nPress ENTER to exit.\n";
	<STDIN>;
	exit 1;
} elsif (defined $ENV{INTERPRETER}) {
	main::__start() if defined(&main::__start);
}
