## SHS - Simple Http(s) Server

This project is a tiny wrapper around `lua-http`, all it does it implement a more friendly
default http server setup for small services.

This project was created to move part of my lacord project code into its own repository.

### The API

The module you require exports one function: `new()`.

This function will take configuration and give you back a `lua-http` server object.

#### *table (lua-http server)* `new(options, crtfile, keyfile)`

Constructs a new lua-http server configured according to `options`.

- *table* `options.routes`
    `options.routes` must be a table which can be indexed with a uri path to produce
    a callback to handle the request. This callback will receive a `response` object.
    There is **no** fancy matching except the following: if no function is found the key `'*'` will
    be used to lookup a callback. As an alternative `options.routes`
    may itself be a function, in which case it will be called for every request.
- *luaossl openssl context?* `options.ctx`
    An optional openssl context object may be provided instead of providing `crtfile` and `keyfile`.
    If this option is not provided and neither are `crtfile` and `keyfile` then TLS will not be enabled.

- *string* `options.server`
    An optional string to set as the value of the server header. This should be a name identifying your application, by default this will be `"shs-http-server"`.

- *anything* `options.data`
    An optional value to be attached to response objects in their `.data` field.

- *table* `options.response_mt`
    An optional table to override the default response object metatable. The default metatable is exported as `shs.response_mt`.

- *string (file path)* `crtfile`
    An optional file path which should be the location of your TLS certificate chain in PEM format.

- *string (file path)* `keyfile`
    An optional file path which should be the location of your certificate's associated private key in PEM format.

Note that `options.ctx` and `crtfile` / `keyfile` are mutually exclusive. Please ensure when compiling luaossl you use a modern and up-to-date version of openssl.

> I would recommend using something like Nginx as a reverse proxy and having shs servers on local ports.


### Response Objects

The callbacks in `routes` will all receive a `response` object as their argument. Its methods and properties are described below:

#### *table (lua-http headers)* `request_headers`

The request's associated headers.

#### *table (lua-http stream)* `stream`

The underlying stream from client to server.

#### *string (peername)* `peername`

The address of the peer of the connection.

#### *string* `path`

The request's path with the query and fragment removed.

#### *table* `query`

A table containing the query portion of the request's path as key-value pairs (all strings).

#### *string* `method`

The request's HTTP method.

#### *anything* `data`

Data attached to the response from the [new](#table-lua-http-server-newoptions-crtfile-keyfile) option `data`.

#### *table (lua-http headers)* `headers`

The headers to send back with the response.


#### *string* `response:get_body()`

Retrieves the request's body, and will decompress it if necessary.

#### *void* `response:set_body(body)`

Sets the body to send back in the response.

- *string* `body`

#### *void* `response:set_500()`

Sets the status code to `500` and sets an appropriate default body.

#### *void* `response:set_503()`

Sets the status code to `503` and sets an appropriate default body.

#### *void* `response:set_401(msg)`

Sets the status code to `401` and sets an appropriate default body.

- *string* `msg`
    An alternative error message to be sent as `text/plain`.

#### *void* `response:set_ok()`

Sets the status code to `204`.

#### *void* `response:set_ok_and_reply(body, content_type)`

Sets the status code to `200` and sets the body and content type.

- *string* `body`
- *string (content type)* `content_type`

#### *void* `response:set_ok_and_reply(code, body, content_type)`

Sets the status code and sets the body and content type.

- *integer (HTTP status code)* `code`
- *string* `body`
- *string (content type)* `content_type`

#### *void* `response:redirect(location)`

Sets the status code to `302` and sets the location header.

- *string (uri)* `location`

#### *void* `response:redirect(code, location)`

Sets the status code and sets the location header.

- *integer (HTTP status code in [300, 400) )* `code`
    This value will become `302` if it is outside the valid 3XX range.
- *string (uri)* `location`