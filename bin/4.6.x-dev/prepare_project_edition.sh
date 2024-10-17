#!/bin/bash
set -e

PROJECT_EDITION=$1
PROJECT_VERSION=$2
PROJECT_BUILD_DIR=${HOME}/build/project
export COMPOSE_FILE=$3
export PHP_IMAGE=${4-ghcr.io/ibexa/docker/php:8.3-node18}
export COMPOSER_MAX_PARALLEL_HTTP=6 # Reduce Composer parallelism to work around Github Actions network errors

if [[ -n "${DOCKER_PASSWORD}" ]]; then
    echo "> Set up Docker credentials"
    echo ${DOCKER_PASSWORD} | docker login -u ${DOCKER_USERNAME} --password-stdin
fi

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

# Go to main project dir
mkdir -p $PROJECT_BUILD_DIR && cd $PROJECT_BUILD_DIR

# Create container to install dependencies
RANDOM_SUFFIX=$(echo $RANDOM | base64 | head -c 6; echo)
docker run --name install_dependencies_${RANDOM_SUFFIX} -d \
--volume=${PROJECT_BUILD_DIR}:/var/www:cached \
--volume=${HOME}/.composer:/root/.composer \
-e APP_ENV -e APP_DEBUG  \
-e COMPOSER_MAX_PARALLEL_HTTP \
-e PHP_INI_ENV_memory_limit -e COMPOSER_MEMORY_LIMIT \
-e COMPOSER_NO_INTERACTION=1 \
${PHP_IMAGE}

echo "> Setting up website skeleton"
composer create-project ibexa/website-skeleton:$PROJECT_VERSION . --no-install --ansi

# Add other dependencies if required
if [ -f ${DEPENDENCY_PACKAGE_DIR}/dependencies.json ]; then
    cp ${DEPENDENCY_PACKAGE_DIR}/dependencies.json .
    echo "> Additional dependencies will be added"
    cat dependencies.json
    RECIPES_ENDPOINT=$(cat dependencies.json | jq -r '.recipesEndpoint')
    if [[ $RECIPES_ENDPOINT != "" ]] ; then
        echo "> Switching Symfony Flex endpoint to $RECIPES_ENDPOINT"
        composer config extra.symfony.endpoint $RECIPES_ENDPOINT
    fi
fi

docker exec install_dependencies_${RANDOM_SUFFIX} composer update --ansi

