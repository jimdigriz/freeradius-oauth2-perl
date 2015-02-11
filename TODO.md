This page lists the outstanding tasks and problems I am yet to solve:

 * fetching users from azure is paged (100 at a time)
 * check threading in rlm_perl, global is probably on run once anyway, BEGIN{} for just validation and barfing at init
 * think of how to better handle xlat injection
 * caching
  * if unable to reauth, then do not expire data in cache
  * remove X-Cache-Key from request...does it matter?
  * add some garbage collector, maybe just make it an LRU?
 * HTTP keep-alive
 * TLS optimisations - https://bjornjohansen.no/optimizing-https-nginx
  * SSL_session_cache/SSL_session_cache_size/set_default_session_cache from IO::Socket::SSL
  * SSL_cipher_list/SSL_version
  * enable OCSP

## Google Apps

Google Apps does not support the Resource Owner Password Credentials Grant flow, which no doubt affects other OAuth2 providers too.

Pretty much means our only option is to have some kind of 'priming' step for every user, fortunately this is not as bad as it sounds as most would typically have to get instructions on how to setup an 802.1X connection so needs an 'out of bound' Internet connection anyway

Currently two workable solutions as I see them but with:

 * disadvantage is that the token could be encrypted with a mistyped in password by the user
 * advantage is this will work in two factor authentication environments; although of course the authentications against this module will remain single factor

There are plenty of usability problems faced here, so I need to mediate some more.

### 'Traditional' OAuth2

1. set up web page that user goes before using any service that relies on this module
1. get user to log in, and with the redirect, pass the authorisation token to the RADIUS server along with the users credentials
1. we then use the users own credentials to encrypt the token and so future re-authentications test if the token decrypts and is still valid

### Google's OAuth2 for Devices

This is rather interesting, but probably in practice offers nothing avoid the traditional model above.

1. when a user tries to log into a service for the first time, they are sent an SMS/twitter message telling them to go to a URL and punch in a code
1. once authenticated, the users own credentials are used to encrypt the token and future re-authentications test if the token decrypts and is still valid

# Bugs

### `Password-With-Header` corruption

Whilst working on the `Group-Name` functionality I found that calling `rlm_cache`, followed by `rlm_pap` and then `rlm_perl` cases for some reason `Password-With-Header` to be corrupted; although visually it looks fine (probably an extra NULL byte?).

I stumbled on a workaround, amusingly Heisenberg in nature, is to add a dummy assignment of `control:Password-With-Header` like so:

    oauth2-perl-cache
    
    ...
    
    if (control:Password-With-Header) {
      update control {
        Tmp-String-0 := "%{control:Password-With-Header}"
      }
    }
    pap
    oauth2-perl

Not tested to see if this is fixed in 3.x.
