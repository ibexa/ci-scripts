#!/bin/bash

add_composer_audit_ignore_config() {
    # CI_SCRIPTS_REF is passed into the container via -e so the single-quoted
    # heredoc below is expanded by the container's bash, not the parent shell.
    docker exec -e CI_SCRIPTS_REF install_dependencies bash -c '
      set -o errexit
      cd /var/www

      script=$(mktemp)
      curl -fsSL \
        "https://raw.githubusercontent.com/ibexa/ci-scripts/${CI_SCRIPTS_REF:-main}/bin/_common/configure_composer_audit_ignores.sh" \
        --output "$script"
      bash "$script"
    '

    return $?
}
