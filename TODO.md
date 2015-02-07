This page lists the outstanding tasks and problems I am yet to solve:

 * xlat for user attributes (eg. groups, email, name)
 * add some garbage collector to the cache (offload into rlm_cache?)
 * HTTP keep-alive
 * TLS optimisations - https://bjornjohansen.no/optimizing-https-nginx
  * SSL_session_cache/SSL_session_cache_size/set_default_session_cache from IO::Socket::SSL
  * SSL_cipher_list/SSL_version
  * enable OCSP
 * on accounting stop, call either end_session_endpoint or revocation_endpoint
 * use the refresh_token for 're-auth's, if credential cache okayed everything, and fall back to full method

# Google Apps

Google Apps does not support the Resource Owner Password Credentials Grant flow, which no doubt affects other OAuth2 providers too.

Pretty much means our only option is to have some kind of 'priming' step for every user, fortunately this is not as bad as it sounds as most would typically have to get instructions on how to setup an 802.1X connection so needs an 'out of bound' Internet connection anyway

Currently two workable solutions as I see them but with:

 * disadvantage is that the token could be encrypted with a mistyped in password by the user
 * advantage is this will work in two factor authentication environments; although of course the authentications against this module will remain single factor

There are plenty of usability problems faced here, so I need to mediate some more.

## 'Traditional' OAuth2

1. set up web page that user goes before using any service that relies on this module
1. get user to log in, and with the redirect, pass the authorisation token to the RADIUS server along with the users credentials
1. we then use the users own credentials to encrypt the token and so future re-authentications test if the token decrypts and is still valid

## Google's OAuth2 for Devices

This is rather interesting, but probably in practice offers nothing avoid the traditional model above.

1. when a user tries to log into a service for the first time, they are sent an SMS/twitter message telling them to go to a URL and punch in a code
1. once authenticated, the users own credentials are used to encrypt the token and future re-authentications test if the token decrypts and is still valid
