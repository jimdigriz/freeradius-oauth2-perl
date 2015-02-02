This is a [FreeRADIUS](http://freeradius.org/) [OAuth2 (OpenID Connect)](http://en.wikipedia.org/wiki/OpenID_Connect) [Perl module](http://wiki.freeradius.org/modules/Rlm_perl) to handle authentication.  It was created to allow the users of a wireless 802.1X (WPA Enterprise) network to connect.

**N.B.** this module relies on [`grant_type=password`](https://tools.ietf.org/html/rfc6749#section-4.3) being supported by your OAuth2 provider

## Related Links

 * [RFC6749: The OAuth 2.0 Authorization Framework](https://tools.ietf.org/html/rfc6749)
 * [OpenID Connect Core 1.0](http://openid.net/specs/openid-connect-core-1_0.html)

# Preflight

## Workstation

You will need to [have git installed on your workstation](http://git-scm.com/book/en/Getting-Started-Installing-Git), [cURL](http://curl.haxx.se/) and python.

**N.B.** Debian/Redhat users should be able to just type `sudo {apt-get,yum} install git curl python` whilst Mac OS X users should already have these tools present.

So we start off by fetching a copy of the project:

    git clone https://github.com/jimdigriz/freeradius-oauth2-perl.git
    cd freeradius-oauth2-perl

Now make a copy of the example configuration which is an [INI](http://en.wikipedia.org/wiki/INI_file) formatted file:

    cp example.config config

**N.B.** although you usually only have a single OAuth2 realm, the configuration does support multiple sections

Optionally, you can edit the following elements in the global section of `config`:

 * **`debug` (default: 0):** set to `1` to have verbose output, such as the HTTPS communications (note that you will see passwords in the clear!)
 * **`from` (default: [unset]):** set to a suitable contact email address for your organisation
 * **`secure` (default: 1):** set to `0` if you wish to turn off all the benefits of SSL (strongly *not* recommended)

## Target RADIUS Server

You require a Debian 'wheezy' 7.x server that is plumbed into [Debian Backports](http://backports.debian.org/), which if you have not done already is just a case of running:

    sudo cat <<'EOF' > /etc/apt/sources.list.d/debian-backports.list
    deb http://http.debian.net/debian wheezy-backports main
    #deb-src http://http.debian.net/debian wheezy-backports main
    EOF

    sudo apt-get update

Afterwards, you can get everything you need with:

    sudo apt-get install -yy --no-install-recommends \
    	libwww-perl libconfig-tiny-perl libjson-perl libjson-xs-perl libtimedate-perl liburi-perl
    sudo apt-get install -yy --no-install-recommends -t wheezy-backports \
    	freeradius freeradius-utils

You should now have set up a working *default* installation of FreeRADIUS 2.2.x.

**N.B.** if someone wants to step forward to help get this working on another UNIX system (*BSD, another Linux, Mac OS X, etc) and/or a later version of FreeRADIUS, then do get in touch

On the server, run:

    mkdir /opt/freeradius-oauth2-perl

From the project directory on your workstation, copy `main.pm` and `module` to `/opt/freeradius-oauth2-perl` and run on the server:

    chown -R root:root /opt/freeradius-oauth2-perl

# Configuration

## OAuth2 Discovery

If you run a *secure* HTTPS website at `https://example.com` then you can make use of the auto-discovery mechanism, by making:

    https://example.com/.well-known/openid-configuration

Generate an HTTP redirect depending on your authentication provider to:

 * **Microsoft Azure AD (Office 365):** `https://login.windows.net/example.com/.well-known/openid-configuration`
 * **Google Apps [not supported]:** `https://accounts.google.com/.well-known/openid-configuration`

If you do not have a *secure* website at the apex of your realm, then you will need to:

1. in a terminal run the following amending the `.well-known/openid-configuration` URL appropriately to point at your authentication provider

        curl -s -L https://.../.well-known/openid-configuration | python -m json.tool
1. extract the `authorization_endpoint` and `token_endpoint` entries (which *must* be HTTPS)
1. edit `config` and add `authorization_endpoint` and `token_endpoint` entries for your realm

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
1. place this Client ID in the `config` file under your realm as `clientid`

Using this Client ID, we now need to create an authorisation code, to do this, run a web server from a terminal, inside the project with:

    python -m SimpleHTTPServer

Now in your web browser go to (replacing `<CLIENTID>` with your Client ID from above):

    https://login.windows.net/common/oauth2/authorize?response_type=code&prompt=admin_consent&client_id=<CLIENTID>

You will be taken to a page asking you to permit freeradius-oauth2-perl access to enable sign-on and read users' profiles.  When you click on 'Accept' you will be redirected to a page that provides you with the authorisation code.  Take a copy of this, either with cut and paste or using the 'Export to File' link on that page and place it in the `config` file under your realm as `code`.

Now `Ctrl-C` the python web server as we have finished with it.

#### Related Links

 * [OAuth 2.0 in Azure AD](https://msdn.microsoft.com/en-us/library/azure/dn645545.aspx)
 * [Microsoft Azure REST API + OAuth 2.0](https://ahmetalpbalkan.com/blog/azure-rest-api-with-oauth2/)

### Google Apps

**N.B.** works in progress

#### Related Links

 * [OpenID Connect (OAuth 2.0 for Login)](https://developers.google.com/accounts/docs/OpenIDConnect)
 * [Using OAuth 2.0 for Devices](https://developers.google.com/accounts/docs/OAuth2ForDevices) - via SMS or email maybe?

## FreeRADIUS

By now your `config` file should look something like:

    [example.com]
    clientid=12345678-abcd-abcd-abcd-1234567890ab
    code=AAAB....
    authorization_endpoint=https://.../oauth2/authorize
    token_endpoint=https://.../oauth2/token

Copy `config` on your workstation to `/opt/freeradius-oauth2-perl` on the target RADIUS server, and then on the server run as root:

    chown root:freerad /opt/freeradius-oauth2-perl/config
    chmod 640 /opt/freeradius-oauth2-perl/config
    ln -T -f -s /opt/freeradius-oauth2-perl/module /etc/freeradius/modules/freeradius-oauth2-perl

Amend `/etc/freeradius/sites-available/default` like so:

    authorize {
      ...
    
      files
    
      # after 'files'
      freeradius-oauth2-perl
    
      ...
    }
    
    authenticate {
      ...
    
      eap
      
      # after 'eap'
      Auth-Type freeradius-oauth2-perl {
        freeradius-oauth2-perl
      }
    }
    
    accounting {
      ...
    
      exec
      
      # after 'exec'
      freeradius-oauth2-perl
    
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
    
      files
    
      # after 'files'
      freeradius-oauth2-perl
    
      ...
    }
    
    authenticate {
      ...
    
      eap
      
      # after 'eap'
      Auth-Type freeradius-oauth2-perl {
        freeradius-oauth2-perl
      }
    }
    
    post-auth {
      ...
    
      #ldap
      
      # after '#ldap'
      update outer.reply {
        User-Name := "%{User-Name}"
      }
    
      ...
    }


And finally edit the `ttls` section in `/etc/freeradius/eap.conf`:

    ttls {
      ...
    
      copy_request_to_tunnel = yes
    
      ...
    }
    
# Testing

## OAuth2

Put a copy of your user name in a file called `username`, and your password in `password`.  Now type:

    curl -i	-F scope=openid \
    		-F client_id=$(awk -F= '/^clientid=/ { print $2 }' config) \
    		-F code=$(awk -F= '/^code=/ { print $2 }' config) \
	    	-F resource=00000002-0000-0000-c000-000000000000 \
	    	-F grant_type=password \
	    	-F username=\<username \
    		-F password=\<password \
    	$(awk -F= '/^token_endpoint=/ { print $2 }' config)

**N.B.** if you have multiple realms enabled in your `config`, then you will need to comment out *all* the ones you are not testing

If this works you will get a HTTP 200, otherwise you will see a 400 error.  If successful, type the following to remove your credentials:

    shred -f -u username password || srm -f username password

## RADIUS

On your RADIUS server, you can test everything is working by typing:

    radtest <USER>@example.com <PASSWORD> localhost 0 testing123 IGNORED 127.0.0.1

**N.B.** this will *not* work if the [OAuth2 test](#OAuth2) above fails to work

### 802.1X

You will require a copy of [`eapol_test`](http://deployingradius.com/scripts/eapol_test/) which to build from source on your target RADIUS server you type:

    sudo apt-get install -yy --no-install-recommends curl build-essential libssl-dev libnl-dev
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

# Debugging

The interaction of this module in FreeRADIUS is as described to aid you when reading the [debugging output](http://wiki.freeradius.org/guide/Troubleshooting).

## `authorize`

 1. if `Auth-Type` is already set
  * return `noop`
 1. if `Realm` is not present or not set to a realm in `config`
  * return `noop`
 1. decides the request is for it
  * sets `Auth-Type` to `freeradius-oauth2-perl`
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
        Acct-Interim-Interval := "%{freeradius-oauth2-perl: expires_in}"
      }

      ...
    }
