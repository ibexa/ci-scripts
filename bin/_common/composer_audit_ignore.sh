#!/bin/bash

add_composer_audit_ignore_config() {
    docker exec install_dependencies bash -c '
      set -o errexit
      cd /var/www

      script=$(mktemp)
      curl -fsSL \
        https://raw.githubusercontent.com/ibexa/ci-scripts/main/bin/_common/configure_composer_audit_ignores.sh \
        --output "$script"
      bash "$script"
    '

    return $?
}
