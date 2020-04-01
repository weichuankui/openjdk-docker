#!/usr/bin/env bash
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
set -o pipefail

export root_dir="$PWD"
push_cmdfile=${root_dir}/push_commands.sh
target_repo="adoptopenjdk/openjdk"
version="9"

# shellcheck source=common_functions.sh
source ./common_functions.sh
# shellcheck source=dockerfile_functions.sh
source ./dockerfile_functions.sh

if [ $# -ne 3 ]; then
	echo
	echo "usage: $0 version vm package"
	echo "version = ${supported_versions}"
	echo "vm      = ${all_jvms}"
	echo "package = ${all_packages}"
	exit 1
fi

set_version "$1"
vm="$2"
package="$3"

# Get the image build time stored in the respective build_time array passed as arg
function get_image_build_time() {
	if ! declare -p "$1" &>/dev/null; then
		return;
	fi

	local btime=$(btarray=$1[${current_arch}]; eval btarch=\${"$btarray"}; echo "${btarch}");

	echo "${btime}"
}

# Check if we need to do a docker build
# Build is needed only if one of the following criteria is met
# 1. If no such docker image exists currently
# 2. If the base OS docker image was recently re-built
# 3. If a new Adopt build is found
# 4. On any other error condition
function check_build_needed() {
	local tag=$2

	# Pull the latest adopt image if it is available.
	adopt_image_tag="${tag// -t /}"
	echo "INFO: Checking when the adopt docker image ${adopt_image_tag} was built ..."
	if ! docker pull -q "${adopt_image_tag}" &>/dev/null; then
		# Adopt image not available currently, build needed
		echo "INFO: AdoptOpenJDK docker image for ${adopt_image_tag} does not exist. Docker build needed"
		build_needed=1
		return;
	fi

	# Get the date when the base image was created. Eg if the base OS is ubuntu, this
	# translates as the exact date/time when the Ubuntu image was created on DockerHub
	from_image="$(grep "FROM" "$1" | awk '{ print $2 }')"
	# Pull the latest image locally
	echo "INFO: Checking when the base docker image ${from_image} was built ..."
	if ! docker pull -q "${from_image}" &>/dev/null; then
		echo "INFO: Failed to pull base docker image. Docker build needed"
		build_needed=1
		return;
	fi

	adopt_last_build_date=$(get_image_build_time ${build_time})
	if [ -z "${adopt_last_build_date}" ]; then
		echo "INFO: Unknown last tarball build time. Docker build needed"
		build_needed=1
		return;
	fi
	# Add "one day" to it, this is to ensure that we rebuild our image if the last build date was in the past 24 hours
	adopt_last_build_date=$(( adopt_last_build_date + 86400 ))

	# check when the adopt image was last built
	adopt_image_creation="$(docker inspect "${adopt_image_tag}" | python -c "import sys, json; print(json.load(sys.stdin)[0]['Created'])")"
	# Convert this to seconds since 1-1-1970
	adopt_image_creation_date="$(date --date="${adopt_image_creation}" +%s)"

	if [[ ${adopt_image_creation_date} -lt ${adopt_last_build_date} ]]; then
		# build needed
		echo "INFO: Newer adopt build found. Docker build needed"
		build_needed=1
		return;
	fi
	
	# Check the time when the base OS image was created
	base_image_creation="$(docker inspect "${from_image}" | python -c "import sys, json; print(json.load(sys.stdin)[0]['Created'])")"
	# Convert the time to seconds since 1-1-1970
	base_image_creation_date="$(date --date="${base_image_creation}" +%s)"
	# Add "one day" to it, this is to ensure that we rebuild our image if the base image was created in the past 24 hours
	base_image_creation_date=$(( base_image_creation_date + 86400 ))

	if [[ ${adopt_image_creation_date} -lt ${base_image_creation_date} ]]; then
		# build needed
		echo "INFO: Newer base OS docker image found. Docker build needed"
		build_needed=1
		return;
	fi

	# build not needed
	echo "INFO: Current build for ${adopt_image_tag} exists and is latest. Docker build NOT needed"
	build_needed=0
}
 
# Build the Docker image with the given repo, build, build type and tags.
function build_image() {
	repo=$1; shift;
	build=$1; shift;
	btype=$1; shift;

	tags=""
	for tag in "$@"
	do
		tags="${tags} -t ${repo}:${tag}"
	done

	dockerfile="Dockerfile.${vm}.${build}.${btype}"
	# Check if we need to build this image.
	# Nightlies are always built.
	if [ "${build}" != "nightly" ]; then
		check_build_needed "${dockerfile}" "${tags}"
		if [[ ${build_needed} -eq 0 ]]; then
			# No build needed, we are done
			return;
		fi
	fi

	echo "docker push ${repo}:${tag}" >> "${push_cmdfile}"
	echo "#####################################################"
	echo "INFO: docker build --no-cache ${tags} -f ${dockerfile} ."
	echo "#####################################################"
	# shellcheck disable=SC2086 # ignoring ${tags} due to whitespace problem
	if ! docker build --pull --no-cache ${tags} -f "${dockerfile}" . ; then
		echo "#############################################"
		echo
		echo "ERROR: Docker build of image: ${tags} from ${dockerfile} failed."
		echo
		echo "#############################################"
	fi
}

# Build the docker image for a given VM, OS, BUILD and BUILD_TYPE combination.
function build_dockerfile {
	vm=$1; pkg=$2; os=$3; build=$4; btype=$5;

	jverinfo="${shasums}[version]"
	# shellcheck disable=SC1083,SC2086
	eval jrel=\${$jverinfo}
	# Docker image tags cannot have "+" in them, replace it with "_" instead.
	# shellcheck disable=SC2154
	rel=${jrel//+/_}
	if [ "${pkg}" == "jre" ]; then
		rel=${rel//jdk/jre}
	fi

	# The target repo is different for different VMs
	if [ "${vm}" == "hotspot" ]; then
		trepo=${target_repo}${version}
	else
		trepo=${target_repo}${version}-${vm}
	fi
	# Get the default tag first
	nanoserver_pat=".*nanoserver.*"
	if [[ "$file" =~ $nanoserver_pat ]]; then
		tag=${current_arch}-${os}-nanoserver-${rel}
	else
		tag=${current_arch}-${os}-${rel}
	fi
	# Append nightly for nightly builds
	if [ "${build}" == "nightly" ]; then
		tag=${tag}-nightly
	fi
	# Append slim for slim builds
	if [ "${btype}" == "slim" ]; then
		tag=${tag}-slim
		# Copy the script to generate slim builds.
		cp slim-java* config/slim-java* "${dir}"/
	fi
	echo "INFO: Building ${trepo} ${tag} from $file ..."
	pushd "${dir}" >/dev/null || return
	build_image "${trepo}" "${build}" "${btype}" "${tag}"
	popd >/dev/null || return
}

# Set the OSes that will be built on based on the current arch
set_arch_os

# Script that has the push commands for the images that we are building.
echo "#!/usr/bin/env bash" > "${push_cmdfile}"
echo >> "${push_cmdfile}"

# Valid image tags
#adoptopenjdk/openjdk${version}:${arch}-${os}-${rel}
#adoptopenjdk/openjdk${version}:${arch}-${os}-${rel}-slim
#adoptopenjdk/openjdk${version}:${arch}-${os}-${rel}-nightly
#adoptopenjdk/openjdk${version}:${arch}-${os}-${rel}-nightly-slim
#adoptopenjdk/openjdk${version}-openj9:${arch}-${os}-${rel}
#adoptopenjdk/openjdk${version}-openj9:${arch}-${os}-${rel}-slim
#adoptopenjdk/openjdk${version}-openj9:${arch}-${os}-${rel}-nightly
#adoptopenjdk/openjdk${version}-openj9:${arch}-${os}-${rel}-nightly-slim
for os in ${oses}
do
	# Build = Release or Nightly
	builds=$(parse_vm_entry "${vm}" "${version}" "${package}" "${os}" "Build:")
	# Type = Full or Slim
	btypes=$(parse_vm_entry "${vm}" "${version}" "${package}" "${os}" "Type:")
	dir=$(parse_vm_entry "${vm}" "${version}" "${package}" "${os}" "Directory:")

	for build in ${builds}
	do
		echo "Getting latest shasum info for [ ${version} ${vm} ${package} ${build} ]"
		get_shasums "${version}" "${vm}" "${package}" "${build}"
		# Source the generated shasums file to access the array
		if [ -f "${vm}"_shasums_latest.sh ]; then
		  # shellcheck disable=SC1090
			source ./"${vm}"_shasums_latest.sh
			source ./"${vm}"_build_time_latest.sh
		else
			continue;
		fi
		# Check if the VM is supported for the current arch
		shasums="${package}"_"${vm}"_"${version}"_"${build}"_sums
		build_time="${package}"_"${vm}"_"${version}"_"${build}"_build_time
		sup=$(vm_supported_onarch "${vm}" "${shasums}")
		if [ -z "${sup}" ]; then
			continue;
		fi
		# Generate all the Dockerfiles for each of the builds and build types
		for btype in ${btypes}
		do
			file="${dir}/Dockerfile.${vm}.${build}.${btype}"
			generate_dockerfile "${file}" "${package}" "${build}" "${btype}" "${os}"
			if [ ! -f "${file}" ]; then
				continue;
			fi
			# Build the docker images for valid Dockerfiles
			build_dockerfile "${vm}" "${package}" "${os}" "${build}" "${btype}"
		done
	done
done
chmod +x "${push_cmdfile}"

echo
echo "INFO: The push commands are available in file ${push_cmdfile}"
