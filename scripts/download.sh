#!/bin/bash

source scripts/utils.sh echo -n

# Saner programming env: these switches turn some bugs into errors
set -o errexit -o pipefail

# This script is meant to be used with the command 'datalad run'

_DATASETS_URL=https://robotcar-dataset.robots.ox.ac.uk/datasets

function get_files_url {
	local _dataset="${1}"
	for url_md5 in $(wget -qO - "${_DATASETS_URL}/${_dataset}" | \
		grep -Eo "https?://[^\"]*/${_dataset}/${_dataset}[^\"]*|<td>[0-9A-Za-z]{32}")
	do
		if [[ "${url_md5}" == "<td>"* ]]
		then
			echo "${url_md5:4}  ${_filename}" | tr '[:upper:]' '[:lower:]' >> md5sums
		else
			local _filename=${_dataset}/${url_md5#*/${_dataset}/}
			echo "${url_md5} ${_filename}"
		fi
	done
}

function download_file {
	local _file=$1
	local _retry=${2:-5}

	git-annex get --fast \
		-c annex.security.allowed-ip-addresses=all \
		-c annex.web-options="${CURL_OPTIONS} --cookie .tmp/cookie_jar" \
		${_file}

	if [[ ! "$(md5sum "${_file}")" == "$(grep "${_file}" md5sums)" ]]
	then
		# Session expired
		if [[ ! -z "$(grep "Login" "${_file}")" ]]
		then
			curl 'https://mrgdatashare.robots.ox.ac.uk/accounts/login/' -X POST \
				-H 'Referer:https://mrgdatashare.robots.ox.ac.uk/accounts/login/' \
				-H "Cookie:${REFRESH_SESSION_COOKIE}" \
				--data-raw "${REFRESH_SESSION_DATA}" --cookie-jar .tmp/cookie_jar
		# Due to resource limitations we can only serve a certain
		# number of files per user. Please wait until your existing
		# files have downloaded before requesting any more. Thanks
		elif [[ ! -z "$(grep "Sorry" "${_file}")" ]]
		then
			sleep 60
		else
			false || exit_on_error_code "Downloaded ${_file} resulted in an unexpected content"
		fi

		local _retry=$((_retry - 1))
		if (($_retry > 0))
		then
			git-annex drop --force --fast "${_file}"
			download_file "${_file}" ${_retry}
		else
			false || exit_on_error_code "All attempts to download ${_file} failed"
		fi
	fi
}

test_enhanced_getopt

PARSED=$(enhanced_getopt --options "h" --longoptions "curl-options:,refresh-token-data:,help" --name "$0" -- "$@")
eval set -- "${PARSED}"

REFRESH_SESSION_COOKIE=$(git config --file scripts/robotcar_config --get robotcar.refresh-session-cookie || echo "")
REFRESH_SESSION_DATA=$(git config --file scripts/robotcar_config --get robotcar.refresh-session-data || echo "")

while [[ $# -gt 0 ]]
do
	arg="$1"; shift
	case "${arg}" in
		--curl-options) CURL_OPTIONS="$1"; shift
		echo "curl-options = [${CURL_OPTIONS}]"
		;;
                --refresh-session-cookie) REFRESH_SESSION_COOKIE="$1"; shift
                echo "refresh-session-cookie = [${REFRESH_SESSION_COOKIE}]"
                ;;
                --refresh-session-data) REFRESH_SESSION_DATA="$1"; shift
                echo "refresh-session-data = [${REFRESH_SESSION_DATA}]"
                ;;
		-h | --help)
		>&2 echo "Options for $(basename "$0") are:"
		>&2 echo "--curl-options OPTIONS"
		>&2 echo "--refresh-session-cookie COOKIE"
		>&2 echo "--refresh-session-data DATA"
		exit 1
		;;
		--) break ;;
		*) >&2 echo "Unknown argument [${arg}]"; exit 3 ;;
	esac
done

mkdir -p .tmp

wget -O datasets.csv "https://raw.githubusercontent.com/mttgdd/RobotCarDataset-Scraper/7685eeba7a0f1ed5669e29832575c576f57b1700/datasets.csv"

_datasets=($(grep -oE "[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{2}-[0-9]{2}-[0-9]{2}" datasets.csv))

rm -f md5sums

# These urls require login cookies to download the file
git-annex addurl --fast --relaxed -c annex.largefiles=anything --raw --batch --with-files <<EOF
$(for dataset in "${_datasets[@]}" ; do get_files_url "${dataset}" ; done)
EOF
for f in $(list -- --fast)
do
	download_file ${f}
done
git-annex migrate --fast -c annex.largefiles=anything *

md5sum -c md5sums > .tmp/md5sums_checks
