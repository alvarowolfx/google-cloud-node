#!/bin/bash
# Copyright 2022 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -ex

if [ $# -lt 4 ]
then
  echo "Usage: $0 <source-repo> <target-repo> <source-path> <target-path> [folders,to,skip] [files,to,keep] [branch-name]"
  exit 1
fi

# source GitHub repository. format: <owner>/<repo>
SOURCE_REPO=$1

# destination GitHub repository. format: <owner>/<repo>
TARGET_REPO=$2

# path in the source repo to copy code from. Defaults to the root directory
SOURCE_PATH=$3

# path in the target repo to put the copied code
TARGET_PATH=$4

# comma-separated list of files/folders to skip
IGNORE_FOLDERS=$5
# keep these specific files that would otherwise be deleted by IGNORE_FOLDERS
KEEP_FILES=$6

# override the HEAD branch name for the migration PR
BRANCH=$7

if [[ ! -z "${UPDATE_SCRIPT}" ]]
then
  UPDATE_SCRIPT=$(realpath "${UPDATE_SCRIPT}")
fi

if [[ -z "${BRANCH}" ]]
then
  # default the branch name to be generated from the source repo name
  BRANCH=$(basename ${SOURCE_REPO})-migration
fi

export FILTER_BRANCH_SQUELCH_WARNING=1

# create a working directory
WORKDIR=$(mktemp -d -t code-migration-XXXXXXXXXX)
echo "Created working directory: ${WORKDIR}"

pushd "${WORKDIR}"

echo "Cloning source repository: ${SOURCE_REPO}"
git clone "git@github.com:${SOURCE_REPO}.git" source-repo

pushd source-repo
git remote remove origin

# prune only files within the specified directory
if [[ ! -z "${SOURCE_PATH}" ]]
then
  echo "Pruning commits only including path: ${SOURCE_PATH}"
  git filter-branch \
    --prune-empty \
    --subdirectory-filter "${SOURCE_PATH}"
fi

if [[ ! -z "${IGNORE_FOLDERS}" ]]
then
  echo "Ignoring folder: ${IGNORE_FOLDERS}"
  mkdir -p ${WORKDIR}/filtered-source
  FOLDERS=$(echo ${IGNORE_FOLDERS} | tr "," " ")
  # remove files/folders we don't want
  FILTER="(rm -rf ${FOLDERS} || true)"
  if [[ ! -z "${KEEP_FILES}" ]]
  then
    # restore files to keep, silence errors if the file doesn't exist
    FILTER="${FILTER}; git checkout -- ${KEEP_FILES} 2> /dev/null || true"
  fi
  git filter-branch \
    --force \
    --prune-empty \
    --tree-filter "${FILTER}"
fi

# reorganize the filtered code into the desired target locations
if [[ ! -z "${TARGET_PATH}" ]]
then
  echo "Moving files to destination path: ${TARGET_PATH}"
  git filter-branch \
    --force \
    --prune-empty \
    --tree-filter \
      "shopt -s dotglob; mkdir -p ${WORKDIR}/migrated-source; mv * ${WORKDIR}/migrated-source; mkdir -p ${TARGET_PATH}; mv ${WORKDIR}/migrated-source/* ${TARGET_PATH}"
fi

# back to workdir
popd

# merge histories
echo "Cloning target repository: ${SOURCE_REPO}"
git clone "git@github.com:${TARGET_REPO}.git" target-repo
pushd target-repo

git remote add --fetch migration ../source-repo
git checkout -b "${BRANCH}"
git merge --allow-unrelated-histories migration/main --no-edit

if [[ ! -z "${UPDATE_SCRIPT}" ]]
then
  bash "${UPDATE_SCRIPT}"
fi

git push -u origin "${BRANCH}" --force

# create pull request
if gh --help > /dev/null
then
  gh pr create --title "migrate code from ${SOURCE_REPO}"
else
  hub pull-request -m "migrate code from ${SOURCE_REPO}"
fi

popd
