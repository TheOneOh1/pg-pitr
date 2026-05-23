# Contributing to PostgreSQL PITR with pgBackRest

First off, thank you for taking the time to contribute! Contributions help make this project more robust and easier for the community to deploy.

The following guidelines outline how to set up your environment, follow our scripting standards, and submit your pull requests.

---

## Getting Started

### Project Structure
- `configs/`: Standalone, production-ready PostgreSQL and pgBackRest configuration templates.
- `docs/`: In-depth guides covering setup, troubleshooting, and standard operating procedures (SOP).
- `scripts/`: Production automation and helper scripts.
- `docker/`: Docker-compose and configuration files for a local, risk-free testing environment.

---

## Coding Standards

### Bash Scripting Standard

Key guidelines include:
1. **Safety Flags:** Every script must start with `set -Eeuo pipefail` to ensure immediate and clean failures.
2. **Defensive Coding:**
   - Always double-quote variables (e.g. `"${my_var}"` instead of `$my_var`) to prevent word splitting and globbing issues.
   - Declare local variables inside functions (e.g. `local path=$1`).
3. **Structured Logging:**
   - Avoid using raw `echo` for system messages.
   - Use the logging functions: `log_info`, `log_success`, `log_warn`, and `log_error`.
4. **Idempotency:** All commands and setups must be safe to execute multiple times without breaking the environment.

### Linting
We run `shellcheck` to catch potential bugs and structural warnings. Before committing changes to any bash script, ensure it passes ShellCheck completely:
```bash
shellcheck scripts/*.sh
```

---

## Testing Your Changes Local Sandbox

We provide a risk-free containerized sandbox inside the `docker/` directory. When testing script modifications or configuration changes:

1. **Start the Sandbox:**
   ```bash
   cd docker
   docker-compose up -d --build
   ```
2. **Log into the Sandbox:**
   ```bash
   docker exec -it pg_pitr_sandbox bash
   ```
3. **Run Verification:** Test stanza initialization, manual backups, or custom recovery workflows using your modified scripts mounted in `/scripts/`.
4. **Clean up:**
   ```bash
   docker-compose down -v
   ```

---

## Pull Request Process

1. **Branch Naming:** Use descriptive branch names:
   - `fix/description-of-bug`
   - `feat/feature-name`
   - `docs/doc-updates`
2. **Commit Messages:** Avoid vague messages. Use descriptive titles (e.g., `feat: add backup-now script using ShellCheck rules`).
3. **Template:** Complete the provided Pull Request template in full, including manual testing details and linter check confirmation.
4. **Code Quality:** Ensure no trailing whitespace, all scripts have execute permissions (`chmod +x`), and documentation markdown compiles cleanly.
