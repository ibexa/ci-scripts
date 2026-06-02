#!/bin/bash

add_composer_audit_ignore_config() {
    docker exec install_dependencies bash -c '
      cd /var/www

      add_audit_ignores() {
        local reason=$1
        shift

        for advisory in "$@"; do
          composer config audit.ignore --json --merge "{\"$advisory\":\"$reason\"}"
        done

        return $?
      }

      PHP74_ADVISORIES=(
        PKSA-xwpn-zs9j-6wy5
        PKSA-sf9j-1gs7-xzvx
        PKSA-7h5p-prw9-w5nr
      )

      PHP7X_PHP80_ADVISORIES=(
        PKSA-5k7f-wvjj-jrgw
        PKSA-sjvz-tbbr-vwth
        PKSA-h8hf-ytnd-5t9q
        PKSA-wwb1-81rc-pd65
        PKSA-hgmw-wn4d-hpcy
        PKSA-kvv6-36cr-fkzb
        PKSA-n14z-jjjg-g8vd
        PKSA-3mcc-k66d-pydb
        PKSA-gw7n-z4yx-7xjt
        PKSA-dpx1-78wg-1kqs
        PKSA-21g2-dzjv-sky5
        PKSA-v3kg-5xkr-pykw
        PKSA-yhcn-xrg3-68b1
        PKSA-2wrf-1xmk-1pky
        PKSA-6319-ffpf-gx66
        PKSA-n7sg-8f52-pqtf
        PKSA-8kk8-h2xr-h5nx
        PKSA-2rbx-bjdx-4d4d
        PKSA-fs5b-x5k4-1h39
        PKSA-fbvq-z33h-r2np
        PKSA-g9zw-qxh8-pq8w
        PKSA-yd6k-t2gh-1m43
        PKSA-1tmc-rt7x-12w6
        PKSA-xx6c-6d96-db2w
      )

      PHP_VERSION="$(php -r "echo PHP_MAJOR_VERSION . \".\" . PHP_MINOR_VERSION;")"

      if [ "$PHP_VERSION" = "7.4" ]; then
        add_audit_ignores \
          "The affected version of 3rd party component is installed on PHP 7.4. There is no alternative supporting PHP 7.4. Consider upgrading to PHP 8.1+" \
          "${PHP74_ADVISORIES[@]}"
      fi

      if [ "$PHP_VERSION" = "7.3" ] || [ "$PHP_VERSION" = "7.4" ] || [ "$PHP_VERSION" = "8.0" ]; then
        add_audit_ignores \
          "The affected version of 3rd party component is installed on PHP ${PHP_VERSION}. There is no alternative supporting PHP ${PHP_VERSION}. Consider upgrading to PHP 8.1+" \
          "${PHP7X_PHP80_ADVISORIES[@]}"
      fi
    '

    return $?
}
