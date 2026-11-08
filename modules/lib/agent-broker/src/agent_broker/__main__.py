"""Streaming HTTP broker: replace the caller's credential and forward a fixed upstream."""

from __future__ import annotations

import sys

from aiohttp import ClientSession, ClientTimeout, web

from . import HOP_BY_HOP, allowed, build_headers, load_config, read_credential

# Large enough for a calibre upload; the broker still streams rather than buffering the reply.
MAX_REQUEST_BYTES = 200 * 1024 * 1024


def make_app(config, key: str) -> web.Application:
    app = web.Application(client_max_size=MAX_REQUEST_BYTES)

    async def handle(request: web.Request) -> web.StreamResponse:
        if not allowed(config.allow, request.method, request.path):
            return web.Response(status=403, text="agent-broker: route not allowed\n")
        url = config.upstream + request.path_qs
        headers = build_headers(dict(request.headers), config.auth, key)
        timeout = ClientTimeout(total=None, connect=10, sock_read=600)
        async with ClientSession(timeout=timeout) as session:
            async with session.request(
                request.method,
                url,
                headers=headers,
                data=request.content.iter_chunked(64 * 1024),
                allow_redirects=False,
            ) as upstream:
                response = web.StreamResponse(status=upstream.status)
                for name, value in upstream.headers.items():
                    if name.lower() not in HOP_BY_HOP | {"content-length", "content-encoding"}:
                        response.headers[name] = value
                await response.prepare(request)
                async for chunk in upstream.content.iter_any():
                    await response.write(chunk)
                await response.write_eof()
                return response

    app.router.add_route("*", "/{tail:.*}", handle)
    return app


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) != 1:
        print("usage: agent-broker <config.json>", file=sys.stderr)
        return 2
    config = load_config(argv[0])
    key = read_credential(config.auth.credential) if config.auth.kind != "none" else ""
    web.run_app(
        make_app(config, key),
        host=config.host,
        port=config.port,
        access_log=None,
        print=None,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
