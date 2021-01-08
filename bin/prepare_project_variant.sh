#!/bin/bash
set -e

PROJECT_VARIANT=$1
PROJECT_VERSION=$2
COMPOSE_FILE=$3

echo "> Setting up website skeleton"
PROJECT_BUILD_DIR=${HOME}/build/project
composer create-project ibexa/website-skeleton:dev-main ${PROJECT_BUILD_DIR}

DEPENDENCY_PACKAGE_DIR=$(pwd)

# Get details about dependency package
DEPENDENCY_PACKAGE_NAME=`php -r "echo json_decode(file_get_contents('${DEPENDENCY_PACKAGE_DIR}/composer.json'))->name;"`
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

# Copy auth.json
if [ -f ./${DEPENDENCY_PACKAGE_NAME}/auth.json ]; then
    cp ${DEPENDENCY_PACKAGE_NAME}/auth.json .
fi


echo "TMP - copying config file"
mkdir -p config/packages/behat
cp ${DEPENDENCY_PACKAGE_NAME}/vendor/ibexa/ci-scripts/test/*.yaml config/packages/behat/

echo "Done"

# Make sure .env exists - we haven't installed Symfony packages yet
touch .env

if [[ "$PROJECT_VARIANT" != "oss" ]]; then
    composer config repositories.ibexa composer https://updates.ibexa.co
fi

# Install package with Docker Compose files
composer require --no-update --prefer-dist ibexa/docker:^0.1@dev
composer update ibexa/docker --no-scripts
composer recipes:install ibexa/docker
rm composer.lock symfony.lock # remove locks created when installing Docker dependency

echo "> Make composer use tested dependency"
composer config repositories.localDependency path ./${DEPENDENCY_PACKAGE_NAME}


if [ -f ./${DEPENDENCY_PACKAGE_NAME}/dependencies.json ]; then
    cp ${DEPENDENCY_PACKAGE_NAME}/dependencies.json .
    echo "> Adding additional dependencies:"
    cat dependencies.json
    COUNT=$(cat dependencies.json | jq length)
    for ((i=0;i<$COUNT;i++)); do
        REPO_URL=$(cat dependencies.json | jq -r .[$i].repositoryUrl)
        PACKAGE_NAME=$(cat dependencies.json | jq -r .[$i].package)
        REQUIREMENT=$(cat dependencies.json | jq -r .[$i].requirement)
        composer config repositories.$(uuidgen) vcs "$REPO_URL"
        composer require ${PACKAGE_NAME}:"$REQUIREMENT" --no-update
    done
fi

# Install correct product variant
composer require ibexa/${PROJECT_VARIANT}:${PROJECT_VERSION} --no-scripts --no-update

# Install packages required for testing
composer require --no-update --prefer-dist ezsystems/behatbundle:"^8.3.x-dev"

echo "> Install DB and dependencies - use Docker for consistent PHP version"
docker-compose -f doc/docker/install-dependencies.yml up --abort-on-container-exit

# ibexa/docker adds these entries to .env, but we need to make sure they're not overwritten by other recipes
echo '> Set up database connection'
echo 'DATABASE_URL=${DATABASE_PLATFORM}://${DATABASE_USER}:${DATABASE_PASSWORD}@${DATABASE_HOST}:${DATABASE_PORT}/${DATABASE_NAME}?serverVersion=${DATABASE_VERSION}' >> .env

echo "> Start docker containers specified by ${COMPOSE_FILE}"
docker-compose up -d

# for Behat builds to work
echo '> Change ownership of files inside docker container'
docker-compose exec app sh -c 'chown -R www-data:www-data /var/www'

if [[ "$PROJECT_VARIANT" = "commerce" ]]; then
    docker-compose exec --user www-data app sh -c "php /scripts/wait_for_db.php; php bin/console ezplatform:install ezplatform-ee-clean"
    docker-compose exec --user www-data app sh -c "php /scripts/wait_for_db.php; php bin/console ezplatform:install ezcommerce-clean"
elif [[ "$PROJECT_VARIANT" = "experience" ]]; then
    docker-compose exec --user www-data app sh -c "php /scripts/wait_for_db.php; php bin/console ezplatform:install ezplatform-ee-clean"
    docker-compose exec --user www-data app sh -c "php /scripts/wait_for_db.php; php bin/console ezplatform:install ezcommerce-clean"
elif [[ "$PROJECT_VARIANT" = "content" ]]; then
    docker-compose exec --user www-data app sh -c "php /scripts/wait_for_db.php; php bin/console ezplatform:install clean"
    docker-compose exec --user www-data app sh -c "php /scripts/wait_for_db.php; php bin/console ezplatform:install ezcommerce-clean"
else
    docker-compose exec --user www-data app sh -c "php /scripts/wait_for_db.php; php bin/console ezplatform:install clean"
fi

echo '> Generate GraphQL schema'
docker-compose exec --user www-data app sh -c "php bin/console ezplatform:graphql:generate-schema"

echo '> Clear cache & generate assets'
docker-compose exec --user www-data app sh -c "composer run post-install-cmd"

echo '> Done, ready to run tests'
