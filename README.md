This is a [FreeRADIUS](http://freeradius.org/) [OAuth2 (OpenID Connect)](http://en.wikipedia.org/wiki/OpenID_Connect) [Perl module](http://wiki.freeradius.org/modules/Rlm_perl) to handle authentication.  It was created to allow the users of a wireless 802.1X (WPA Enterprise) network to connect.

**N.B.** this module relies on your OAuth2 provider supporting the [Resource Owner Password Credentials Grant](https://tools.ietf.org/html/rfc6749#section-4.3)

## Related Links

 * [RFC6749: The OAuth 2.0 Authorization Framework](https://tools.ietf.org/html/rfc6749)
 * [RFC7009: OAuth 2.0 Token Revocation](https://tools.ietf.org/html/rfc7009)
 * [OpenID Specifications](http://openid.net/developers/specs/)
  * [Connect Core](http://openid.net/specs/openid-connect-core-1_0.html)
  * [Connect Discovery](http://openid.net/specs/openid-connect-discovery-1_0.html)
  * [Connect Session Management](http://openid.net/specs/openid-connect-session-1_0.html)

## TODO

 * xlat for user attributes (eg. groups, email, name)
 * add some garbage collector to the token/endpoint stash
 * xlat method to utilise token (but *not* to provide them) and construct adhoc HTTP requests
 * HTTP keep-alive
 * TLS optimisations - https://bjornjohansen.no/optimizing-https-nginx
  * SSL_session_cache/SSL_session_cache_size/set_default_session_cache from IO::Socket::SSL
  * SSL_cipher_list/SSL_version
  * enable OCSP
 * on accounting stop, call either end_session_endpoint or revocation_endpoint
 * use the refresh_token for 're-auth's, if credential cache okayed everything, and fall back to full method
 * Google Apps integration - and probably others too
  * does not support Resource Owner Password Credentials Grant
  * means we have to have a 'priming' step for each user - not the end of the world as a user typically has to get instructions for how to use things like 802.1X so has to seek 'out of bound' Internet access from somewhere
   * 'traditional' oauth2: Set up web page that user goes before using any service that relies on this module.  Get user to log in, and with the redirect, send off the the authorisation token to the RADIUS server after getting the user to re-enter in their credentials.  Once authenticated, the users own credentials are used to encrypt the token and future re-authentications test if the token decrypts and is still valid
   * using Google's OAuth2 for Devices: They try to log in as usual into the service, but then are sent an SMS/twitter message telling them to go to a URL and punch in a code.  Once authenticated, the users own credentials are used to encrypt the token and future re-authentications test if the token decrypts and is still valid
  * disadvantage here is that is the token is encrypted with a mistyped password the user will have to rerun the process; plenty of other userability problems come to mind too
  * huge advantage is that this will work in two factor auth safe environments; although of course the authentications against this module will not be two factor

# Preflight

## Workstation

You will need to [have git installed on your workstation](http://git-scm.com/book/en/Getting-Started-Installing-Git) and [python](https://wiki.python.org/moin/BeginnersGuide).

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
 * **`cache` (default: 1800):** number of seconds to cache credentials for (internally uses a [salted SHA-1 hash](http://en.wikipedia.org/wiki/Cryptographic_hash_function#Password_verification))

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
	libtimedate-perl liburi-perl libcrypt-saltedhash-perl
    sudo apt-get install -yy --no-install-recommends -t wheezy-backports freeradius

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
1. enter in the application name `freeradius-oauth2-perl`, click on 'Native client application', and click on the next arrow
1. as a redirect URI, enter in `http://localhost:8000/code.html`, then click on the complete arrow
1. the application will now be added and you will be shown a preview page
1. before we leave, you will need the 'Client ID' (the long formatted hex string known as a [GUID](http://en.wikipedia.org/wiki/Globally_unique_identifier#Text_encoding)), which you can find located under both 'Configure' (at the top of the page) or 'Update your Code' (under the 'Getting Started' title)
1. place this Client ID in the `config` file under your realm as `client_id`

Using this Client ID, we now need to create an authorisation code, to do this, run a web server from a terminal, inside the project with:

    python -m SimpleHTTPServer

Now in your web browser go to (replacing `CLIENTID` with your Client ID from above):

    https://login.windows.net/common/oauth2/authorize?response_type=code&prompt=admin_consent&client_id=CLIENTID

You will be taken to a page asking you to permit freeradius-oauth2-perl access to enable sign-on and read users' profiles.  When you click on 'Accept' you will be redirected to a page that provides you with the authorisation code.  Take a copy of this, either with cut and paste or using the 'Export to File' link on that page and place it in the `config` file under your realm as `code`.

Now `Ctrl-C` the python web server as we have finished with it.

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

By now your `config` file should look something like:

    [example.com]
    vendor=microsoft-azure
    discovery=https://login.windows.net/example.com/.well-known/openid-configuration
    client_id=12345678-abcd-abcd-abcd-1234567890ab
    code=AAAB....

Copy `config` on your workstation to `/opt/freeradius-oauth2-perl` on the target RADIUS server, and then on the server run as root:

    chown root:freerad /opt/freeradius-oauth2-perl/config
    chmod 640 /opt/freeradius-oauth2-perl/config
    ln -T -f -s /opt/freeradius-oauth2-perl/module /etc/freeradius/modules/oauth2-perl

Amend `/etc/freeradius/sites-available/default` like so:

    authorize {
      ...
    
      #sql
    
      # after '#sql'
      update control {
        Cache-Status-Only := 'yes'
      }
      oauth2-perl-cache
      if (notfound) {
        update control {
          Cache-Status-Only !* ANY
        }
        oauth2-perl
      }
      else {
        update control {
          Cache-Status-Only !* ANY
        }
        oauth2-perl-cache
      }
    
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
    
    accounting {
      ...
    
      exec
      
      # after 'exec'
      oauth2-perl
    
      ...
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
    
      #sql
    
      # after '#sql'
      update control {
        Cache-Status-Only := 'yes'
      }
      oauth2-perl-cache
      if (notfound) {
        update control {
          Cache-Status-Only !* ANY
        }
        oauth2-perl
      }
      else {
        update control {
          Cache-Status-Only !* ANY
        }
        oauth2-perl-cache
      }
    
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

    sudo apt-get install -yy --no-install-recommends curl

Run the following, pointing at your OAuth2 discovery address, and extract `authorization_endpoint`:

    curl -s -L https://.../.well-known/openid-configuration | python -m json.tool

Now run (replacing `USERNAME`, `PASSWORD`, `example.com` and `AUTHORIZATION_ENDPOINT`):

    unset HISTFILE
    curl -i	-F scope=openid \
    		-F client_id=$(awk -F= '/^client_id=/ { print $2 }' /opt/freeradius-oauth2-perl/config) \
    		-F code=$(awk -F= '/^code=/ { print $2 }' /opt/freeradius-oauth2-perl/config) \
	    	-F grant_type=password \
	    	-F username=USERNAME@example.com \
    		-F password=PASSWORD \
    	AUTHORIZATION_ENDPOINT

**N.B.** Microsoft Azure users will need to also add `-F resource=https://graph.windows.net` as an parameter

If this works you will get a HTTP 200, otherwise you will see a 400 error.

**N.B.** if you have multiple realms enabled in your `config`, then you will need to comment out the realms you do not wish to test.

## RADIUS

Before you test freeradius-oauth2-perl is working, you must make sure that the [OAuth2 test method](#OAuth2) above works first.  If it does not, the RADIUS test below will definitely not work.

To test freeradius-oauth2-perl is working, you need to have a copy of [`radtest`](http://wiki.freeradius.org/guide/Radtest).  To install it type

    sudo apt-get install -yy --no-install-recommends -t wheezy-backports freeradius-utils

Whilst testing, it helps a lot to first stop freeradius and run in a separate terminal:

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

# Debugging

The interaction of this module in FreeRADIUS is as described to aid you when reading the [debugging output](http://wiki.freeradius.org/guide/Troubleshooting).

## `authorize`

 1. if `Auth-Type` is already set
  * return `noop`
 1. if `Realm` is not present or not set to a realm in `config`
  * return `noop`
 1. decides the request is for it
  * sets `Auth-Type` to `oauth2-perl`
  * deletes `Proxy-To-Realm` to force the request to not be proxied
  * return `updated`
 1. ...

## `authenticate`

 1. ...

# xlat

There is some basic xlat functionality in the module that lets you extract some state data about the current user where possible.

Calling the function with the following argument will return:
 * **`timestamp`:** epoch of when the authorization token was created
 * **`expires_in`:** time in seconds from `timestamp` that the [authorization token is valid](https://tools.ietf.org/html/rfc6749#section-5.1) for or `-1` if there is not one; this is *not* how long the `refresh_token` is valid for which is typically significantly longer

For example:

    post-auth {
      ...
    
      update reply {
        Acct-Interim-Interval := "%{oauth2-perl: expires_in}"
      }

      ...
    }
