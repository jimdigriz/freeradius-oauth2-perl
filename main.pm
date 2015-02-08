#!/usr/bin/env perl

use strict;
use warnings;

use 5.010_01;

use threads;
use threads::shared;

use Config::Tiny;
use LWP::UserAgent;
use HTTP::Status qw/is_client_error is_server_error/;
use JSON;
use Date::Parse qw/str2time/;
use Storable qw/freeze thaw/;
use URI;
use Crypt::SaltedHash;
use JSON::Path;

$JSON::Path::Safe = 0;

my $VERSION = '0.1';

# http://wiki.freeradius.org/modules/Rlm_perl#Logging
use constant {
	RADIUS_LOG_DEBUG	=> 1,
	RADIUS_LOG_AUTH		=> 2,
	RADIUS_LOG_INFO		=> 3,
	RADIUS_LOG_ERROR	=> 4,
	RADIUS_LOG_PROXY	=> 5,
	RADIUS_LOG_ACCT		=> 6,
};

# http://wiki.freeradius.org/modules/Rlm_perl#Return-Codes
use constant {
	RLM_MODULE_REJECT	=>  0,	# immediately reject the request
	RLM_MODULE_FAIL		=>  1,	# module failed, don't reply
	RLM_MODULE_OK		=>  2,	# the module is OK, continue
	RLM_MODULE_HANDLED	=>  3,	# the module handled the request, so stop
	RLM_MODULE_INVALID	=>  4,	# the module considers the request invalid
	RLM_MODULE_USERLOCK	=>  5,	# reject the request (user is locked out)
	RLM_MODULE_NOTFOUND	=>  6,	# user not found
	RLM_MODULE_NOOP		=>  7,	# module succeeded without doing anything
	RLM_MODULE_UPDATED	=>  8,	# OK (pairs modified)
	RLM_MODULE_NUMCODES	=>  9,	# How many return codes there are
};

use vars qw/%RAD_REQUEST %RAD_REPLY %RAD_CHECK/;

my $cfg;

BEGIN {
	$cfg = Config::Tiny->read('/opt/freeradius-oauth2-perl/config');
	unless (defined($cfg)) {
		&radiusd::radlog(RADIUS_LOG_ERROR, "unable to open 'config': " . Config::Tiny->errstr);
		exit 1;
	}

	&radiusd::radlog(RADIUS_LOG_INFO, 'no realms configured, this module will always noop')
		unless (scalar(grep { $_ ne '_' } keys %$cfg) > 0);

	foreach my $realm (grep { $_ ne '_' } keys %$cfg) {
		unless ($realm eq lc $realm) {
			&radiusd::radlog(RADIUS_LOG_ERROR, "realm '$realm' has to be all lowercase");
			exit 1;
		}

		if (defined($cfg->{$realm}->{'vendor'})) {
			unless (grep { $_ eq $cfg->{$realm}->{'vendor'} } ('microsoft-azure', 'google-apps')) {
				&radiusd::radlog(RADIUS_LOG_ERROR, "unsupported vendor for '$realm'");
				exit 1;
			}
		} else {
			$cfg->{$realm}->{'vendor'} = 'ietf';
		}

		if (defined($cfg->{$realm}->{'discovery'})
				&& URI->new($cfg->{$realm}->{'discovery'})->canonical->scheme ne 'https') {
			&radiusd::radlog(RADIUS_LOG_ERROR, "discovery for '$realm' is not 'https' scheme");
			return;
		}

		foreach my $key ('client_id', 'client_secret') {
			unless (defined($cfg->{$realm}->{$key})) {
				&radiusd::radlog(RADIUS_LOG_ERROR, "no '$key' set for '$realm'");
				exit 1;
			}
		}
	}
}

my %cache :shared;

my $ua = LWP::UserAgent->new;
$ua->timeout(10);
$ua->env_proxy;
$ua->agent("freeradius-oauth2-perl/$VERSION (+https://github.com/jimdigriz/freeradius-oauth2-perl; " . $ua->_agent . ')');
$ua->from($cfg->{'_'}->{'from'})
	if (defined($cfg->{'_'}->{'from'}));

# debugging
if (defined($cfg->{'_'}->{'debug'}) && $cfg->{'_'}->{'debug'} == 1) {
	&radiusd::radlog(RADIUS_LOG_INFO, 'debugging enabled, you will see the HTTPS requests in the clear!');

	$ua->add_handler('request_send',  sub { &radiusd::radlog(RADIUS_LOG_DEBUG, $_) foreach split /\n/, shift->dump; return });
	$ua->add_handler('response_done', sub { &radiusd::radlog(RADIUS_LOG_DEBUG, $_) foreach split /\n/, shift->dump; return });
}

