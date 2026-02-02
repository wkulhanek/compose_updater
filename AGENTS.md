# AGENTS.md

This file contains development guidelines and commands for agentic coding agents working in this repository.

## Project Overview

This is a Bash-based Docker Compose updater for LXC containers on Proxmox hosts. The project consists of a single main script that automates container updates with comprehensive error handling, health checks, and notifications.

## Build/Test/Development Commands

### Running the Script
```bash
# Basic execution
./compose_updater.sh

# Dry-run mode (always test first)
./compose_updater.sh --dry-run

# Test with specific container
./compose_updater.sh --dry-run --filter "container-name"

# With timestamps for debugging
./compose_updater.sh --timestamp --dry-run
```

### Testing/Validation
```bash
# No formal test suite - validation is done through:
# 1. Shell syntax checking
bash -n compose_updater.sh

# 2. Dry-run testing
./compose_updater.sh --dry-run --timestamp

# 3. Manual command-line argument testing
./compose_updater.sh --help
```

### Linting/Code Quality
```bash
# Check Bash syntax
bash -n compose_updater.sh

# Check for common Bash issues with shellcheck (if available)
shellcheck compose_updater.sh

# Verify script permissions
ls -la compose_updater.sh
```

## Code Style Guidelines

### Script Structure and Organization
- **Header**: Always include shebang `#!/bin/bash` and brief description
- **Error Handling**: Use `set -euo pipefail` at script start
- **Functions**: Define all functions before main script logic
- **Constants**: Define global variables/constants at top after error handling setup

### Naming Conventions
- **Variables**: Use `UPPER_SNAKE_CASE` for global constants, `lower_snake_case` for local variables
- **Functions**: Use `lower_snake_case` with descriptive names (e.g., `log_info`, `check_container_health`)
- **Constants**: Use `UPPER_SNAKE_CASE` for configuration values that don't change during execution

### Code Formatting
- **Indentation**: Use 4 spaces (no tabs)
- **Line Length**: Keep lines under 100 characters when possible
- **Spacing**: Use spaces around operators (`=` in variable assignments, `[[ ]]` in tests)
- **Comments**: Minimal, only for complex logic or non-obvious behavior

### Error Handling Patterns
- **Strict Mode**: Always use `set -euo pipefail`
- **Function Returns**: Check return codes explicitly with `if ! command; then`
- **Error Messages**: Use `log_error` function for consistency, send to stderr
- **Graceful Degradation**: Continue processing other items when one fails (container processing loop)

### Logging and Output
- **Log Functions**: Use the defined log functions: `log_info`, `log_warn`, `log_error`, `log_dry_run`, `log_success`, `log_debug`
- **Colors**: Use predefined color constants for consistent output
- **Timestamps**: Respect `LOG_WITH_TIMESTAMP` flag for optional timestamping
- **Error Streams**: Send errors to stderr, normal output to stdout

### Command Line Argument Handling
- ** getopt Pattern**: Use `while [[ $# -gt 0 ]]; do case $1 in ... esac; done`
- **Help Function**: Always provide `--help` option with usage examples
- **Default Values**: Set defaults before argument parsing
- **Validation**: Validate required arguments and show helpful error messages

### Security Best Practices
- **Input Validation**: Validate all user inputs and external data
- **Command Injection**: Use proper quoting for all variables in commands
- **Permissions**: Don't assume root access, check requirements
- **Sensitive Data**: Avoid logging passwords, API keys, or sensitive information

### Function Design Patterns
- **Single Responsibility**: Each function should do one thing well
- **Parameters**: Pass data as function parameters, avoid global variables when possible
- **Return Codes**: Use standard Unix conventions (0=success, non-zero=error)
- **Error Handling**: Handle errors within functions or propagate them appropriately

### Code Organization Sections
1. **Header**: Shebang, description, strict mode
2. **Constants**: Color definitions, global configuration
3. **Functions**: Logging, error handling, core logic
4. **Main Script**: Argument parsing, main execution flow

### Testing Philosophy
- **Dry-Run Mode**: Always provide `--dry-run` option for safe testing
- **Verbosity**: Use `--timestamp` and log levels for debugging
- **Dependency Checks**: Verify required commands are available
- **Graceful Failures**: Provide helpful error messages for missing dependencies

### Documentation Standards
- **Comments**: Only add comments for non-obvious logic
- **Function Docs**: Brief inline comments for complex functions
- **README**: Keep README.adoc updated with usage examples and troubleshooting
- **Help Output**: Comprehensive `--help` with examples

### Specific Patterns for This Project
- **Container Processing**: Continue processing other containers if one fails
- **Health Checks**: Implement timeout and retry logic with detailed logging
- **Notifications**: Handle both email and webhook methods gracefully
- **LXC Commands**: All LXC operations should be wrapped with error handling

### Dependencies and Requirements
- **Bash Version**: Requires Bash 4.0+ (for arrays and modern features)
- **System Commands**: `lxc-ls`, `lxc-attach`, `docker`, `mail` (optional), `curl` (optional)
- **Privileges**: Requires root access for LXC container operations

### Git Workflow
- **Commits**: Write clear, concise commit messages focusing on the "why"
- **Testing**: Always test with `--dry-run` before committing functional changes
- **Documentation**: Update README.adoc when adding new features or options

### Performance Considerations
- **Parallel Processing**: Currently sequential - consider parallel container processing for scalability
- **Resource Usage**: Clean up temporary resources and handle signals gracefully
- **Network Operations**: Implement timeouts for all external network calls

### Backward Compatibility
- **Command Line**: Maintain compatibility with existing command-line interface
- **Configuration**: Preserve existing default behavior when adding new options
- **Output Format**: Keep log output format stable for parsing scripts