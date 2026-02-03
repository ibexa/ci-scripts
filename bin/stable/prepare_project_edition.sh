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
    fi
    if [[ "$PROJECT_EDITION" == "commerce" ]]; then
      docker exec install_dependencies composer require ibexa/discounts:$PROJECT_VERSION ibexa/discounts-codes:$PROJECT_VERSION --with-all-dependencies --no-scripts --ansi
    fi
else
    echo "> Installing dependencies for v5"
    docker exec install_dependencies composer require ibexa/behat:$PROJECT_VERSION ibexa/docker:$PROJECT_VERSION ibexa/connector-anthropic:$PROJECT_VERSION --with-all-dependencies --no-scripts --ansi
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
