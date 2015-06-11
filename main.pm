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
use HTTP::Date;
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

	$cfg->{'_'}->{'cache_cred'} = 1800
		unless (defined($cfg->{'_'}->{'cache_cred'}));

	$cfg->{'_'}->{'cache'} = 1800
		unless (defined($cfg->{'_'}->{'cache'}));
}

my %token :shared;
my %cache :shared;

my $ua = LWP::UserAgent->new;
$ua->timeout(10);
$ua->env_proxy;
$ua->agent("freeradius-oauth2-perl/$VERSION (+https://github.com/jimdigriz/freeradius-oauth2-perl; " . $ua->_agent . ')');
$ua->default_header('Accept-Encoding' => scalar HTTP::Message::decodable());
$ua->from($cfg->{'_'}->{'from'})
	if (defined($cfg->{'_'}->{'from'}));

$ua->add_handler('request_send', sub { return _cache_check(@_) });
$ua->add_handler('response_done', sub { return _cache_store(@_) });

# debugging
if (defined($cfg->{'_'}->{'debug'}) && $cfg->{'_'}->{'debug'} == 1) {
	&radiusd::radlog(RADIUS_LOG_INFO, 'debugging enabled, you will see the HTTPS requests in the clear!');

	$ua->add_handler('request_send',  sub { my $r = $_[0]->clone; $r->decode; &radiusd::radlog(RADIUS_LOG_DEBUG, $_) foreach split /\n/, $r->dump });
	$ua->add_handler('response_done', sub { my $r = $_[0]->clone; $r->decode; &radiusd::radlog(RADIUS_LOG_DEBUG, $_) foreach split /\n/, $r->dump });
}

