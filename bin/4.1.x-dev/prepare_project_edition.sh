#!/bin/bash
set -e

PROJECT_EDITION=$1
PROJECT_VERSION=$2
export COMPOSE_FILE=$3
export PHP_IMAGE=${4-ezsystems/php:7.4-v2-node16}

echo "> Setting up website skeleton"
PROJECT_BUILD_DIR=${HOME}/build/project
composer create-project ibexa/website-skeleton:~4.1.0@dev ${PROJECT_BUILD_DIR} --no-install --no-scripts 

if [[ -n "${DOCKER_PASSWORD}" ]]; then
    echo "> Set up Docker credentials"
    echo ${DOCKER_PASSWORD} | docker login -u ${DOCKER_USERNAME} --password-stdin
fi

export COMPOSER_MAX_PARALLEL_HTTP=6

# Create container to install dependencies
docker run --name install_dependencies -d \
--volume=${PROJECT_BUILD_DIR}:/var/www:cached \
--volume=${HOME}/.composer:/root/.composer \
-e APP_ENV -e APP_DEBUG  \
-e COMPOSER_MAX_PARALLEL_HTTP \
-e PHP_INI_ENV_memory_limit -e COMPOSER_MEMORY_LIMIT \
-e COMPOSER_NO_INTERACTION=1 \
${PHP_IMAGE}

# Get details about dependency package
DEPENDENCY_PACKAGE_DIR=$(pwd)
DEPENDENCY_PACKAGE_NAME=$(jq -r '.["name"]' "${DEPENDENCY_PACKAGE_DIR}/composer.json")
DEPENDENCY_PACKAGE_VERSION=$(jq -r '.["extra"]["branch-alias"] | flatten | .[0]' "${DEPENDENCY_PACKAGE_DIR}/composer.json")
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

# Remove installed dependencies inside the package
rm -rf ${PROJECT_BUILD_DIR}/${DEPENDENCY_PACKAGE_NAME}/vendor

# Go to main project dir
cd ${PROJECT_BUILD_DIR}

# Copy auth.json if needed
if [ -f ./${DEPENDENCY_PACKAGE_NAME}/auth.json ]; then
    cp ${DEPENDENCY_PACKAGE_NAME}/auth.json .
fi

if [[ "$PROJECT_EDITION" != "oss" ]]; then
    composer config repositories.ibexa composer https://updates.ibexa.co
fi

echo "> Make composer use tested dependency"
JSON_STRING=$( jq -n \
                  --arg packageVersion "$DEPENDENCY_PACKAGE_VERSION" \
                  --arg packageName "$DEPENDENCY_PACKAGE_NAME" \
                  --arg packageDir "./$DEPENDENCY_PACKAGE_NAME" \
                  '{"type": "path", "url": $packageDir, "options": { "symlink": false , "versions": { ($packageName): $packageVersion}}}' )

composer config repositories.localDependency "$JSON_STRING"

# Install correct product variant
docker exec install_dependencies composer update
docker exec -e APP_ENV=dev install_dependencies composer require ibexa/${PROJECT_EDITION}:${PROJECT_VERSION} -W --no-scripts

# Install ibexa/behat
docker exec install_dependencies composer require ibexa/behat:^4.0.x-dev --no-scripts

# Init a repository to avoid Composer asking questions
git init; git add . > /dev/null;

# Execute Ibexa recipes
docker exec install_dependencies composer recipes:install ibexa/${PROJECT_EDITION} --force --reset

# Install Docker stack
docker exec install_dependencies composer require ibexa/docker:^0.2.x-dev --no-scripts

# Add other dependencies if required
if [ -f ./${DEPENDENCY_PACKAGE_NAME}/dependencies.json ]; then
    cp ${DEPENDENCY_PACKAGE_NAME}/dependencies.json .
    echo "> Adding additional dependencies:"
    cat dependencies.json
    COUNT=$(cat dependencies.json | jq length)
    for ((i=0;i<$COUNT;i++)); do
        REPO_URL=$(cat dependencies.json | jq -r .[$i].repositoryUrl)
        PACKAGE_NAME=$(cat dependencies.json | jq -r .[$i].package)
        REQUIREMENT=$(cat dependencies.json | jq -r .[$i].requirement)
        SHOULD_BE_ADDED_AS_VCS=$(cat dependencies.json | jq -r .[$i].shouldBeAddedAsVCS)
        if [[ $SHOULD_BE_ADDED_AS_VCS == "true" ]] ; then 
            echo ">> Private or fork repository detected, adding VCS to Composer repositories"
            docker exec install_dependencies composer config repositories.$(uuidgen) vcs "$REPO_URL"
        fi
        jq --arg package "$PACKAGE_NAME" --arg requirement "$REQUIREMENT" '.["require"] += { ($package) : ($requirement) }' composer.json > composer.json.new
        mv composer.json.new composer.json
    done

    docker exec install_dependencies composer update --no-scripts

    # Execute recipes from behat and docker again, because they use copy-from-package
    docker exec install_dependencies composer sync-recipes ibexa/docker --force --reset
    docker exec install_dependencies composer sync-recipes ibexa/behat --force --reset
fi

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

# Workaround: create cache directory for JSRoutingBundle, see https://github.com/FriendsOfSymfony/FOSJsRoutingBundle/pull/434
docker-compose --env-file=.env exec -T --user www-data app sh -c "mkdir var/cache/$APP_ENV/fosJsRouting"

echo '> Install data'
docker-compose --env-file=.env exec -T --user www-data app sh -c "php /scripts/wait_for_db.php; php bin/console ibexa:install"

echo '> Generate GraphQL schema'
docker-compose --env-file=.env exec -T --user www-data app sh -c "php bin/console ibexa:graphql:generate-schema"



echo '> Done, ready to run tests'
