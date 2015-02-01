#!/usr/bin/env perl

use strict;
use warnings;

use threads;
use threads::shared;

use Config::Tiny;
use LWP::UserAgent;
use HTTP::Status qw/is_client_error is_server_error/;
use JSON;
use Date::Parse qw/str2time/;
use Storable qw/freeze thaw/;
use URI;

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

		my $c = $cfg->{$realm};

		foreach my $key ('clientid', 'code') {
			unless (defined($c->{$key})) {
				&radiusd::radlog(RADIUS_LOG_ERROR, "no '$key' set for '$realm'");
				exit 1;
			}
		}

		if (defined($c->{'authorization_endpoint'}) ^ defined($c->{'token_endpoint'})) {
			&radiusd::radlog(RADIUS_LOG_ERROR, "realm '$realm' has partially configured manual endpoints");
			exit 1;
		}

		$c->{'discovery'} = (defined($c->{'authorization_endpoint'})) ? 0 : 1;
	}
}

my $ua = LWP::UserAgent->new;
$ua->timeout(10);
$ua->env_proxy;
$ua->agent("freeradius-oauth2-perl/$VERSION (+https://github.com/jimdigriz/freeradius-oauth2-perl; " . $ua->_agent . ')');
$ua->from($cfg->{'_'}->{'from'})
	if (defined($cfg->{'_'}->{'from'}));

if (defined($cfg->{'_'}->{'secure'}) && $cfg->{'_'}->{'secure'} == 0) {
	&radiusd::radlog(RADIUS_LOG_INFO, 'secure set to zero, SSL is effectively disabled!');

	$ua->ssl_opts(verify_hostname => 0);
}

# debugging
if (defined($cfg->{'_'}->{'debug'}) && $cfg->{'_'}->{'debug'} == 1) {
	&radiusd::radlog(RADIUS_LOG_INFO, 'debugging enabled, you will see the HTTPS requests in the clear!');

	$ua->add_handler('request_send',  sub { shift->dump; return });
	$ua->add_handler('response_done', sub { shift->dump; return });
}

my %tokens :shared;

sub authorize {
	return RLM_MODULE_NOOP
		if (defined($RAD_CHECK{'Auth-Type'}));

	return RLM_MODULE_NOOP
		unless (defined($RAD_REQUEST{'User-Name'}) && defined($RAD_REQUEST{'User-Password'}));

	return RLM_MODULE_NOOP
		unless (defined($RAD_REQUEST{'Realm'}) && defined($cfg->{lc $RAD_REQUEST{'Realm'}}));

	return RLM_MODULE_INVALID
		unless (defined($RAD_REQUEST{'NAS-Identifier'}) 
				|| defined($RAD_REQUEST{'NAS-IP-Address'})
				|| defined($RAD_REQUEST{'NAS-IPv6-Address'}));

	$RAD_CHECK{'Auth-Type'} = 'freeradius-oauth2-perl';
	delete $RAD_CHECK{'Proxy-To-Realm'};
	return RLM_MODULE_UPDATED;
}

sub authenticate {
	my $c = $cfg->{lc $RAD_REQUEST{'Realm'}};

	my ($auth_endpoint, $token_endpoint) = _discovery($c);
	return RLM_MODULE_REJECT
		unless (defined($auth_endpoint));

	my ($r, $j) = _fetch_token($c, $token_endpoint, [
		resource	=> '00000002-0000-0000-c000-000000000000',
		grant_type	=> 'password',
		username	=> $RAD_REQUEST{'User-Name'},
		password	=> $RAD_REQUEST{'User-Password'},
	]);
	return $r
		if (ref($r) eq '');

	my $id = _gen_id();
	my $data = {
		timestamp				=> str2time($r->header('Date')),
		token_endpoint				=> $token_endpoint,
		token_type				=> $j->{'token_type'},
		access_token				=> $j->{'access_token'},
	};
	if (defined($j->{'expires_in'})) {
		$data->{'expires_in'}			= $j->{'expires_in'};
		$RAD_REPLY{'Acct-Interim-Interval'}	= int($j->{'expires_in'} * (0.7 + (rand(20)/100)));
	}
	$data->{'refresh_token'}			= $j->{'refresh_token'}
			if (defined($j->{'refresh_token'}));

	lock(%tokens);
	$tokens{$id} = freeze $data;

	return RLM_MODULE_OK;
}

