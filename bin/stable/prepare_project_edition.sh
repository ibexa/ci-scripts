#!/bin/bash
set -e

PROJECT_EDITION=$1
PROJECT_VERSION=$2
PROJECT_BUILD_DIR=${HOME}/build/project
export COMPOSE_FILE=$3
export PHP_IMAGE=${4-ezsystems/php:7.4-v2-node16}
export COMPOSER_MAX_PARALLEL_HTTP=6 # Reduce Composer parallelism to work around Github Actions network errors

DEPENDENCY_PACKAGE_DIR=$(pwd)
DEPENDENCY_PACKAGE_NAME=$(jq -r '.["name"]' "${DEPENDENCY_PACKAGE_DIR}/composer.json")
ls $DEPENDENCY_PACKAGE_NAME

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
docker exec install_dependencies composer create-project ibexa/${PROJECT_EDITION}-skeleton:${PROJECT_VERSION} . --no-install

# Copy auth.json if needed
if [ -f ./${DEPENDENCY_PACKAGE_NAME}/auth.json ]; then
    echo "AUTH FILE DETECTED IN ${DEPENDENCY_PACKAGE_NAME}, copying!"
    cp ${DEPENDENCY_PACKAGE_NAME}/auth.json .
fi

if [[ $PHP_IMAGE == *"8."* && $PROJECT_VERSION == *"v3.3"* ]]; then
    # See "Using PHP 8": https://doc.ibexa.co/en/3.3/getting_started/install_ez_platform/#set-up-authentication-tokens
    echo "> Running composer update"
    docker exec -e APP_ENV=dev install_dependencies composer update
else
    echo "> Running composer install"
    docker exec -e APP_ENV=dev install_dependencies composer install
fi

if [[ $PROJECT_VERSION == *"v3.3"* ]]; then
    echo "> Installing dependencies for 3.3"
    docker exec install_dependencies composer require ezsystems/behatbundle:^8.3 ibexa/docker:$PROJECT_VERSION --no-scripts
else
    echo "> Installing dependencies for v4"
    docker exec install_dependencies composer require ibexa/behat:^4.0 ibexa/docker:$PROJECT_VERSION --no-scripts
fi

# Enable FriendsOfBehat SymfonyExtension in the Behat env
sudo sed -i "s/\['test' => true\]/\['test' => true, 'behat' => true\]/g" config/bundles.php

# Create a default Behat configuration file
cp "behat_ibexa_${PROJECT_EDITION}.yaml" behat.yaml

# Depenencies are installed and container can be removed
docker container stop install_dependencies
docker container rm install_dependencies

echo "> Start docker containers specified by ${COMPOSE_FILE}"
docker-compose --env-file=.env up -d

# for Behat builds to work
echo '> Change ownership of files inside docker container'
docker-compose --env-file=.env exec -T app sh -c 'chown -R www-data:www-data /var/www'

# Rebuild container
docker-compose --env-file=.env exec -T --user www-data app sh -c "rm -rf var/cache/*"
echo '> Clear cache & generate assets'
docker-compose --env-file=.env exec -T --user www-data app sh -c "composer run post-install-cmd"

echo '> Install data'
docker-compose --env-file=.env exec -T --user www-data app sh -c "php /scripts/wait_for_db.php; php bin/console ibexa:install"

echo '> Generate GraphQL schema'
docker-compose --env-file=.env exec -T --user www-data app sh -c "php bin/console ibexa:graphql:generate-schema"

echo '> Done, ready to run tests'
