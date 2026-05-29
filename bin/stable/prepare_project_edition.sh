#!/bin/bash
set -e

PROJECT_EDITION=$1
PROJECT_VERSION=$2
PROJECT_BUILD_DIR=${HOME}/build/project
export COMPOSE_FILE=$3
export PHP_IMAGE=${4-ghcr.io/ibexa/docker/php:8.3-node18}
export COMPOSER_MAX_PARALLEL_HTTP=6 # Reduce Composer parallelism to work around Github Actions network errors

DEPENDENCY_PACKAGE_DIR=$(pwd)

echo '> Preparing project containers using the following setup:'
echo "- PROJECT_BUILD_DIR=${PROJECT_BUILD_DIR}"

# Go to main project dir
mkdir -p $PROJECT_BUILD_DIR && cd $PROJECT_BUILD_DIR

# Create container to install dependencies
docker run --name install_dependencies -d \
--volume=${PROJECT_BUILD_DIR}:/var/www:cached \
--volume=${HOME}/.composer:/root/.composer \
-e APP_ENV -e APP_DEBUG  \
-e COMPOSER_MAX_PARALLEL_HTTP \
-e PHP_INI_ENV_memory_limit -e COMPOSER_MEMORY_LIMIT \
-e COMPOSER_NO_INTERACTION=1 \
${PHP_IMAGE}

echo "> Setting up skeleton"
docker exec install_dependencies composer create-project ibexa/${PROJECT_EDITION}-skeleton:${PROJECT_VERSION} . --no-install --ansi

# Copy auth.json if needed
if [ -f ${DEPENDENCY_PACKAGE_DIR}/auth.json ]; then
    cp ${DEPENDENCY_PACKAGE_DIR}/auth.json .
fi

if [[ $PHP_IMAGE == *"8.3"* ]]; then
    echo "> Running composer install"
    docker exec install_dependencies composer install --no-scripts --ansi
else
    docker exec install_dependencies bash -c '
      cd /var/www

      add_audit_ignores() {
        local reason=$1
        shift

        for advisory in "$@"; do
          composer config audit.ignore --json --merge "{\"$advisory\":\"$reason\"}"
        done
      }

      PHP74_ADVISORIES=(
        PKSA-xwpn-zs9j-6wy5
        PKSA-sf9j-1gs7-xzvx
        PKSA-7h5p-prw9-w5nr
      )

      PHP74_PHP80_ADVISORIES=(
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
      )

      PHP_VERSION="$(php -r "echo PHP_MAJOR_VERSION . \".\" . PHP_MINOR_VERSION;")"

      if [ "$PHP_VERSION" = "7.4" ]; then
        add_audit_ignores \
          "The affected version of 3rd party component is installed on PHP 7.4. There is no alternative supporting PHP 7.4. Consider upgrading to PHP 8.1+" \
          "${PHP74_ADVISORIES[@]}"
      fi

      if [ "$PHP_VERSION" = "7.4" ] || [ "$PHP_VERSION" = "8.0" ]; then
        add_audit_ignores \
          "The affected version of 3rd party component is installed on PHP ${PHP_VERSION}. There is no alternative supporting PHP ${PHP_VERSION}. Consider upgrading to PHP 8.1+" \
          "${PHP74_PHP80_ADVISORIES[@]}"
      fi
    '

    echo "> Running composer update"
    docker exec install_dependencies composer update --no-scripts --ansi
fi

if [[ $PROJECT_VERSION == *"v3.3"* ]]; then
    echo "> Installing dependencies for 3.3"
    docker exec install_dependencies composer require ezsystems/behatbundle:^8.3 ibexa/docker:$PROJECT_VERSION --with-all-dependencies --no-scripts --ansi
elif [[ $PROJECT_VERSION == *"v4.6"* ]]; then
    echo "> Installing dependencies for v4"
    docker exec install_dependencies composer require ibexa/behat:$PROJECT_VERSION ibexa/docker:$PROJECT_VERSION --with-all-dependencies --no-scripts --ansi
    if [[ "$PROJECT_EDITION" != "oss" ]]; then
      echo "> Installing opt-in packages"
      # ibexa/connector-qualifio is already being installed with the project
      docker exec install_dependencies composer require ibexa/connector-ai:$PROJECT_VERSION ibexa/connector-openai:$PROJECT_VERSION --with-all-dependencies --no-scripts --ansi
      docker exec install_dependencies composer require ibexa/collaboration:$PROJECT_VERSION ibexa/share:$PROJECT_VERSION --with-all-dependencies --no-scripts --ansi
      if [[ "$PHP_IMAGE" != *"node18"* ]]; then
          docker exec install_dependencies composer require ibexa/fieldtype-richtext-rte:$PROJECT_VERSION --with-all-dependencies --no-scripts --ansi
      fi
      docker exec install_dependencies composer require ibexa/product-catalog-date-time-attribute:$PROJECT_VERSION --with-all-dependencies --no-scripts --ansi
      docker exec install_dependencies composer require ibexa/product-catalog-symbol-attribute:$PROJECT_VERSION --with-all-dependencies --no-scripts --ansi
      docker exec install_dependencies composer require ibexa/integrated-help:$PROJECT_VERSION --with-all-dependencies --no-scripts --ansi
      if [[ "$PHP_IMAGE" == *"node20"* ]]; then
          docker exec install_dependencies composer require ibexa/elasticsearch8:$PROJECT_VERSION --with-all-dependencies --no-scripts --ansi
      fi
    fi
    if [[ "$PROJECT_EDITION" == "commerce" ]]; then
      docker exec install_dependencies composer require ibexa/discounts:$PROJECT_VERSION ibexa/discounts-codes:$PROJECT_VERSION --with-all-dependencies --no-scripts --ansi
    fi