# Move dependency to directory available for docker volume
echo "> Move ${DEPENDENCY_PACKAGE_DIR} to ${PROJECT_BUILD_DIR}/${DEPENDENCY_PACKAGE_NAME}"
mkdir -p ${PROJECT_BUILD_DIR}/${DEPENDENCY_PACKAGE_NAME}
mv ${DEPENDENCY_PACKAGE_DIR}/* ${PROJECT_BUILD_DIR}/${DEPENDENCY_PACKAGE_NAME}/

# Remove installed dependencies inside the package
rm -rf ${PROJECT_BUILD_DIR}/${DEPENDENCY_PACKAGE_NAME}/vendor

# Copy auth.json if needed
if [ -f ./${DEPENDENCY_PACKAGE_NAME}/auth.json ]; then
    cp ${DEPENDENCY_PACKAGE_NAME}/auth.json .
fi

if [[ "$PROJECT_EDITION" != "oss" ]]; then
    composer config repositories.ibexa composer https://updates.ibexa.co

    editions=(commerce experience headless)

    IBEXA_PACKAGES="[]"
    for EDITION in "${editions[@]}"; do
        if [[ "$PROJECT_EDITION" == "$EDITION" ]]; then
            break
        fi
        COMPOSER_JSON_CONTENT=$(curl -s "https://raw.githubusercontent.com/ibexa/$EDITION/master/composer.json")
        EDITION_PACKAGES=$(echo "$COMPOSER_JSON_CONTENT" | \
            jq -r --arg projectEdition "ibexa/$PROJECT_EDITION" \
            '.require | with_entries(select(.key | contains("ibexa/"))) | with_entries(select(.key == $projectEdition | not )) | keys')
        IBEXA_PACKAGES=$(echo "$IBEXA_PACKAGES" | jq --argjson editionPackages "$EDITION_PACKAGES" '. + $editionPackages')

    done

    jq --argjson ibexaPackages "$IBEXA_PACKAGES" '.repositories.ibexa.exclude = $ibexaPackages' composer.json > composer.json.new
    mv composer.json.new composer.json
fi

echo "> Make composer use tested dependency"
JSON_STRING=$( jq -n \
                  --arg packageVersion "$DEPENDENCY_PACKAGE_VERSION" \
                  --arg packageName "$DEPENDENCY_PACKAGE_NAME" \
                  --arg packageDir "./$DEPENDENCY_PACKAGE_NAME" \
                  '{"type": "path", "url": $packageDir, "options": { "symlink": false , "versions": { ($packageName): $packageVersion}}}' )

composer config repositories.localDependency "$JSON_STRING"
composer require "$DEPENDENCY_PACKAGE_NAME:$DEPENDENCY_PACKAGE_VERSION" --no-update

# Install correct product variant
docker exec install_dependencies_${RANDOM_SUFFIX} composer require ibexa/${PROJECT_EDITION}:${PROJECT_VERSION} -W --no-scripts --ansi

# Init a repository to avoid Composer asking questions
docker exec install_dependencies_${RANDOM_SUFFIX} git config --global --add safe.directory /var/www && git init && git add .

# Execute recipes
docker exec install_dependencies_${RANDOM_SUFFIX} composer recipes:install ibexa/${PROJECT_EDITION} --force --reset --ansi
docker exec install_dependencies_${RANDOM_SUFFIX} composer recipes:install ${DEPENDENCY_PACKAGE_NAME} --force --reset --ansi

# Install Behat and Docker packages
docker exec install_dependencies_${RANDOM_SUFFIX} composer require ibexa/behat:$PROJECT_VERSION ibexa/docker:$PROJECT_VERSION --no-scripts --ansi --no-update

# Install opt-in packages
if [[ "$PROJECT_EDITION" != "oss" ]] && [[ $PHP_IMAGE == *"8.3"* ]]; then
  # openai-php/client requires PHP 8.1+, v4.6 test matrix has PHP 7.4, 8.0, 8.3
  # ibexa/connector-qualifio is already being installed with the project
  docker exec install_dependencies_${RANDOM_SUFFIX} composer require ibexa/connector-ai:$PROJECT_VERSION ibexa/connector-openai:$PROJECT_VERSION --no-scripts --ansi --no-update
fi

# Add other dependencies if required
if [ -f dependencies.json ]; then
    COUNT=$(cat dependencies.json | jq '.packages | length' )
    for ((i=0;i<$COUNT;i++)); do
        REPO_URL=$(cat dependencies.json | jq -r .packages[$i].repositoryUrl)
        PACKAGE_NAME=$(cat dependencies.json | jq -r .packages[$i].package)
        REQUIREMENT=$(cat dependencies.json | jq -r .packages[$i].requirement)
        SHOULD_BE_ADDED_AS_VCS=$(cat dependencies.json | jq -r .packages[$i].shouldBeAddedAsVCS)
        if [[ $SHOULD_BE_ADDED_AS_VCS == "true" ]] ; then 
            echo ">> Private or fork repository detected, adding VCS to Composer repositories"
            docker exec install_dependencies_${RANDOM_SUFFIX} composer config repositories.$(uuidgen) vcs "$REPO_URL"
        fi
        jq --arg package "$PACKAGE_NAME" --arg requirement "$REQUIREMENT" '.["require"] += { ($package) : ($requirement) }' composer.json > composer.json.new
        mv composer.json.new composer.json
    done
fi

docker exec install_dependencies_${RANDOM_SUFFIX} composer update --no-scripts

# Enable FriendsOfBehat SymfonyExtension in the Behat env
sudo sed -i "s/\['test' => true\]/\['test' => true, 'behat' => true\]/g" config/bundles.php

if [[ $PHP_IMAGE == *"8.2"* ]] || [[ $PHP_IMAGE == *"8.3"* ]]; then
    echo "> Set PHP 8.2+ Ibexa error handler to avoid deprecations"
    docker exec install_dependencies_${RANDOM_SUFFIX} composer config extra.runtime.error_handler "\\Ibexa\\Contracts\\Core\\MVC\\Symfony\\ErrorHandler\\Php82HideDeprecationsErrorHandler"
    docker exec install_dependencies_${RANDOM_SUFFIX} composer dump-autoload
fi

echo "> Display composer.json for debugging"
cat composer.json

# Create a default Behat configuration file
cp "behat_ibexa_${PROJECT_EDITION}.yaml" behat.yaml

# Depenencies are installed and container can be removed
docker container stop install_dependencies_${RANDOM_SUFFIX}
docker container rm install_dependencies_${RANDOM_SUFFIX}

# Set up Percy visual testing base branch
IFS='.' read -ra VERSION_NUMBERS <<< "$PROJECT_VERSION"
VERSION="${VERSION_NUMBERS[0]}.${VERSION_NUMBERS[1]}/$PROJECT_EDITION"
export PERCY_BRANCH=$VERSION

echo "> Start docker containers specified by ${COMPOSE_FILE}"
docker compose --env-file=.env up -d

# for Behat builds to work
echo '> Change ownership of files inside docker container'
docker compose --env-file=.env exec -T app sh -c 'chown -R www-data:www-data /var/www'

# Rebuild container
docker compose --env-file=.env exec -T --user www-data app sh -c "rm -rf var/cache/*"
echo '> Clear cache & generate assets'
docker compose --env-file=.env exec -T --user www-data app sh -c "composer run post-install-cmd --ansi"

echo '> Install data'
if [[ "$COMPOSE_FILE" == *"elastic.yml"* ]]; then
    docker compose --env-file=.env exec -T --user www-data app sh -c "php bin/console ibexa:elasticsearch:put-index-template"
fi
docker compose --env-file=.env exec -T --user www-data app sh -c "php /scripts/wait_for_db.php; php bin/console ibexa:install --skip-indexing"
docker compose --env-file=.env exec -T --user www-data app sh -c "php bin/console ibexa:reindex"

echo '> Generate GraphQL schema'
docker compose --env-file=.env exec -T --user www-data app sh -c "php bin/console ibexa:graphql:generate-schema"

echo '> Done, ready to run tests'
