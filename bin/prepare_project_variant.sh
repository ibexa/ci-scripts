#!/bin/bash
set -e

PROJECT_VARIANT=$1
PROJECT_VERSION=$2
COMPOSE_FILE=$3

echo "> Setting up website skeleton"
EZPLATFORM_BUILD_DIR=${HOME}/build/ezplatform
# composer create-project ibexa/website-skeleton:^1.0@dev ${EZPLATFORM_BUILD_DIR} --no-scripts --repository=https://webhdx.repo.repman.io #TMP
composer create-project ibexa/dev-website-skeleton:dev-devel ${EZPLATFORM_BUILD_DIR} --no-scripts --repository='{"type": "vcs", "url": "https://gitlab.com/webhdx/dev-website-skeleton.git"}'

DEPENDENCY_PACKAGE_DIR=$(pwd)

# Get details about dependency package
DEPENDENCY_PACKAGE_NAME=`php -r "echo json_decode(file_get_contents('${DEPENDENCY_PACKAGE_DIR}/composer.json'))->name;"`
if [[ -z "${DEPENDENCY_PACKAGE_NAME}" ]]; then
    echo 'Missing composer package name of tested dependency' >&2
    exit 2
fi

echo '> Preparing project containers using the following setup:'
echo "- EZPLATFORM_BUILD_DIR=${EZPLATFORM_BUILD_DIR}"
echo "- DEPENDENCY_PACKAGE_NAME=${DEPENDENCY_PACKAGE_NAME}"

# Move dependency to directory available for docker volume
echo "> Move ${DEPENDENCY_PACKAGE_DIR} to ${EZPLATFORM_BUILD_DIR}/${DEPENDENCY_PACKAGE_NAME}"
mkdir -p ${EZPLATFORM_BUILD_DIR}/${DEPENDENCY_PACKAGE_NAME}
mv ${DEPENDENCY_PACKAGE_DIR}/* ${EZPLATFORM_BUILD_DIR}/${DEPENDENCY_PACKAGE_NAME}/

# Go to main project dir
cd ${EZPLATFORM_BUILD_DIR}

# Make sure .env exists - we haven't installed Symfony packages yet
touch .env

# Install package with Docker Compose files
composer config repositories.docker vcs https://github.com/mnocon/docker.git #TMP
composer require --no-update --prefer-dist mnocon/docker:^1.0@dev
composer update mnocon/docker --no-scripts
composer recipes:install mnocon/docker
rm composer.lock # remove lock created when installing Docker dependency

echo "> Make composer use tested dependency"
composer config repositories.localDependency path ./${DEPENDENCY_PACKAGE_NAME}

# Install correct product variant
composer require ibexa/${PROJECT_VARIANT}:${PROJECT_VERSION} --no-scripts --no-update

# Install packages required for testing
composer require --no-update --prefer-dist ezsystems/behatbundle:"dev-overwrite-mink-config as 8.3.x-dev" #TMP - should there be a metapackage for testing libraries?

echo "> Install DB and dependencies - use Docker for consistent PHP version"
docker-compose -f doc/docker/install-dependencies.yml up --abort-on-container-exit

echo '> Set up database connection'
echo 'DATABASE_URL=${DATABASE_PLATFORM}://${DATABASE_USER}:${DATABASE_PASSWORD}@${DATABASE_HOST}:${DATABASE_PORT}/${DATABASE_NAME}?serverVersion=${DATABASE_VERSION}' >> .env

echo "> Start docker containers specified by ${COMPOSE_FILE}"
docker-compose up -d

# for Behat builds to work
echo '> Change ownership of files inside docker container'
docker-compose exec app sh -c 'chown -R www-data:www-data /var/www'

echo '> Install data'
docker-compose exec --user www-data app sh -c "php /scripts/wait_for_db.php; php bin/console ezplatform:install clean" #TMP 1) hardcoded install type

echo '> Generate GraphQL schema'
docker-compose exec --user www-data app sh -c "php bin/console ezplatform:graphql:generate-schema"

echo '> Clear cache & generate assets'
docker-compose exec --user www-data app sh -c "composer run post-install-cmd"

echo '> Done, ready to run tests'
