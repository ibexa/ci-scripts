#!/bin/bash
set -e

PROJECT_EDITION=$1
PROJECT_VERSION=$2
COMPOSE_FILE=$3
PHP_IMAGE=${4-ezsystems/php:7.3-v2-node12}

echo "> Setting up website skeleton"
PROJECT_BUILD_DIR=${HOME}/build/project
composer create-project ibexa/website-skeleton ${PROJECT_BUILD_DIR} --no-install --no-scripts 

if [[ -n "${DOCKER_PASSWORD}" ]]; then
    echo "> Set up Docker credentials"
    echo ${DOCKER_PASSWORD} | docker login -u ${DOCKER_USERNAME} --password-stdin
fi

# Create container to install dependencies
docker run --name install_dependencies -d --volume=${PROJECT_BUILD_DIR}:/var/www:cached --volume=${HOME}/.composer:/root/.composer -e APP_ENV -e APP_DEBUG ${PHP_IMAGE}

# Get details about dependency package
DEPENDENCY_PACKAGE_DIR=$(pwd)
DEPENDENCY_PACKAGE_NAME=`php -r "echo json_decode(file_get_contents('${DEPENDENCY_PACKAGE_DIR}/composer.json'))->name;"`
DEPENDENCY_PACKAGE_VERSION=`php -r "echo json_decode(file_get_contents('${DEPENDENCY_PACKAGE_DIR}/composer.json'))->extra->{'branch-alias'}->{'dev-master'};"`
if [[ -z "${DEPENDENCY_PACKAGE_NAME}" ]]; then
    echo 'Missing composer package name of tested dependency' >&2
    exit 2
fi

echo '> Preparing project containers using the following setup:'
echo "- PROJECT_BUILD_DIR=${PROJECT_BUILD_DIR}"
echo "- DEPENDENCY_PACKAGE_NAME=${DEPENDENCY_PACKAGE_NAME}"

# Move dependency to directory available for docker volume
echo "> Move ${DEPENDENCY_PACKAGE_DIR} to ${PROJECT_BUILD_DIR}/${DEPENDENCY_PACKAGE_NAME}"
mkdir -p ${PROJECT_BUILD_DIR}/${DEPENDENCY_PACKAGE_NAME}
mv ${DEPENDENCY_PACKAGE_DIR}/* ${PROJECT_BUILD_DIR}/${DEPENDENCY_PACKAGE_NAME}/

# Go to main project dir
cd ${PROJECT_BUILD_DIR}

echo "> Make composer use tested dependency"
JSON_STRING=$( jq -n \
                  --arg packageVersion "$DEPENDENCY_PACKAGE_VERSION" \
                  --arg packageName "$DEPENDENCY_PACKAGE_NAME" \
                  --arg packageDir "./$DEPENDENCY_PACKAGE_NAME" \
                  '{"type": "path", "url": $packageDir, "options": { "versions": { ($packageName): $packageVersion}}}' )

composer config repositories.localDependency "$JSON_STRING"

# Install correct product variant
docker exec install_dependencies composer update
docker exec -e APP_ENV=dev install_dependencies composer require ibexa/${PROJECT_EDITION}:${PROJECT_VERSION}

# Install packages required for testing
docker exec install_dependencies composer require --dev ezsystems/behatbundle --no-scripts
docker exec install_dependencies composer sync-recipes ezsystems/behatbundle --force

# Init a repository to avoid Composer asking questions
git init; git add . > /dev/null;

# Execute Ibexa recipes
docker exec install_dependencies composer recipes:install ibexa/${PROJECT_EDITION} --force

# Install Docker stack
docker exec install_dependencies composer require --dev ibexa/docker:^0.1@dev

# Depenencies are installer and container can be removed
docker container stop install_dependencies
docker container rm install_dependencies

echo "> Start docker containers specified by ${COMPOSE_FILE}"
docker-compose up -d

# for Behat builds to work
echo '> Change ownership of files inside docker container'
docker-compose exec app sh -c 'chown -R www-data:www-data /var/www'

echo '> Install data'
docker-compose exec --user www-data app sh -c "php /scripts/wait_for_db.php; php bin/console ibexa:install"

echo '> Generate GraphQL schema'
docker-compose exec --user www-data app sh -c "php bin/console ibexa:graphql:generate-schema"

echo '> Clear cache & generate assets'
docker-compose exec --user www-data app sh -c "composer run post-install-cmd"

echo '> Done, ready to run tests'
