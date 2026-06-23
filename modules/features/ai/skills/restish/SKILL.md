---
name: restish
description: Configure and use restish CLI for REST APIs. Use when setting up restish, adding API endpoints, configuring auth, querying APIs, filtering responses, or working with OpenAPI specs via restish.
---

# Restish

CLI for interacting with REST-ish HTTP APIs with built-in OpenAPI support.

## Setup

### Install

```bash
brew install rest-sh/tap/restish
```

### Config locations

| OS    | `apis.json` path                                 |
| ----- | ------------------------------------------------- |
| macOS | `~/Library/Application Support/restish/apis.json` |
| Linux | `~/.config/restish/apis.json`                     |

Global config lives in the same directory as `config.json`.

### Register an API

**Always write directly to `apis.json`.** The interactive `restish api configure` command requires TTY input. Read the existing file, merge in the new API entry, and write it back.

```json
{
    "my-api": {
        "base": "https://api.example.com/v1",
        "spec_files": ["https://example.com/openapi.json"],
        "profiles": {
            "default": {
                "headers": {
                    "Authorization": "Bearer <token>"
                }
            }
        }
    }
}
```

Use python/jq to read-modify-write so you don't clobber existing API entries:

```bash
python3 -c "
import json, os
path = os.path.expanduser('~/Library/Application Support/restish/apis.json')
with open(path) as f: config = json.load(f)
config['my-api'] = {
    'base': 'https://api.example.com/v1',
    'spec_files': ['https://example.com/openapi.json'],
    'profiles': {'default': {'headers': {'Authorization': 'Bearer ' + os.environ['MY_TOKEN']}}}
}
with open(path, 'w') as f: json.dump(config, f, indent=2)
"
```

**Gotcha:** restish does not expand environment variables in config. Write the actual token value, or use a script to inject it from env vars at write time.

### Sync OpenAPI spec

```bash
restish api sync my-api
```

Restish auto-discovers specs at `/openapi.json` or `/openapi.yaml`. If the spec is elsewhere, set `spec_files` in config. Specs are cached for 24 hours.

If Cloudflare or CDN blocks the documented spec URL, look for an S3 or raw URL in the API's docs page source.

### Shell completion

```bash
restish completion fish --help
restish completion zsh --help
restish completion bash --help
```

## Authentication

### Bearer token / API key (most common)

Use persistent headers — no special auth name needed:

```json
{
    "profiles": {
        "default": {
            "headers": {
                "Authorization": "Bearer <token>"
            }
        }
    }
}
```

### HTTP Basic

```json
{
    "auth": {
        "name": "http-basic",
        "params": {
            "username": "user",
            "password": "pass"
        }
    }
}
```

### OAuth2 Client Credentials

```json
{
    "auth": {
        "name": "oauth-client-credentials",
        "params": {
            "client_id": "...",
            "client_secret": "...",
            "token_url": "https://auth.example.com/oauth/token",
            "scopes": ""
        }
    }
}
```

### OAuth2 Authorization Code (PKCE)

```json
{
    "auth": {
        "name": "oauth-authorization-code",
        "params": {
            "client_id": "...",
            "authorize_url": "https://auth.example.com/authorize",
            "token_url": "https://auth.example.com/oauth/token",
            "scopes": "offline_access"
        }
    }
}
```

### External tool

For custom signing schemes — pipes request JSON to a script:

```json
{
    "auth": {
        "name": "external-tool",
        "params": {
            "commandline": "my-auth-script"
        }
    }
}
```

### Profiles

Switch profiles with `-p`:

```bash
restish -p staging my-api list-users
```

## Querying

### Basic requests

```bash
restish my-api list-users                    # OpenAPI operation
restish my-api get-user 123                  # with path param
restish my-api/users                         # direct path
restish GET https://api.example.com/users    # full URL
```

### Query params

```bash
restish my-api/users -q 'page[number]=2' -q 'page[size]=10'
restish my-api/users?status=active
```

### Headers

```bash
restish -H Accept:application/json my-api/users
```

### POST / PUT / PATCH with body

**Important:** Restish does not support `-d` or `--data` flags. Body data is passed as positional arguments after the URI using shorthand syntax, or via stdin redirection.

