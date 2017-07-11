#!/bin/bash -x
set -eu

copr_project_name=nftables
rpm_name=nftables
arch=x86_64

copr_project_description="
"

copr_project_instructions="\`\`\`
ver=\$(rpm -q --qf "%{VERSION}" \$(rpm -q --whatprovides redhat-release))
\`\`\`

\`\`\`
sudo curl -sL -o /etc/yum.repos.d/${COPR_USERNAME}-libmnl.repo https://copr.fedoraproject.org/coprs/${COPR_USERNAME}/libmnl/repo/epel-\${ver}/${COPR_USERNAME}-libmnl-epel-\${ver}.repo
\`\`\`

\`\`\`
sudo curl -sL -o /etc/yum.repos.d/${COPR_USERNAME}-libnftnl.repo https://copr.fedoraproject.org/coprs/${COPR_USERNAME}/libnftnl/repo/epel-\${ver}/${COPR_USERNAME}-libnftnl-epel-\${ver}.repo
\`\`\`

\`\`\`
sudo curl -sL -o /etc/yum.repos.d/${COPR_USERNAME}-${copr_project_name}.repo https://copr.fedoraproject.org/coprs/${COPR_USERNAME}/${copr_project_name}/repo/epel-\${ver}/${COPR_USERNAME}-${copr_project_name}-epel-\${ver}.repo
\`\`\`

\`\`\`
sudo yum install ${rpm_name}
\`\`\`"

spec_file=${rpm_name}.spec
mock_chroots="epel-7-${arch}"

usage() {
  cat <<'EOF' 1>&2
Usage: build.sh subcommand

subcommand:
  srpm          build the srpm
  mock          build the rpm locally with mock
  copr          upload the srpm and build the rpm on copr
EOF
}

topdir=`rpm --eval '%{_topdir}'`

download_source_files() {
  source_urls=`rpmspec -P ${topdir}/SPECS/${spec_file} | awk '/^Source[0-9]*:\s*(ht|f)tp/ {print $2}'`
  for source_url in $source_urls; do
    source_file=${source_url##*/}
    (cd ${topdir}/SOURCES && if [ ! -f ${source_file} ]; then curl -sLO ${source_url}; fi)
  done
}

build_srpm() {
  download_source_files
  rpmbuild -bs "${topdir}/SPECS/${spec_file}"
  version=`rpmspec -P ${topdir}/SPECS/${spec_file} | awk '$1=="Version:" { print $2 }'`
  release=`rpmspec -P ${topdir}/SPECS/${spec_file} | awk '$1=="Release:" { print $2 }'`
  rpm_version_release=${version}-${release}
  srpm_file=${rpm_name}-${rpm_version_release}.src.rpm
}

create_libmnl_and_libnftnl_repo_file() {
  base_chroot=$1

  libmnl_and_libnftnl_repo_file=libmnl_and_libnftnl.repo
  if [ ! -f $libmnl_and_libnftnl_repo_file ]; then
    # NOTE: Although https://copr.fedorainfracloud.org/coprs/hnakamur/libmnl/repo/epel-7/hnakamur-libmnl-epel-7.repo
    #       has the gpgkey in it, I don't use it since I don't know how to add it to /etc/mock/*.cfg
    cat > ${libmnl_and_libnftnl_repo_file} <<EOF
[hnakamur-libmnl]
name=Copr repo for libmnl owned by hnakamur
baseurl=https://copr-be.cloud.fedoraproject.org/results/hnakamur/libmnl/${base_chroot}/
type=rpm-md
enabled=1
gpgcheck=0

[hnakamur-libnftnl]
name=Copr repo for libnftnl owned by hnakamur
baseurl=https://copr-be.cloud.fedoraproject.org/results/hnakamur/libnftnl/${base_chroot}/
type=rpm-md
enabled=1
gpgcheck=0
EOF
  fi
}

create_mock_chroot_cfg() {
  base_chroot=$1
  mock_chroot=$2

  create_libmnl_and_libnftnl_repo_file $base_chroot

  # Insert ${scl_repo_file} before closing """ of config_opts['yum.conf']
  # See: http://unix.stackexchange.com/a/193513/135274
  #
  # NOTE: Support of adding repository was added to mock,
  #       so you can use it in the future.
  # See: https://github.com/rpm-software-management/ci-dnf-stack/issues/30
  (cd ${topdir} \
    && echo | sed -e '$d;N;P;/\n"""$/i\
' -e '/\n"""$/r '${libmnl_and_libnftnl_repo_file} -e '/\n"""$/a\
' -e D /etc/mock/${base_chroot}.cfg - | sudo sh -c "cat > /etc/mock/${mock_chroot}.cfg")
}

build_rpm_with_mock() {
  build_srpm
  for mock_chroot in $mock_chroots; do
    base_chroot=$mock_chroot
    mock_chroot=${base_chroot}-with-libmnl-and-libfntnl
    create_mock_chroot_cfg $base_chroot $mock_chroot
    /usr/bin/mock -r ${mock_chroot} --rebuild ${topdir}/SRPMS/${srpm_file}

    mock_result_dir=/var/lib/mock/${base_chroot}/result
    if [ -n "`find ${mock_result_dir} -maxdepth 1 -name \"${rpm_name}-*${version}-*.${arch}.rpm\" -print -quit`" ]; then
      mkdir -p ${topdir}/RPMS/${arch}
      cp ${mock_result_dir}/${rpm_name}-*${version}-*.${arch}.rpm ${topdir}/RPMS/${arch}/
    fi
    if [ -n "`find ${mock_result_dir} -maxdepth 1 -name \"${rpm_name}-*${version}-*.noarch.rpm\" -print -quit`" ]; then
      mkdir -p ${topdir}/RPMS/noarch
      cp ${mock_result_dir}/${rpm_name}-*${version}-*.noarch.rpm ${topdir}/RPMS/noarch/
    fi
  done
}

