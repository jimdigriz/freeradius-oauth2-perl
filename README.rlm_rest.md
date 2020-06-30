A good question is why not to use [`rlm_rest`](https://freeradius.org/modules/?cat=io&mod=rlm_rest) and [`rlm_cache`](https://freeradius.org/modules/?s=cache&mod=rlm_cache) stitched together with [unlang](https://freeradius.org/radiusd/man/unlang.html).

FreeRADIUS makes working with a REST API really difficult for the following (undocumented) reasons:

 * does not support parse nested objects
     * user/group is nested as `.value[].{userPrincipalName,displayName}`
     * cannot be flatten by the [Microsoft Graph API](https://docs.microsoft.com/en-us/graph/use-the-api)
 * URI handling is...peculiar
     * validation of the URL is done *before* `xlat` and as `://` cannot be found it is considered invalid
     * host/path components are treated differently
     * every `xlat` evaluation in the path is URL encoded unconditionally
     * as such if you have an attribute that contains a correctly formed query string (or URI) it breaks it
         * such URLs can be found in the OAuth2 Discovery document and...
 * does not make the HTTP headers of the response available
     * parsing [`Cache-Control`](https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Cache-Control) headers is impossible
 * makes supporting paging impossible
     * we need to use the [full URL](https://docs.microsoft.com/en-us/graph/paging) from the response to walk through pages, unfortunately the unconditional escaping of `xlat`'s make this not possible

As such, this is implemented using [`rlm_perl`](https://freeradius.org/modules/?s=perl&mod=rlm_perl) to maintain accessibility to others.
