## Flutter Smartschool

Unofficial Dart client library for Smartschool.

## Smartschool Researcher MCP Server

This repository includes a local MCP server that wraps `DevInspector` so
Copilot Agent mode can explore Smartschool endpoints directly.

- Server entrypoint: `bin/smartschool_researcher_mcp.dart`
- VS Code MCP config: `.vscode/mcp.json`
- Default credentials source: `credentials.yml` (auto-discovered)

### Available MCP tools

- `login`
	- Logs in with `credentials.yml`, or with inline `username/password/mainUrl`.
- `login_status`
	- Verifies whether the current MCP server session is authenticated.
- `get_page`
	- Performs an authenticated GET for HTML/text pages.
- `post_form`
	- Performs an authenticated `application/x-www-form-urlencoded` POST.
- `request`
	- Generic request tool (method, headers, query, body, content type).
- `get_json`
	- GET with JSON accept header and parsed JSON in output.

### Typical Agent flow

1. Call `login` once.
2. Call `get_page` for pages like `/?module=Messages`.
3. Call `post_form` or `request` to emulate browser form/XHR actions.
4. Use returned `statusCode`, `headers`, `body`, and parsed `json` to design
	 service methods and models.

### Notes

- The MCP server is for development/research only.
- Keep `credentials.yml` local and private.
- For very large payloads, pass `maxBodyChars` to truncate the response body.