sub accounting {
	my $id = _gen_id();

	my $data;
	{
		lock(%tokens);
		$data = thaw $tokens{$id};
		delete $tokens{$id};
	}

	my $c = $cfg->{lc $RAD_REQUEST{'Realm'}};

	my ($auth_endpoint, $token_endpoint) = _discovery($c);
	return RLM_MODULE_REJECT
		unless (defined($auth_endpoint));

	my ($r, $j) = _fetch_token($c, $token_endpoint, [
		grant_type	=> 'refresh_token',
		refresh_token	=> $data->{'refresh_token'},
	]);
	return $r
		if (ref($r) eq '');

	$data->{'timestamp'}			= str2time($r->header('Date'));
	$data->{'token_type'}			= $j->{'token_type'};
	$data->{'access_token'}			= $j->{'access_token'};
	$data->{'expires_in'}			= $j->{'expires_in'}
		if (defined($j->{'expires_in'}));
	if (defined($j->{'refresh_token'})) {
		$data->{'refresh_token'}	= $j->{'refresh_token'}
	} else {
		delete $data->{'refresh_token'};
	}

	lock(%tokens);
	$tokens{$id} = freeze $data;

	return RLM_MODULE_OK;
}

sub post_auth {
	return RLM_MODULE_OK;
}

sub detach {
	return RLM_MODULE_OK;
}

sub _discovery ($) {
	my $c = shift;

	my ($auth_endpoint, $token_endpoint);

	if ($c->{'discovery'}) {
		my $r = $ua->get('https://' . lc $RAD_REQUEST{'Realm'} . '/.well-known/openid-configuration');
		if (is_server_error($r->code)) {
			&radiusd::radlog(RADIUS_LOG_ERROR, 'unable to perform discovery: ' . $r->status_line);
			return;
		}

		my $j = decode_json $r->decoded_content;
		unless (defined($j) && defined($j->{'authorization_endpoint'})) {
			&radiusd::radlog(RADIUS_LOG_ERROR, "non-JSON reponse or missing 'authorization_endpoint' element");
			return;
		}

		$auth_endpoint = $j->{'authorization_endpoint'};
		$token_endpoint = $j->{'token_endpoint'};
	} else {
		$auth_endpoint = $c->{'authorization_endpoint'};
		$token_endpoint = $c->{'token_endpoint'};
	}

	unless (URI->new($auth_endpoint)->canonical->scheme eq 'https') {
		&radiusd::radlog(RADIUS_LOG_ERROR, "'authorization_endpoint' is not 'https' scheme");
		return;
	}
	unless (URI->new($token_endpoint)->canonical->scheme eq 'https') {
		&radiusd::radlog(RADIUS_LOG_ERROR, "'token_endpoint' is not 'https' scheme");
		return;
	}

	return ($auth_endpoint, $token_endpoint);
}

sub _fetch_token ($$) {
	my $c = shift;
	my $t = shift;
	my $f = shift;

	my $r = $ua->post($t, [
		scope		=> 'openid',
		client_id	=> $c->{'clientid'},
		code		=> $c->{'code'},
		@$f,
	]);
	if (is_server_error($r->code)) {
		&radiusd::radlog(RADIUS_LOG_INFO, 'authentication request failed: ' . $r->status_line);
		return RLM_MODULE_REJECT;
	}

	my $j = decode_json $r->decoded_content;
	unless (defined($j)) {
		&radiusd::radlog(RADIUS_LOG_INFO, 'non-JSON reponse to authentication request');
		return RLM_MODULE_REJECT;
	}

	if (is_client_error($r->code)) {
		my $m = [];

		push @$m, $RAD_REPLY{'Reply-Message'}
			if (defined($RAD_REPLY{'Reply-Message'}));

		push @$m, 'Error: ' . $j->{'error'};
		push @$m, split(/\r\n/ms, $j->{'error_description'})
			if (defined($j->{'error_description'}));

		$RAD_REPLY{'Reply-Message'} = $m;

		return RLM_MODULE_FAIL;
	}

	unless (defined($j->{'access_token'} && $j->{'token_type'})) {
		&radiusd::radlog(RADIUS_LOG_ERROR, 'missing access_token/token_type in JSON response');
		return RLM_MODULE_REJECT;
	}

	return ($r, $j);
}

sub _gen_id {
	my $i = $RAD_REQUEST{'NAS-Identifier'} || $RAD_REQUEST{'NAS-IP-Address'} || $RAD_REQUEST{'NAS-IPv6-Address'};
	$i .= '|' . $RAD_REQUEST{'NAS-Port'} || $RAD_REQUEST{'NAS-Port-Id'}
		if (defined($RAD_REQUEST{'NAS-Port'}) || defined($RAD_REQUEST{'NAS-Port-Id'}));
	$i .= '|' . $RAD_REQUEST{'User-Name'};

	return $i;
}

exit 0;
