#!/bin/bash

# This script helps create a zip file for a GiveWP plugin.
# The goal is to replicate the GitHub Actions workflow for generating a zip file as accurately as possible in a local environment.
# This script is not intended for production use or to replace the GitHub Actions workflow.
# Official releases MUST be created using the GitHub Actions workflow.

# How does it work? This script will:
# 1. Clone the git repository into a temp directory
# 2. Install composer packages
# 3. Install npm packages
# 4. Build assets
# 5. Generate the pot file
# 6. Generate the plugin zip dir
# 7. Generate the plugin zip file
# 8. Move the plugin zip file to the current directory
# 9. Delete the temp directory

# Usage: sh givezip.sh <plugin_slug> <ref> [--verbose]

# Suggestion: add an alias for this script in your .bashrc/.zshrc file so you can run it from anywhere:
# alias givezip="sh /path/to/givezip.sh"
# or if you want to run it directly from GitHub:
# alias givezip="curl -s https://raw.githubusercontent.com/impress-org/givewp-github-actions/master/scripts/givezip.sh | sh /dev/stdin"

# Test
if [ $# -lt 2 ]; then
    echo "Usage: sh givezip.sh <plugin_slug> <ref> [--verbose]"
    echo "Example: sh givezip.sh givewp master"
    exit 1
fi

# Input parameters
plugin_slug=$1
ref=$2
verbose=$3

starting_directory=$(pwd)
temp_dir=$(mktemp -d -t givezip)
green='\033[0;32m'
reset='\033[0m'

if [ "$verbose" = "--verbose" ]; then
    OUTPUT="/dev/stdout"
else
    OUTPUT="/dev/null"
fi

# Clone the git repository
echo "${green}-> Cloning the git repository...${reset}"
{
    cd $temp_dir
    git clone -b $ref git@github.com:impress-org/$plugin_slug.git repo
    cd repo
} &> $OUTPUT

# Generate zip name
ZIP_NAME="$plugin_slug.${ref//\//__}"

# Composer installation
echo "${green}-> Installing composer packages...${reset}"
composer install --no-dev &> $OUTPUT

# Node and npm installation
echo "${green}-> Installing npm packages...${reset}"
{
    . ~/.nvm/nvm.sh
    nvm use 16
    npm install
} &> $OUTPUT
echo "${green}-> Building assets...${reset}"
{
    npm run build
} &> $OUTPUT

# Generate pot file
echo "${green}-> Generating pot file...${reset}"
{
    if [ -f "webpack.config.js" ]; then
        php -d xdebug.mode=off "$(which wp)" i18n make-pot $PWD $PWD/languages/$plugin_slug.pot --exclude="$(cat .distignore | tr "\n" "," | sed 's/,$/ /' | tr " " "\n"),*.js.map"
    else
        php -d xdebug.mode=off "$(which wp)" i18n make-pot $PWD $PWD/languages/$plugin_slug.pot --exclude="$(cat .distignore | tr "\n" "," | sed 's/,$/ /' | tr " " "\n"),src/*.js,src/**/*.js,*.js.map,blocks/**/*.js"
    fi
} &> $OUTPUT

# Generate plugin zip dir
echo "${green}-> Generating plugin build dir...${reset}"
{
    if [ "$plugin_slug" == "givewp" ]; then
        ZIP_FOLDER="give"
    else
        ZIP_FOLDER=$plugin_slug
    fi

    mkdir -p ../zip/$ZIP_FOLDER
    rsync -rc --exclude-from="$PWD/.distignore" "$PWD/" ../zip/$ZIP_FOLDER/ --delete --delete-excluded
} &> $OUTPUT

# Generate plugin zip file
echo "${green}-> Generating plugin zip file...${reset}"
{
    cd ../zip
    zip -r $ZIP_NAME.zip $ZIP_FOLDER
    mv $ZIP_NAME.zip $starting_directory/$ZIP_NAME.zip
    rm -rf $temp_dir
} &> $OUTPUT

echo "${green}-- Plugin package generated successfully! --${reset}"

cd "$starting_directory"
