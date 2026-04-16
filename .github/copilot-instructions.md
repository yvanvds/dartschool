## Smartschool API — Copilot Context

This is an unofficial Dart HTTP client for the Smartschool school platform.

### Key files
- `lib/src/credentials.dart` — AppCredentials, base URL
- `lib/src/session.dart` — SmartschoolClient, handles auth + cookie jar
- `lib/src/dev/dev_inspector.dart` — raw HTTP inspector for reverse engineering
- `dev_dumps/` — raw HTML/JSON responses captured from the live site

### Conventions
- Services live in `lib/src/services/`
- Models live in `lib/src/models/`
- All services take a `SmartschoolClient` in their constructor
- Parse HTML with the `html` package (CSS selectors preferred)
- Parse JSON directly with `dart:convert`

### When implementing a new feature
1. Check `dev_dumps/` for a captured response
2. Identify the form fields or JSON keys
3. Add a model in `models/`, a method in the relevant service
- Use one public class per file unless classes are tiny and tightly coupled.
- Prefer small, focused services with a single responsibility.
- When generating Dart code, prefer clear naming and null-safe patterns.

### NEVER EVER
- Hardcode credentials or sensitive data in the codebase
- Commit real credentials to GitHub
- Use the MCP server for anything other than development/research
- Use the MCP server to send messages to anyone but the developer's own account
- Use the MCP server to interact with the live site in any way that could be disruptive