sub authorize {
	return RLM_MODULE_NOOP
		unless (defined($RAD_REQUEST{'Realm'}) && defined($cfg->{lc $RAD_REQUEST{'Realm'}}));

	return RLM_MODULE_NOOP
		unless (defined($RAD_REQUEST{'User-Password'}) && $RAD_REQUEST{'User-Password'} ne '');

	my $realm = lc $RAD_REQUEST{'Realm'};

	if ($cfg->{$realm}->{'vendor'} eq 'microsoft-azure') {
		my $url = "https://graph.windows.net/$realm/users?api-version=1.5&\$top=999&\$filter=accountEnabled+eq+true";
		my $jsonpath = '$.value[*].userPrincipalName';

		my ($j, @results) = _handle_jsonpath($realm, $url, $jsonpath);

		return RLM_MODULE_FAIL
			unless (defined($j));

		return RLM_MODULE_NOTFOUND
			unless (grep { $_ eq lc $RAD_REQUEST{'Stripped-User-Name'} } map { s/@[^@]*$//; lc $_ } @results);

		$url = "https://graph.windows.net/$realm/users/$RAD_REQUEST{'User-Name'}/memberOf?api-version=1.5&\$top=999";
		$jsonpath = '$.value[?($_->{objectType} eq "Group" && $_->{securityEnabled} eq "true")].displayName';

		($j, @results) = _handle_jsonpath($realm, $url, $jsonpath);

		return RLM_MODULE_FAIL
			unless (defined($j));

		push @{$RAD_REQUEST{'Group-Name'}}, @results;
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
		username	=> $RAD_REQUEST{'User-Name'},
		password	=> $RAD_REQUEST{'User-Password'},
	);

	my $t = _fetch_token_password($realm, @opts);
	return $t
		if (ref($t) eq '');

	# oauth2-perl-cache
	my $csh = Crypt::SaltedHash->new(algorithm => 'SHA-1');
	$csh->add($RAD_REQUEST{'User-Password'});
	$RAD_CHECK{'Password-With-Header'} = $csh->generate;
	$RAD_CHECK{'Cache-TTL'} = int($cfg->{'_'}->{'cache_cred'} * (1.1-rand(0.2)));

	return RLM_MODULE_OK;
}

sub xlat {
	my ($type, @args) = @_;

	my $realm = lc shift @args;

	return ''
		unless (defined($cfg->{$realm}));

	given ($type) {
		when ('jsonpath') {
			my ($url, $jsonpath) = (shift @args, join ' ', @args);
			my ($j, @results) = _handle_jsonpath($realm, $url, $jsonpath);
			return $results[0] || '';
		}
	}

	return;
}

sub _cache_check {
	my ($request, $ua, $h) = @_;

	return unless ($request->method eq 'GET');

	return unless (defined($request->header('X-Cache-Key')));

	my $key = $request->header('X-Cache-Key');
	my $uri = $request->uri;

	my $response;
	{
		lock(%cache);
		return unless (defined($cache{"$key:$uri"}));

		$response = HTTP::Response->parse($cache{"$key:$uri"});
	}

	return $response
		unless ($response->header('X-Cache-Expires') < time);

	lock(%cache);
	delete $cache{"$key:$uri"};

	return;
}

sub _cache_store {
	my ($response, $ua, $h) = @_;

	return if ($response->is_error);

	return unless ($response->request->method eq 'GET');

	return unless (defined($response->request->header('X-Cache-Key')));

	my $key = $response->request->header('X-Cache-Key');
	my $uri = $response->request->uri;

	$response->header('Date' => $response->header->date(time))
		unless (defined($response->header('Date')));

	my $expires = str2time($response->header('Date')) + int($cfg->{'_'}->{'cache'} * (1.1-rand(0.2)));
	$response->header('X-Cache-Expires' => $expires);

	lock(%cache);
	$cache{"$key:$uri"} = $response->as_string;

	return;
}

sub _discovery ($) {
	my ($realm) = @_;

	my $url = (defined($cfg->{$realm}->{'discovery'})) 
		? $cfg->{$realm}->{'discovery'}
		: 'https://$realm/.well-known/openid-configuration';

	my $r = $ua->get($url, 'X-Cache-Key' => $realm);
	if (is_server_error($r->code)) {
		&radiusd::radlog(RADIUS_LOG_ERROR, 'unable to perform discovery: ' . $r->status_line);
		return;
	}

	my $j = decode_json $r->decoded_content;
	unless (defined($j)) {
		&radiusd::radlog(RADIUS_LOG_ERROR, 'non-JSON reponse');
		return;
	}

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

	return $j;
}

sub _fetch_token ($@) {
	my ($realm, @args) = @_;

	my $d = _discovery($realm);
	return RLM_MODULE_FAIL
		unless (defined($d));

	push @args, resource => 'https://graph.windows.net'
		if ($cfg->{$realm}->{'vendor'} eq 'microsoft-azure');

	my $r = $ua->post($d->{'token_endpoint'}, [ scope => 'openid', @args ]);
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

	unless (defined($j->{'token_type'} && $j->{'access_token'})) {
		&radiusd::radlog(RADIUS_LOG_ERROR, 'missing token_type/access_token in JSON response');
		return RLM_MODULE_REJECT;
	}

	$j->{'_timestamp'} = (defined($r->header('Date')))
			? str2time($r->header('Date'))
			: time;

	return $j;
}

sub _fetch_token_password ($@) {
	my ($realm, @args) = @_;

	push @args, grant_type		=> 'password';
	push @args, client_id		=> $cfg->{$realm}->{'client_id'};
	push @args, client_secret	=> $cfg->{$realm}->{'client_secret'};

	return _fetch_token($realm, @args);
}

sub _fetch_token_client ($@) {
	my ($realm, @args) = @_;

	my $t = { };
	{
		lock(%token);
		if (defined($token{$realm})) {
			$t = thaw $token{$realm};

			return $t
				if (defined($t->{'token_type'}) && $t->{'_timestamp'} + $t->{'expires_in'} > time);
		}
	}

	if (defined($t->{'refresh_token'})) {
		push @args, grant_type		=> 'refresh_token';
		push @args, refresh_token	=> $t->{'refresh_token'};
	} else {
		push @args, grant_type		=> 'client_credentials';
		push @args, client_id		=> $cfg->{$realm}->{'client_id'};
		push @args, client_secret	=> $cfg->{$realm}->{'client_secret'};
	}

	my $j = _fetch_token($realm, @args);
	if (ref($j) eq '') {
		lock(%token);
		delete $token{$realm};
		return $j;
	}

	lock(%token);
	$token{$realm} = freeze $j;

	return $j;
}

sub _handle_jsonpath($$$) {
	my ($realm, $url, $jsonpath) = @_;

	$jsonpath =~ s/\\//g;

	my $r;
	for (1..3) {
		my $t = _fetch_token_client($realm);
		return
			if (ref($t) eq '');

		$r = $ua->get($url, 'X-Cache-Key' => $realm, Authorization => $t->{'token_type'} . ' ' . $t->{'access_token'});
		if (is_server_error($r->code)) {
			&radiusd::radlog(RADIUS_LOG_INFO, 'jsonpath request failed: ' . $r->status_line);
			return;
		}

		if (is_client_error($r->code)) {
			delete $t->{'token_type'};

			lock(%token);
			$token{$realm} = freeze $t;

			next;
		}

		last;
	}

	my $j = decode_json $r->decoded_content;
	unless (defined($j)) {
		&radiusd::radlog(RADIUS_LOG_INFO, 'non-JSON reponse to authentication request');
		return RLM_MODULE_FAIL;
	}

	return ( $j, JSON::Path->new($jsonpath)->values($j) );
}

exit 0;
