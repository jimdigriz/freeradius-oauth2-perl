This is a [FreeRADIUS](http://freeradius.org/) [OAuth2 (OpenID Connect)](http://en.wikipedia.org/wiki/OpenID_Connect) [Perl module](http://wiki.freeradius.org/modules/Rlm_perl) to handle authentication.  It was created to allow the users of a wireless 802.1X (WPA Enterprise) network to connect.

**N.B.** this module relies on your OAuth2 provider supporting the [Resource Owner Password Credentials Grant](https://tools.ietf.org/html/rfc6749#section-4.3)

## Features

 * `User-Name` is validated against list of actually valid usernames
 * `Group-Name` attribute is populated with users group membership
 * credentials cache that utilises a [salted SHA-1 hash](http://en.wikipedia.org/wiki/Cryptographic_hash_function#Password_verification)
 * xlat support to pull any URL with a suitable token and use [JSONPath](http://jsonpath.curiousconcept.com/) to extract data; backed by a similar HTTP cache

There is a [TODO list](TODO.md) for the project listing outstanding problems and missing functionality.

## Related Links

 * [RFC6749: The OAuth 2.0 Authorization Framework](https://tools.ietf.org/html/rfc6749)
 * [RFC7009: OAuth 2.0 Token Revocation](https://tools.ietf.org/html/rfc7009)
 * [OpenID Specifications](http://openid.net/developers/specs/)
  * [Connect Core](http://openid.net/specs/openid-connect-core-1_0.html)
  * [Connect Discovery](http://openid.net/specs/openid-connect-discovery-1_0.html)
  * [Connect Session Management](http://openid.net/specs/openid-connect-session-1_0.html)

# Preflight

## Workstation

You will need to [have git installed on your workstation](http://git-scm.com/book/en/Getting-Started-Installing-Git).

**N.B.** Debian/Redhat users should be able to just type `sudo {apt-get,yum} install git python` whilst Mac OS X users will need to install the [Command Line Tools](http://osxdaily.com/2014/02/12/install-command-line-tools-mac-os-x/).

So we start off by fetching a copy of the project:

    git clone https://github.com/jimdigriz/freeradius-oauth2-perl.git
    cd freeradius-oauth2-perl

Now make a copy of the example configuration which is an [INI](http://en.wikipedia.org/wiki/INI_file) formatted file:

    cp example.config config

**N.B.** although you usually only have a single OAuth2 realm, the configuration does support multiple sections

Optionally, you can edit the following elements in the global section of `config`:

 * **`debug` (default: 0):** set to `1` to have verbose output, such as the HTTPS communications (note that you will see passwords in the clear!)
 * **`from` (default: [unset]):** set to a suitable contact email address for your organisation
 * **`cache` (default: 1800):** number of seconds to cache HTTP GET requests for
 * **`cache_cred` (default: 1800):** number of seconds to cache credentials for

## Target RADIUS Server

You require a Debian 'wheezy' 7.x server that is plumbed into [Debian Backports](http://backports.debian.org/), which if you have not done already is just a case of running:

    sudo cat <<'EOF' > /etc/apt/sources.list.d/debian-backports.list
    deb http://http.debian.net/debian wheezy-backports main
    #deb-src http://http.debian.net/debian wheezy-backports main
    EOF

    sudo apt-get update

Afterwards, you can get everything you need with:

    sudo apt-get install -yy --no-install-recommends \
    	libwww-perl libconfig-tiny-perl libjson-perl libjson-xs-perl \
	libhttp-date-perl liburi-perl libcrypt-saltedhash-perl cpanminus make
    sudo apt-get install -yy --no-install-recommends -t wheezy-backports freeradius
    sudo cpanm JSON::Path

You should now have set up a working *default* installation of FreeRADIUS 2.2.x.

**N.B.** if someone wants to step forward to help get this working on another UNIX system (*BSD, another Linux, Mac OS X, etc) and/or a later version of FreeRADIUS, then do get in touch

On the server, run:

    mkdir /opt/freeradius-oauth2-perl

From the project directory on your workstation, copy `main.pm` and `module` to `/opt/freeradius-oauth2-perl` and run on the server:

    chown -R root:root /opt/freeradius-oauth2-perl

# Configuration

## OAuth2 Discovery

If you run a *secure* HTTPS website at `https://example.com` then you can make use of the [auto-discovery mechanism](http://openid.net/specs/openid-connect-discovery-1_0.html#ProviderConfig):

    https://example.com/.well-known/openid-configuration

Alternatively you can generate an HTTP redirect to your authentication provider's discovery address:

 * **[IETF](https://www.ietf.org/):** this is the default
  * **Vendor:** `ietf`
  * **Discovery:** `https://example.com/.well-known/openid-configuration`
 * **[Microsoft Azure AD](http://azure.microsoft.com/) ([Office 365](http://products.office.com/en/business/office-365-business)):**
  * **Vendor:** `microsoft-azure`
  * **Discovery:** `https://login.windows.net/example.com/.well-known/openid-configuration`
 * **[Google Apps](https://www.google.com/work/apps/business/) [not supported]:**
  * **Vendor:** `google-apps`
  * **Discovery:** `https://accounts.google.com/.well-known/openid-configuration`

If you do not have a secure website at the apex of your realm, then you will need to edit `config` and add your authentication provider's discovery address under your realm as `discovery`.

Also add to `config` under your realm a `vendor` attribute if you use one of the authentication providers above.

## Cloud

### Microsoft Azure AD (Office 365)

1. go to https://portal.office.com/ and log in as an administrator
1. click on 'Admin' in the top right and select 'Azure AD' from the drop down menu
1. once the Azure page loads, click on 'Active Directory' from the left hand panel
1. highlight your main directory, and click on the arrow pointing right located to the right of its name
1. click on 'Applications' at the top
1. click on 'Add' located at the centre of the bottom of the page
1. a window will open asking 'What do you want to do?', click on 'Add an application my organization is developing'
1. enter in the application name `freeradius-oauth2-perl`, click on 'Web Application and/or Web API', and click on the next arrow
1. as a sign-on URI, enter in `http://localhost`
1. as an App ID URI, use `https://github.com/jimdigriz/freeradius-oauth2-perl`
1. click on the complete arrow
1. the application will now be added and you will be shown a preview page
1. go to the 'Configure' section found at the top of the page
1. under the 'Keys' section, select the drop down menu to create a key of a duration of your choosing
1. under the 'Permissions to other applications', in the first drop down menu, give application permissions to 'Read directory data', and under the second drop down menu select give delegated permissions to 'Enable sign-on and read users'
1. click on 'Save' located in the bottom bar of the page
1. now edit your `config` file and place under your realm:
  * 'Client ID' as `client_id`
  * take a copy of your new generated key and place it under `client_secret`

#### Related Links

 * [OAuth 2.0 in Azure AD](https://msdn.microsoft.com/en-us/library/azure/dn645545.aspx)
 * [Microsoft Azure REST API + OAuth 2.0](https://ahmetalpbalkan.com/blog/azure-rest-api-with-oauth2/)
 * [Azure AD Graph REST API Reference](https://msdn.microsoft.com/en-us/library/azure/hh974478.aspx)
  * [Azure AD Graph API Directory Schema Extensions](https://msdn.microsoft.com/en-us/library/azure/dn720459.aspx) - SSH keys and other meta data?

### Google Apps

**N.B.** not supported

#### Related Links

 * [OpenID Connect (OAuth 2.0 for Login)](https://developers.google.com/accounts/docs/OpenIDConnect)
  * [People: getOpenIdConnect (aka `userinfo`)](https://developers.google.com/+/api/openidconnect/getOpenIdConnect)
  * [Create a custom user schema](https://developers.google.com/admin-sdk/directory/v1/guides/manage-schemas#create_schema) - SSH keys and other meta data?
 * [Using OAuth 2.0 for Devices](https://developers.google.com/accounts/docs/OAuth2ForDevices) - via SMS or email maybe?

## FreeRADIUS

This section assumes you are familiar with configuring FreeRADIUS, or have an existing working service and want to know what you need to splice in.  For example the following problems are not addressed here:

 * what to do with realmless usernames, you may wish to use [unlang](http://freeradius.org/radiusd/man/unlang.html) to fix it up before the `suffix` module
 * throttling authentication attempts, care is to be taken in case your OAuth2 provider throttles *all* authentication requests from your RADIUS server, possibly causing you service unavailability
 * preventing attempts by your RADIUS server to proxy realmed usernames that are not handled locally

By now your `config` file should look something like:

    [example.com]
    vendor=microsoft-azure
    discovery=https://login.windows.net/example.com/.well-known/openid-configuration
    client_id=12345678-abcd-abcd-abcd-1234567890ab
    client_secret=....

Copy `config` on your workstation to `/opt/freeradius-oauth2-perl` on the target RADIUS server, and then on the server run as root:

    chown root:freerad /opt/freeradius-oauth2-perl/config
    chmod 640 /opt/freeradius-oauth2-perl/config
    ln -T -f -s /opt/freeradius-oauth2-perl/module /etc/freeradius/modules/oauth2-perl

Amend `/etc/freeradius/sites-available/default` like so:

    authorize {
      ...
    
      eap
    
      # after 'eap'
      update control {
        Cache-Status-Only := yes
      }
      oauth2-perl-cache
      if (ok) {
        update control {
          Cache-Status-Only !* ANY
        }
        oauth2-perl-cache
      }
      update control {
        Cache-Status-Only !* ANY
      }
      oauth2-perl
    
      ...
    }
    
    authenticate {
      ...
    
      unix
      
      # after 'unix'
      Auth-Type oauth2-perl {
        oauth2-perl
      }
    }
    
    post-auth {
      ...
    
      #reply_log
    
      # after '#reply_log'
      oauth2-perl-cache
    
      ...
    }

Add to your `/etc/freeradius/proxy.conf`:

    realm example.com {
    }

### Heartbleed

FreeRADIUS actively checks for the [Heartbleed vulnerability](http://freeradius.org/security.html#heartbleed) and will refuse to fire up if it thinks you are running a too old a version.  To bypass this check you *must* confirm that you have installed at least version `1.0.1e-2+deb7u7` (note the '7' on the end there) of [libssl1.0.0](https://packages.debian.org/wheezy/libssl1.0.0) which you can do with:

    $ dpkg -s libssl1.0.0 | grep Version
    Version: 1.0.1e-2+deb7u14

Once confirmed, amend the `security` section of `/etc/freeradius/radiusd.conf` like so:

    security {
      ...
    
      allow_vulnerable_openssl = yes
    }

### 802.1X

For 802.1X authentication, only EAP-TTLS/PAP is supported, so Linux, Mac OS X and [Microsoft Windows 8](https://adamsync.wordpress.com/2012/05/08/eap-ttls-on-windows-2012-build-8250/) based devices will have no problems.  However, for Microsoft Windows 7 and earlier, you will need to use a supplicant extension such as [SecureW2 Enterprise Client](http://www.securew2.com/enterpriseclient).

To enable this functionality, you will need to amend `/etc/freeradius/sites-available/inner-tunnel`:

    authorize {
      ...
    
      eap
    
      # after 'eap'
      update control {
        Cache-Status-Only := yes
      }
      oauth2-perl-cache
      if (ok) {
        update control {
          Cache-Status-Only !* ANY
        }
        oauth2-perl-cache
      }
      update control {
        Cache-Status-Only !* ANY
      }
      oauth2-perl
    
      ...
    }
    
    authenticate {
      ...
    
      unix
      
      # after 'unix'
      Auth-Type oauth2-perl {
        oauth2-perl
      }
    }
    
    post-auth {
      ...
    
      #reply_log
    
      # after '#reply_log'
      oauth2-perl-cache
    
      ...
    
      Post-Auth-Type REJECT {
        ...
      }
      
      # after 'Post-Auth-Type REJECT'
      update outer.reply {
        User-Name := "%{request:User-Name}"
      }
    
      ...
    }


And finally edit `/etc/freeradius/eap.conf`:

    eap {
      ...
    
      default_eap_type = ttls
    
      gtc {
        ...
    
        auth_type = oauth2-perl
      }
    
      ttls {
        ...
    
        default_eap_type = gtc
    
        copy_request_to_tunnel = yes
    
        ...
      }
    
      ...
    }
    
# Testing

## OAuth2

On the target RADIUS server make sure you have a copy of curl available with:

    sudo apt-get install -yy --no-install-recommends curl python

Run the following, pointing at your OAuth2 discovery address, and extract `authorization_endpoint`:

    curl -s -L https://.../.well-known/openid-configuration | python -m json.tool

Now run (replacing `USERNAME`, `PASSWORD`, `example.com` and `TOKEN_ENDPOINT`):

    unset HISTFILE
    curl -i	-d scope=openid \
    		--data-urlencode client_id=$(awk -F= '/^client_id=/ { print $2 }' /opt/freeradius-oauth2-perl/config) \
    		--data-urlencode client_secret=$(awk -F= '/^client_secret=/ { print $2 }' /opt/freeradius-oauth2-perl/config) \
	    	-d grant_type=password \
	    	--data-urlencode username=USERNAME@example.com \
    		--data-urlencode password=PASSWORD \
    	TOKEN_ENDPOINT

**N.B.** Microsoft Azure users will need to also add `--data-urlencode resource=https://graph.windows.net` as an additional parameter

If this works you will get a HTTP 200 and an JSON response in the body, otherwise you will see a 400 error.

**N.B.** if you have multiple realms enabled in your `config`, then you will need to comment out the realms you do not wish to test.

## RADIUS

Before you test freeradius-oauth2-perl is working, you must make sure that the [OAuth2 test method](#OAuth2) above works first.  If it does not, the RADIUS test below will definitely not work.

To test freeradius-oauth2-perl is working, you need to have a copy of [`radtest`](http://wiki.freeradius.org/guide/Radtest).  To install it type

    sudo apt-get install -yy --no-install-recommends -t wheezy-backports freeradius-utils

Whilst testing, it helps a lot to first stop FreeRADIUS and run in a separate terminal in [debugging mode](http://wiki.freeradius.org/guide/Troubleshooting):

    /etc/init.d/freeradius stop
    freeradius -X | tee /tmp/freeradius.debug

You may also want to edit `/opt/freeradius-oauth2-perl/config` to have `debug=1` in the global section to provide more information; but do not leave this enabled for production!

To see if everything is working, type in a terminal on the target RADIUS server (amending `USERNAME`, `PASSWORD` and `example.com`):

    unset HISTFILE
    radtest USERNAME@example.com PASSWORD localhost 0 testing123 IGNORED 127.0.0.1

If it works, you should see an `Access-Accept` being returned:

    Sending Access-Request of id 226 to 127.0.0.1 port 1812
            User-Name = "USERNAME@example.com"
            User-Password = "PASSWORD"
            NAS-IP-Address = 127.0.0.1
            NAS-Port = 0
            Message-Authenticator = 0x00000000000000000000000000000000
            Framed-Protocol = PPP
    rad_recv: Access-Accept packet from host 127.0.0.1 port 1812, id=226, length=32
            Framed-Protocol = PPP
            Framed-Compression = Van-Jacobson-TCP-IP

A failure will either be no reply, or an `Access-Reject`:

    rad_recv: Access-Reject packet from host 127.0.0.1 port 1812, id=39, length=263
            Reply-Message = "Error: invalid_grant"
            Reply-Message = "AADSTS70002: Error validating credentials. AADSTS50020: Invalid username or password"
            Reply-Message = "Trace ID: 06389d3a-eeba-403a-b896-aeb5162f77a7"
            Reply-Message = "Correlation ID: 700ae598-934f-4dd1-b81b-fd2b75051101"
            Reply-Message = "Timestamp: 2015-02-02 10:08:22Z"

If there is a problem, look at the contents of `/tmp/freeradius.debug`.

### 802.1X

You will require a copy of [`eapol_test`](http://deployingradius.com/scripts/eapol_test/) which to build from source on your target RADIUS server you type:

    sudo apt-get install -yy --no-install-recommends build-essential libssl-dev libnl-dev
    curl -O -J -L http://w1.fi/releases/wpa_supplicant-2.3.tar.gz
    tar zxf wpa_supplicant-2.3.tar.gz
    sed -e 's/^#CONFIG_EAPOL_TEST=y/CONFIG_EAPOL_TEST=y/' wpa_supplicant-2.3/wpa_supplicant/defconfig > wpa_supplicant-2.3/wpa_supplicant/.config
    make -C wpa_supplicant-2.3/wpa_supplicant -j$(($(getconf _NPROCESSORS_ONLN)+1)) eapol_test

Once built, you will need a configuration file (amending `USERNAME`, `PASSWORD` and `example.com`):

    cat <<'EOF' > eapol_test.conf
    network={
      ssid="ssid"

      key_mgmt=WPA-EAP
      eap=TTLS
      phase2="auth=PAP"
      identity="USERNAME@example.com"
      anonymous_identity="@example.com"
      password="PASSWORD"
    
      #ca_path=/etc/ssl/certs
      #ca_file=/etc/ssl/certs/ca-certificates.crt
    }
    EOF

To test it works run:

    $ ./wpa_supplicant-2.3/wpa_supplicant/eapol_test -s testing123 -c eapol_test.conf

A successful test will have again an `Access-Accept` towards the end of the output:

    Received RADIUS message
    RADIUS message: code=2 (Access-Accept) identifier=5 length=184
       Attribute 1 (User-Name) length=24
          Value: 'USERNAME@example.com'
       Attribute 26 (Vendor-Specific) length=58
          Value: 00000137113...64768eac
       Attribute 26 (Vendor-Specific) length=58
          Value: 00000137103...a4dae19e
       Attribute 79 (EAP-Message) length=6
          Value: 03050004
       Attribute 80 (Message-Authenticator) length=18
          Value: 34468e4556b...c5c2230c
    STA 02:00:00:00:00:01: Received RADIUS packet matched with a pending request, round trip time 0.72 sec

**N.B.** in the case of a failure you will *not* get a set of `Reply-Message` attributes in the `Access-Reject` as [EAP does not allow this](https://tools.ietf.org/html/rfc3579#section-2.6.5)

# `xlat`

There is some basic xlat functionality in the module that lets you extract some state data about the current user where possible.

## `jsonpath`

This lets you pull any URL utilising the Web API token and extract arbitrary data from it, if nothing matches, you get an empty string and if you fetch a multi-value element only the first item will be returned.

The arguments are in order:

 * **realm:** the realm of the Web API token you want to use
 * **url:** URL to use the token against
 * **jsonpath:** a JSONPath statement to select the information you wish to extract

**N.B.** [JSON::Path](http://search.cpan.org/~tobyink/JSON-Path/lib/JSON/Path.pm) is used so if you wish to do filtering the section titled [JSONPath Embedded Perl Expressions](http://search.cpan.org/~tobyink/JSON-Path/lib/JSON/Path.pm#JSONPath_Embedded_Perl_Expressions) along with the examples below may help

**N.B.** your JSONPath will need escaping where you need to prepend `\\` before every occurrence of `$` and `}`

For example the following puts the `displayName` attribute into `Tmp-String-0`:

    authorize {
      ...
    
      update request {
        Tmp-String-0 := "%{oauth2-perl:jsonpath %{Realm} https://graph.windows.net/%{Realm}/users/%{User-Name}?api-version=1.5 \\$.displayName}"
      }
    
      ...
    }

**SECURITY WARNING:** rlm_perl xlat splits on spaces and quoting is completely ignored, so if any variables you use in the URL argument contain spaces, you will run into trouble.  `Realm` is safe as `suffix` protects you, but `User-Name`, and other user controllable fields, need validating so it is crucial that using something like `filter_username` is *strongly* recommended (including for `inner-tunnel`)

If you are not running a [recent multivalue supporting version of FreeRADIUS](https://github.com/FreeRADIUS/freeradius-server/blob/master/src/tests/keywords/if-multivalue), then the auto-populating of `Group-Name` is inaccessible, so you should use `jsonpath`.

For example the following will reject anyone not a member of the 'Office Staff' group:

    authorize {
      ...
    
      oauth2-perl
    
      ...
    
      update control {
        Tmp-String-0 := "%{oauth2-perl:jsonpath %{Realm} https://graph.windows.net/%{Realm}/groups?api-version=1.5 \\$.value[?(\\$_->{securityEnabled\\} eq 'true' && \\$_->{displayName\\} eq 'Office Staff')].objectId}"
      }
      if (control:Tmp-String-0) {
        update control {
          Tmp-String-1 := "%{oauth2-perl:jsonpath %{Realm} https://graph.windows.net/%{Realm}/groups/%{control:Tmp-String-0}/members?api-version=1.5 \\$.value[?(\\$_->{mailNickname\\} =~ /^%{Stripped-User-Name}\\$/i)].mailNickname}"
        }
        if (!(control:Tmp-String-1)) {
          update control {
            Auth-Type := Reject
          }
        }
      }
    
      ...
    }

**N.B.** although the above may look inefficient, the URL caching makes it very fast on subsequent runs, so it helps to keep any dynamic componment in the JSONPath filter rather than the URL
