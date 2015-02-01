#!/usr/bin/env perl

use strict;
use warnings;

use threads;
use threads::shared;

use Config::Tiny;
use LWP::UserAgent;
use JSON::PP;

#use Data::Dumper;

my $cfg = Config::Tiny->read('/opt/freeradius-perl-oauth2/config');

# http://lists.freeradius.org/pipermail/freeradius-users/2012-December/064155.html
my %credentials :shared;
sub put($$$) {
	my ($hash, $key, $value) = @_;
	lock(%$hash);
	$hash->{$key} = share($value);
	return;
}
sub get($$) {
	my ($hash, $key) = @_;
	lock(%$hash);
	my $value = $hash->{$key};
	return $value;
}

# http://wiki.freeradius.org/modules/Rlm_perl#Return-Codes
use constant {
	RLM_MODULE_REJECT	=>  0,	# immediately reject the request
	RLM_MODULE_FAIL		=>  1,	# module failed, don't reply
	RLM_MODULE_OK		=>  2,	# the module is OK, continue
	RLM_MODULE_HANDLED	=>  3,	# the module handled the request, so stop.
	RLM_MODULE_INVALID	=>  4,	# the module considers the request invalid.
	RLM_MODULE_USERLOCK	=>  5,	# reject the request (user is locked out)
	RLM_MODULE_NOTFOUND	=>  6,	# user not found
	RLM_MODULE_NOOP		=>  7,	# module succeeded without doing anything
	RLM_MODULE_UPDATED	=>  8,	# OK (pairs modified)
	RLM_MODULE_NUMCODES	=>  9,	# How many return codes there are
};

use vars qw/%RAD_REQUEST %RAD_REPLY %RAD_CHECK/;

sub authorize {
	unless (defined($RAD_CHECK{'Auth-Type'}) || !defined($RAD_REQUEST{'Realm'})) {
		$RAD_CHECK{'Auth-Type'} = 'freeradius-perl-oauth2';
		delete $RAD_CHECK{'Proxy-To-Realm'};
		return RLM_MODULE_UPDATED;
	}

	return RLM_MODULE_NOOP;
}

sub authenticate {
	$RAD_REPLY{'Reply-Message'} = join ',', map { $cfg->{$_}->{'clientid'} } grep { $_ ne '_' } keys %$cfg;
	return RLM_MODULE_OK;
}

sub preacct {
	return RLM_MODULE_OK;
}

sub accounting {
	return RLM_MODULE_OK;
}

sub checksimul {
	return RLM_MODULE_OK;
}

sub pre_proxy {
	return RLM_MODULE_OK;
}

sub post_auth {
	return RLM_MODULE_OK;
}

sub detach {
	return RLM_MODULE_OK;
}

exit 0;