```bash
# CLI shorthand — all key-value pairs in a SINGLE positional argument, comma-separated
restish post my-api/users "name: Alice, role: admin"

# Nested objects use dot notation
restish post my-api/users "name: Alice, address.city: NYC"

# Array indexing
restish post my-api/query "queries[0].refId: A, queries[0].expr: up, from: 123, to: 456"

# Quoted string values (use inner quotes for values that look like numbers or contain special chars)
restish post my-api/query 'from: "1234567890", to: "9876543210"'

# From file via stdin redirection
restish post my-api/users <user.json
```

**For complex or deeply nested JSON bodies** (for example, Grafana `ds/query`), the shorthand syntax gets unwieldy. Options:

1. **Shorthand in one arg** — flatten with dot notation and array indices:
   `"queries[0].datasource.uid: grafanacloud-prom, queries[0].expr: \"my_metric\""` (escape inner quotes)
2. **File redirect** — write JSON to a temp file and `< file.json`
3. **Shell script** — build args programmatically in a loop or helper script

**Common mistake:** Do not try `-d`, `-X POST`, or `--data` — these don't exist in restish. The verb (`post`, `put`, `patch`, `delete`) is a subcommand, not a flag.

### Editing resources

```bash
restish edit my-api/users/123 name: Bob      # GET + modify + PUT
restish edit -i my-api/users/123             # open in $EDITOR
```

## Output

### Formats

```bash
restish my-api/users                         # readable (interactive default)
restish my-api/users -o json                 # JSON
restish my-api/users -o table                # table (for arrays of objects)
restish my-api/users -o yaml                 # YAML
restish my-api/users -o gron                 # greppable paths
```

When piped, defaults to JSON body-only automatically.

### Filtering

Use `-f` with shorthand query syntax. Response structure is `{proto, status, headers, links, body}`.

```bash
restish my-api/users -f body                          # body only
restish my-api/users -f 'body[].name'                 # pluck field
restish my-api/users -f 'body.{id, name}'             # select fields
restish my-api/users -f 'body[status == active]'      # filter items
restish my-api/users -f 'body[name.lower contains al]' # string ops
restish my-api/users -f '..email'                     # recursive search
restish my-api/users -f headers.Date                  # access headers
```

### Raw mode

Strips quotes from string output — useful for scripting:

```bash
restish my-api/users -f 'body[0].id' -r
```

### Greppable discovery

```bash
restish my-api/users -o gron | grep -i email
```

## Pagination

Restish auto-paginates via RFC 5988 `next` link headers. Disable with:

```bash
restish --rsh-no-paginate my-api/users
```

For APIs using query-param pagination without link headers (like JSON:API), pass params manually:

```bash
restish my-api/users -q 'page[number]=2' -q 'page[size]=25'
```

## Global flags reference

| Flag                | Env var             | Purpose                 |
| ------------------- | ------------------- | ----------------------- |
| `-f`                | `RSH_FILTER`        | Filter/project response |
| `-H`                | `RSH_HEADER`        | Add header              |
| `-q`                | `RSH_QUERY`         | Add query param         |
| `-o`                | `RSH_OUTPUT_FORMAT` | Output format           |
| `-p`                | `RSH_PROFILE`       | Auth profile            |
| `-r`                | `RSH_RAW`           | Raw output              |
| `-s`                | `RSH_SERVER`        | Override server URL     |
| `-v`                | `RSH_VERBOSE`       | Verbose/debug           |
| `--rsh-no-paginate` | `RSH_NO_PAGINATE`   | Disable auto-pagination |
| `--rsh-no-cache`    | `RSH_NO_CACHE`      | Disable response cache  |
| `--rsh-insecure`    | `RSH_INSECURE`      | Skip TLS verification   |

## Rate limits

Before making multiple requests, check rate limits by reading response headers:

```bash
restish my-api/users -f 'headers.{X-Ratelimit-Limit, X-Ratelimit-Remaining, X-Ratelimit-Used, X-Ratelimit-Reset}'
```

Use this to understand your budget before scripting loops or bulk operations. Many APIs have tight rate limits.
## Useful commands

```bash
restish api show my-api          # show config
restish api edit                 # edit apis.json in $EDITOR
restish api sync my-api          # force-refresh OpenAPI spec
restish api clear-auth-cache     # clear OAuth token cache
restish my-api --help            # list all API operations
restish links my-api/users       # show hypermedia links
```