build_rpm_on_copr() {
  build_srpm

  # Check the project is already created on copr.
  status=`curl -s -o /dev/null -w "%{http_code}" https://copr.fedoraproject.org/api/coprs/${COPR_USERNAME}/${copr_project_name}/detail/`
  if [ $status = "404" ]; then
    # Create the project on copr.
    # We call copr APIs with curl to work around the InsecurePlatformWarning problem
    # since system python in CentOS 7 is old.
    # I read the source code of https://pypi.python.org/pypi/copr/1.62.1
    # since the API document at https://copr.fedoraproject.org/api/ is old.
    chroot_opts=''
    for mock_chroot in $mock_chroots; do
      chroot_opts="$chroot_opts --data-urlencode ${mock_chroot}=y"

      # Remove suffix '-x86_64' from epel-6-x86_64, or epel-7-x86_64
      chroot_without_arch=${mock_chroot%-*}
      chroot_opts="$chroot_opts --data-urlencode repos=https://copr-be.cloud.fedoraproject.org/results/hnakamur/libmnl/${chroot_without_arch}-\$basearch/"
      chroot_opts="$chroot_opts --data-urlencode repos=https://copr-be.cloud.fedoraproject.org/results/hnakamur/libnftnl/${chroot_without_arch}-\$basearch/"
    done
    curl -s -X POST -u "${COPR_LOGIN}:${COPR_TOKEN}" \
      --data-urlencode "name=${copr_project_name}" \
      $chroot_opts \
      --data-urlencode "description=${copr_project_description}" \
      --data-urlencode "instructions=${copr_project_instructions}" \
      https://copr.fedoraproject.org/api/coprs/${COPR_USERNAME}/new/
  fi
  # Add a new build on copr with uploading a srpm file.
  chroot_opts=''
  for mock_chroot in $mock_chroots; do
    chroot_opts="$chroot_opts -F ${mock_chroot}=y"
  done
  curl -s -X POST -u "${COPR_LOGIN}:${COPR_TOKEN}" \
    -H "Expect:" \
    $chroot_opts \
    -F "pkgs=@${topdir}/SRPMS/${srpm_file};type=application/x-rpm" \
    https://copr.fedoraproject.org/api/coprs/${COPR_USERNAME}/${copr_project_name}/new_build_upload/
}

case "${1:-}" in
srpm)
  build_srpm
  ;;
mock)
  build_rpm_with_mock
  ;;
copr)
  build_rpm_on_copr
  ;;
*)
  usage
  ;;
esac