sub authorize {
	return RLM_MODULE_NOOP
		unless (defined($RAD_REQUEST{'Realm'}) && defined($cfg->{lc $RAD_REQUEST{'Realm'}}));

	return RLM_MODULE_NOOP
		unless (defined($RAD_REQUEST{'User-Password'}) && $RAD_REQUEST{'User-Password'} ne '');

	my $realm = lc $RAD_REQUEST{'Realm'};

	if ($cfg->{$realm}->{'vendor'} eq 'microsoft-azure') {
		my $url = "https://graph.windows.net/$realm/users?api-version=1.5";
		my $jsonpath = '$.value[?($_->{accountEnabled} eq "true")].userPrincipalName';

		my @accounts = map { s/@[^@]*$//; lc $_ } _handle_jsonpath($realm, $url, $jsonpath);

		return RLM_MODULE_NOTFOUND
			unless (grep { $_ eq lc $RAD_REQUEST{'Stripped-User-Name'} } @accounts);

		$url = "https://graph.windows.net/$realm/users/$RAD_REQUEST{'User-Name'}/memberOf?api-version=1.5";
		$jsonpath = '$.value[?($_->{objectType} eq "Group" && $_->{securityEnabled} eq "true")].displayName';
		push @{$RAD_REQUEST{'Group-Name'}}, _handle_jsonpath($realm, $url, $jsonpath);
	}

	# Normally would NOOP the top when Auth-Type is set, however
	# rlm_cache in v2.x.x does not support multivalue attributes
	# and to get Group-Name populated we instead break out here
	return RLM_MODULE_UPDATED
		if (defined($RAD_CHECK{'Auth-Type'}));

	# let PAP catch this
	return RLM_MODULE_UPDATED
		if (defined($RAD_CHECK{'Password-With-Header'}));

	$RAD_CHECK{'Auth-Type'} = 'oauth2-perl';

	return RLM_MODULE_OK;
}

sub authenticate {
	my $realm = lc $RAD_REQUEST{'Realm'};

	my @opts = (
		grant_type	=> 'password',
		username	=> $RAD_REQUEST{'User-Name'},
		password	=> $RAD_REQUEST{'User-Password'},
	);

	my $rc = _fetch_token($realm, $RAD_REQUEST{'User-Name'}, @opts);
	return $rc
		if ($rc != RLM_MODULE_OK);

	# oauth2-perl-cache
	my $csh = Crypt::SaltedHash->new(algorithm => 'SHA-1');
	$csh->add($RAD_REQUEST{'User-Password'});
	$RAD_CHECK{'Password-With-Header'} = $csh->generate;
	$RAD_CHECK{'Cache-TTL'} = $cfg->{'_'}->{'cache'}
		if (defined($cfg->{'_'}->{'cache'}));

	return RLM_MODULE_OK;
}

sub accounting {
	return RLM_MODULE_NOOP
		unless (defined($RAD_REQUEST{'Realm'}) && defined($cfg->{lc $RAD_REQUEST{'Realm'}}));

	# https://tools.ietf.org/html/rfc2866#section-5.1
	given ($RAD_REQUEST{'Acct-Status-Type'}) {
		when ('Stop') {
			lock(%cache);
			delete $cache{$RAD_REQUEST{'User-Name'}};
			return RLM_MODULE_OK;
		}
		when ('Interim-Update') {
			return _handle_acct_update($RAD_REQUEST{'User-Name'});
		}
	}

	return RLM_MODULE_NOOP;
}

sub xlat {
	my ($type, $realm, @args) = @_;

	$realm = lc $realm;

	return ''
		unless (defined($cfg->{lc $realm}));

	given ($type) {
		when ('timestamp') {
			lock(%cache);
			return ''
				unless (defined($cache{$args[0]}));
			my $data = thaw $cache{$args[0]};
			return $data->{'_timestamp'};
		}
		when ('expires_in') {
			lock(%cache);
			return ''
				unless (defined($cache{$args[0]}));
			my $data = thaw $cache{$args[0]};
			return $data->{'expires_in'} || -1;
		}
		when ('jsonpath') {
			return (_handle_jsonpath($realm, @args))[0] || '';
		}
	}

	return;
}

sub _discovery ($) {
	my ($realm) = @_;

	my $url = (defined($cfg->{$realm}->{'discovery'})) 
		? $cfg->{$realm}->{'discovery'}
		: 'https://$realm/.well-known/openid-configuration';

	{
		lock(%cache);
		return thaw $cache{$url}
			if (defined($cache{$url}));
	}

	my $r = $ua->get($url);
	if (is_server_error($r->code)) {
		&radiusd::radlog(RADIUS_LOG_ERROR, 'unable to perform discovery: ' . $r->status_line);
		return;
	}

	my $j = decode_json $r->decoded_content;
	unless (defined($j)) {
		&radiusd::radlog(RADIUS_LOG_ERROR, 'non-JSON reponse');
		return;
	}

	$j->{'_timestamp'} = str2time($r->header('Date')) || time;

	for my $t ('token') {
		my $v = $j->{"${t}_endpoint"};

		unless (defined($v)) {
			&radiusd::radlog(RADIUS_LOG_ERROR, "missing '${t}_endpoint' element");
			return;
		}

		unless (URI->new($v)->canonical->scheme eq 'https') {
			&radiusd::radlog(RADIUS_LOG_ERROR, "'${t}_endpoint' is not 'https' scheme");
			return;
		}
	}

	lock(%cache);
	$cache{$url} = freeze $j;

	return $j;
}

sub _fetch_token (@) {
	my ($realm, $key, @args) = @_;

	my $d = _discovery($realm);
	return RLM_MODULE_FAIL
		unless (defined($d));

	{
		lock(%cache);
		return thaw $cache{$d->{'token_endpoint'}}
			if (defined($cache{$d->{'token_endpoint'}}));
	}

	push @args, resource => 'https://graph.windows.net'
		if ($cfg->{$realm}->{'vendor'} eq 'microsoft-azure');

	my $r = $ua->post($d->{'token_endpoint'}, [
		scope		=> 'openid',
		client_id	=> $cfg->{$realm}->{'client_id'},
		client_secret	=> $cfg->{$realm}->{'client_secret'},
		@args,
	]);
	if (is_server_error($r->code)) {
		&radiusd::radlog(RADIUS_LOG_INFO, 'authentication request failed: ' . $r->status_line);
		return RLM_MODULE_FAIL;
	}

	my $j = decode_json $r->decoded_content;
	unless (defined($j)) {
		&radiusd::radlog(RADIUS_LOG_INFO, 'non-JSON reponse to authentication request');
		return RLM_MODULE_FAIL;
	}

	$j->{'_timestamp'} = str2time($r->header('Date')) || time;

	if (is_client_error($r->code)) {
		my $m = [];

		push @$m, $RAD_REPLY{'Reply-Message'}
			if (defined($RAD_REPLY{'Reply-Message'}));

		push @$m, 'Error: ' . $j->{'error'};
		push @$m, split(/\r\n/ms, $j->{'error_description'})
			if (defined($j->{'error_description'}));

		$RAD_REPLY{'Reply-Message'} = $m;

		return RLM_MODULE_REJECT;
	}

	unless (defined($j->{'access_token'} && $j->{'token_type'})) {
		&radiusd::radlog(RADIUS_LOG_ERROR, 'missing access_token/token_type in JSON response');
		return RLM_MODULE_REJECT;
	}

	lock(%cache);
	$cache{$key} = freeze $j;

	return RLM_MODULE_OK;
}

sub _handle_acct_update($) {
	my $id = shift;

	my $data;
	{
		lock(%cache);
		return RLM_MODULE_INVALID
			unless (defined($cache{$id}));
		$data = thaw $cache{$id};
	}

	my $rc = _fetch_token($RAD_REQUEST{'Realm'}, $RAD_REQUEST{'User-Name'},
		grant_type	=> 'refresh_token',
		refresh_token	=> $data->{'refresh_token'},
	);
	return $rc
		if ($rc != RLM_MODULE_OK);

	return RLM_MODULE_OK;
}

sub _handle_jsonpath($$$) {
	my ($realm, $url, $jsonpath) = @_;

	$jsonpath =~ s/\^/\$/g;

	{
		lock(%cache);
		return JSON::Path->new($jsonpath)->values(thaw $cache{$url})
			if (defined($cache{$url}));
	}

	my $atok;
	{
		lock(%cache);
		$atok = thaw $cache{$realm};
	}
	unless (defined($atok)) {
		my $rc = _fetch_token($realm, $realm, grant_type => 'client_credentials');
		return
			if ($rc != RLM_MODULE_OK);
		lock(%cache);
		$atok = thaw $cache{$realm};
	}

	my $r = $ua->get($url, Authorization => $atok->{'token_type'} . ' ' . $atok->{'access_token'});
	if (is_server_error($r->code)) {
		&radiusd::radlog(RADIUS_LOG_INFO, 'jsonpath request failed: ' . $r->status_line);
		return;
	}

	return
		if (is_client_error($r->code));

	my $j = decode_json $r->decoded_content;
	unless (defined($j)) {
		&radiusd::radlog(RADIUS_LOG_INFO, 'non-JSON reponse to authentication request');
		return RLM_MODULE_FAIL;
	}

	$j->{'_timestamp'} = str2time($r->header('Date')) || time;

	lock(%cache);
	$cache{$url} = freeze $j;

	return JSON::Path->new($jsonpath)->values($j);
}

exit 0;
