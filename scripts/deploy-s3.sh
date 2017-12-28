#!/bin/bash
#
# Deploying Mayflower to Amazon S3
# -----------------------------------------------------
#
# Run from the repo root, must have a clean working directory.
#
# Usage:
# ./scripts/deploy-s3.sh [-b (git-branch-or-tag)] [-m] [-p]
#   -b Build source: the git branch or tag to build from (required)
#   -m Indicates a deploy to the latest minor version (optional)
#   -p Indicates a deploy to production (optional)
#
# Description:
# 1. Validate the passed arguments: build source and target repo
# 2. Attempt to checkout passed build source
# 3. Get to mayflower/styleguide directory
# 4. Write config to support hosting from subdirectory, if necessary
# 5. Build pattern lab static assets
# 6. Copy static assets (build output: styleguide/public/) into a new temp directory
# 7. Execute gulp command to deploy to s3
# 8. Remove the temp directory
# 9. Check out the previous branch

# @todo
# - build into ci process

# Steps to clean up after script execution
# Runs on success and failure.
function cleanup {
    # 8. Remove temp directory
    line="Cleaning up tmp dir..."
    log "log" "$line";

    rm -rf ~/tmp/mayflower

    # 9. Check out the previous branch
    line="Checking out your previous branch..."
    log "log" "$line";

    git checkout @{-1}
}

# Output success or error log during execution
function log {
    # parameters
    local theLogType=$1
    local theMessage=$2

    if [ "$theLogType" == "success" ]; then
        echo -e "\n\x1B[01;92m [success] "${theMessage}"\x1B[0m \n"
    elif [ "$theLogType" == "error" ]; then
        echo -e "\n\x1B[01;91m [error] "${theMessage}"\x1B[0m \n" >&2
    else
        echo -e "\n\x1B[01;34m [info] "${theMessage}"\x1B[0m \n"
    fi
}

# Default arguments
prod=false
minor=false
buildSrc=false

# Local variables
assetsPath=''
subDir=''
majorVersion=''

# Get passed arguments
while getopts :b:mp option
do
    case "${option}" in
        b) buildSrc=${OPTARG};;
        m) minor=true;;
        p) prod=true;;
        : ) line="Missing argument for parameter [-${OPTARG}]";
              log "error" "$line";
              exit 1;;
        \? ) line="Whoops, this script only accepts arguments for: git build branch/tag [-b] and if it is a production release [-p]";
             log "error" "$line";
             exit 1;;
    esac
done

# 1. Validate build source environment argument exists
if [ "$buildSrc" = false ];
then
    line="Whoops, we need a git branch or tag name to checkout and build from [-b]."
    log "error" "$line";
    exit 1;
fi

# Validate that passed build source is a valid git branch or tag
git rev-parse ${buildSrc} &>/dev/null
if [ "$?" -ne 0 ];
then
    line="Hmmm, couldn't find a branch/tag named ${buildSrc}... check spelling and make sure you've pulled it."
    log "error" "$line";
    exit 1;
else
    line="Validated git build source: ${buildSrc}..."
    log "success" "$line";
fi

# Confirm a deploy to prod if -p passed.
if [ "$prod" = true ];
then
    read -p "You've indicated a deploy to production (by passing [-p]), are you sure? [y/n] " -n 1 -r
    echo    # move to a new line
    if [[ ! $REPLY =~ ^[Yy]$ ]];
    then
        line="Aborting deploy.  Execute the script again without passing [-p]."
        log "error" "$line";
        exit 1;
    fi
fi

# 2. Checkout the build source
line="Checking out the build source: ${buildSrc}"
log "log" "$line";

if ! git checkout ${buildSrc};
then
    line="Could not check out $buildSrc, make sure your working directory is clean."
    log "error" "$line";
    exit 1;
fi

# 3. Get to styleguide directory
# Get to styleguide directory (inside of repo root), does not assume repo root is "mayflower"
line="Changing directory into mayflower/styleguide..."
log "log" "$line";

cd $(git rev-parse --show-toplevel)/styleguide

# 4. Set the domain and asset path config
# When there is a cname: url.domain = cname, url.assetsPath = assets
# When there is no cname: url.domain = <githug-username>.github.io, url.assetsPath = mayflower/assets
line="Setting the domain and asset path config..."
log "log" "$line";

# If we're deploying something that doesn't have the url.json.example file, create it first
if [ ! -f ./source/_data/url.json.example ];
    then
        urljson='{\n\t"url": {\n\t\t"comment": "Save this file as url.json and enter your domain and the path to the assets folder",\n\t\t"domain": "http://localhost:3000",\n\t\t"assetsPath": "assets"\n\t}\n}'
        echo -e ${urljson} > ./source/_data/url.json.example

        # Set flag to undo these changes in the working directory before leaving script.
        cleanup=true
fi

# Create url.json from the .example and set the appropriate domain and assetsPath values
cp ./source/_data/url.json.example ./source/_data/url.json

# Determine the value of url.domain, url.assetsPath based arguments passed
domain="https://s3.amazonaws.com/mayflower.digital.mass.gov"

if [ "$minor" = true ];
then
    IFS='.' read -ra VERSION <<< "$buildSrc";
    majorVersion=${VERSION[0]}
    subDir="$majorVersion"
else
    subDir="$buildSrc"
fi
assetsPath="$subDir/assets"

# Set url.domain and url.assetsPath
find ./source/_data -type f -name "url.json" -exec sed -i "" "s!http://localhost:3000!${domain}!g" {} \;
find ./source/_data -type f -name "url.json" -exec sed -i "" "s!assets\"!${assetsPath}\"!g" {} \;

# 5. Build pattern to generate prod static assets
line="Generating mayflower patterns..."
log "log" "$line";
php core/console --generate >/dev/null

line="Building mayflower static assets..."
log "log" "$line";
gulp prod >/dev/null

# Remove url.json to keep repo clean
rm source/_data/url.json

# 6. Copy built assets in /public into new tmp directory

# Make temp directory to copy public assets
line="Making ~/tmp/mayflower/$subDir directory..."
log "log" "$line";
dir="~/tmp/mayflower/$subDir"
if [ -d "~/tmp" ];
then
    mkdir ~/tmp/mayflower
    mkdir ${dir}
else
    mkdir ~/tmp
    mkdir ~/tmp/mayflower
    mkdir ${dir}
fi

# Copy
line="Copying Pattern Lab build output to ~/tmp/mayflower/$subDir directory..."
log "log" "$line";
cp -r public/. ${dir} >/dev/null

# 7. Run gulp task to deploy to s3 bucket
#line="Uploading contents of ~/tmp/mayflower/$dir to Mayflower s3 bucket..."
#log "log" "$line";
#if ! gulp s3; then
#    line="gulp s3 task failed"
#    log "error" "$line";
#    exit 1;
#fi

# 8. Clean up tmp directory and get back to where we want to be.
#cleanup