else
    echo "> Installing dependencies for v5"
    docker exec install_dependencies composer require ibexa/behat:$PROJECT_VERSION ibexa/docker:$PROJECT_VERSION --with-all-dependencies --no-scripts --ansi
    if [[ "$PROJECT_EDITION" != "oss" ]]; then
      docker exec install_dependencies composer require ibexa/connector-anthropic:$PROJECT_VERSION --with-all-dependencies --no-scripts --ansi
      docker exec install_dependencies composer require ibexa/connector-gemini:$PROJECT_VERSION --with-all-dependencies --no-scripts --ansi
      docker exec install_dependencies composer require ibexa/integrated-help:$PROJECT_VERSION --with-all-dependencies --no-scripts --ansi
      docker exec install_dependencies composer require ibexa/connector-raptor:$PROJECT_VERSION --with-all-dependencies --no-scripts --ansi
      docker exec install_dependencies composer require ibexa/translations-management:$PROJECT_VERSION --with-all-dependencies --no-scripts --ansi

      if [[ "${INSTALL_CONNECTOR_QUABLE:-false}" == "true" ]]; then
        docker exec install_dependencies composer require ibexa/connector-quable:$PROJECT_VERSION --with-all-dependencies --no-scripts --ansi
      fi
      
    fi
    if [[ "$PROJECT_EDITION" == "commerce" ]]; then
      docker exec install_dependencies composer require ibexa/shopping-list:$PROJECT_VERSION --with-all-dependencies --no-scripts --ansi
    fi  
fi

# Enable FriendsOfBehat SymfonyExtension in the Behat env
sudo sed -i "s/\['test' => true\]/\['test' => true, 'behat' => true\]/g" config/bundles.php

# Create a default Behat configuration file
cp "behat_ibexa_${PROJECT_EDITION}.yaml" behat.yaml

# Depenencies are installed and container can be removed
docker container stop install_dependencies
docker container rm install_dependencies

echo "> Start docker containers specified by ${COMPOSE_FILE}"
docker compose --env-file=.env up -d

# for Behat builds to work
echo '> Change ownership of files inside docker container'
docker compose --env-file=.env exec -T app sh -c 'chown -R www-data:www-data /var/www'

# Rebuild container
docker compose --env-file=.env exec -T --user www-data app sh -c "rm -rf var/cache/*"
echo '> Clear cache & generate assets'
if [[ $PROJECT_VERSION == *"v5.0"* ]]; then
    docker compose --env-file=.env exec -T --user www-data app sh -c "NODE_OPTIONS='--max-old-space-size=3072' composer run post-install-cmd --ansi"
else
    docker compose --env-file=.env exec -T --user www-data app sh -c "composer run post-install-cmd --ansi"
fi

echo '> Install data'
if [[ "$COMPOSE_FILE" == *"elastic"*.yml ]]; then
    docker compose --env-file=.env exec -T --user www-data app sh -c "php bin/console ibexa:elasticsearch:put-index-template"
fi
docker compose --env-file=.env exec -T --user www-data app sh -c "php /scripts/wait_for_db.php; php bin/console ibexa:install --skip-indexing --no-interaction"
docker compose --env-file=.env exec -T --user www-data app sh -c "php bin/console ibexa:reindex"

echo '> Display database version for debugging'
if [[ "$COMPOSE_FILE" == *"db-postgresql"*.yml ]]; then
    docker exec ibexa-db-1 sh -c "psql -V"
elif [[ "$COMPOSE_FILE" == *"db-mariadb"*.yml ]]; then
    docker exec ibexa-db-1 sh -c "mariadb --version"
else
    docker exec ibexa-db-1 sh -c "mysql -V"
fi

if [[ "$COMPOSE_FILE" == *"redis"*.yml ]]; then
    echo '> Display SPI (Redis) version for debugging'
    docker exec ibexa-redis-1 sh -c "redis-cli --version"
elif [[ "$COMPOSE_FILE" == *"valkey"*.yml ]] then
    echo '> Display SPI (Valkey) version for debugging'
    docker exec valkey sh -c "valkey-cli --version"
fi

echo '> Generate GraphQL schema'
docker compose --env-file=.env exec -T --user www-data app sh -c "php bin/console ibexa:graphql:generate-schema"

echo '> Done, ready to run tests'
