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

my %endpoints :shared;
my %tokens :shared;

sub authorize {
	return RLM_MODULE_NOOP
		if (defined($RAD_CHECK{'Auth-Type'}));

	return RLM_MODULE_NOOP
		unless (defined($RAD_REQUEST{'Realm'}) && defined($cfg->{lc $RAD_REQUEST{'Realm'}}));

	return RLM_MODULE_NOOP
		unless (defined($RAD_REQUEST{'User-Password'}));

	$RAD_CHECK{'Auth-Type'} = 'oauth2-perl';
	return RLM_MODULE_UPDATED;
}

sub authenticate {
	my $realm = lc $RAD_REQUEST{'Realm'};

	my @opts = (
		grant_type	=> 'password',
		username	=> $RAD_REQUEST{'User-Name'},
		password	=> $RAD_REQUEST{'User-Password'},
	);
	push @opts, resource => 'https://graph.windows.net'
		if ($cfg->{$realm}->{'vendor'} eq 'microsoft-azure');

	my ($r, $j) = _fetch_token(@opts);
	return $r
		if (ref($r) eq '');

	# oauth2-perl-cache
	my $csh = Crypt::SaltedHash->new(algorithm => 'SHA-1');
	$csh->add($RAD_REQUEST{'User-Password'});
	$RAD_CHECK{'Password-With-Header'} = $csh->generate;
	$RAD_CHECK{'Cache-TTL'} = $cfg->{'_'}->{'cache'}
		if (defined($cfg->{'_'}->{'cache'}));

	my $data = {
		'_timestamp'				=> str2time($r->header('Date')) || time,
		token_type				=> $j->{'token_type'},
		access_token				=> $j->{'access_token'},
	};
	if (defined($j->{'expires_in'})) {
		$data->{'expires_in'}			= $j->{'expires_in'};
	}
	$data->{'refresh_token'}			= $j->{'refresh_token'}
			if (defined($j->{'refresh_token'}));

	lock(%tokens);
	$tokens{$RAD_REQUEST{'User-Name'}} = freeze $data;

	return RLM_MODULE_OK;
}

sub accounting {
	return RLM_MODULE_NOOP
		unless (defined($RAD_REQUEST{'User-Name'}));

	# https://tools.ietf.org/html/rfc2866#section-5.1
	given ($RAD_REQUEST{'Acct-Status-Type'}) {
		when ('Stop') {
			lock(%tokens);
			delete $tokens{$RAD_REQUEST{'User-Name'}};
			return RLM_MODULE_OK;
		}
		when ('Interim-Update') {
			return _handle_acct_update($RAD_REQUEST{'User-Name'});
		}
	}

	return RLM_MODULE_NOOP;
}

sub detach {
	return RLM_MODULE_OK;
}

sub xlat {
	my ($type, @args) = @_;

	return RLM_MODULE_INVALID
		unless (defined($RAD_REQUEST{'User-Name'}));

	lock(%tokens);

	return RLM_MODULE_NOTFOUND
		unless (defined($tokens{$RAD_REQUEST{'User-Name'}}));

	my $data = thaw $tokens{$RAD_REQUEST{'User-Name'}};

	given ($type) {
		when ('timestamp') {
			return $data->{'_timestamp'};
		}
		when ('expires_in') {
			return $data->{'expires_in'} || -1;
		}
	}

	return;
}

sub _discovery {
	my $realm = lc $RAD_REQUEST{'Realm'};

	my $url = (defined($cfg->{$realm}->{'discovery'})) 
		? $cfg->{$realm}->{'discovery'}
		: 'https://$realm/.well-known/openid-configuration';

	{
		lock(%endpoints);
		return thaw $endpoints{$url}
			if (defined($endpoints{$url}));
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

	my $endpoint = {
		'_timestamp'	=> time,
	};
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

		$endpoint->{$t} = $v;
	}

	lock(%endpoints);
	$endpoints{$url} = freeze $endpoint;

	return $endpoint;
}

sub _fetch_token (@) {
	my (@args) = @_;

	my $realm = lc $RAD_REQUEST{'Realm'};

	my $endpoint = _discovery();
	return RLM_MODULE_FAIL
		unless (defined($endpoint));

	my $r = $ua->post($endpoint->{'token'}, [
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

	return ($r, $j);
}

sub _handle_acct_update($) {
	my $id = shift;

	my $data;
	{
		lock(%tokens);
		return RLM_MODULE_INVALID
			unless (defined($tokens{$id}));
		$data = thaw $tokens{$id};
	}

	my ($r, $j) = _fetch_token(
		grant_type	=> 'refresh_token',
		refresh_token	=> $data->{'refresh_token'},
	);
	return $r
		if (ref($r) eq '');

	$data->{'_timestamp'}			= str2time($r->header('Date')) || time;
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

exit 0;
