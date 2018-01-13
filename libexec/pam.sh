#!/bin/bash
function configure_core_dumps() {
  # slackware uses /etc/limits and is configured through limits.new file
  local file="${ROOTDIR:-/}etc/security/limits.conf"
  print_topic "configuring core dumps"
  check_for_conf_file "${file}" || return 1
  echo "[+] ${file} found"
  sed_with_diff 's/^#\?\*\( \+\)soft\( \+\)core\( \+\)0$/*\1hard\2core\30/' "${file}"
  return ${?}
  # TODO: nproc - max number of processes
} # configure_core_dumps()
################################################################################
function configure_pam_umask() {
  if [ -d /usr/share/pam-configs ]
  then
    echo '[+] creating umask pam-config'
    make -f "${CWD}/Makefile" /usr/share/pam-configs/umask
    echo '[+] updating /etc/pam.d/common-*'
    pam-auth-update --package
  fi
} # configure_pam_umask()
################################################################################
function configure_pam() {
  # https://github.com/pyllyukko/harden.sh/wiki/PAM
  local setting
  local file
  local regex
  local NAME

  configure_password_policies

  print_topic "configuring PAM"
  if [ ! -d ${ROOTDIR:-/}etc/pam.d ]
  then
    echo '[-] /etc/pam.d does not exist!' 1>&2
    return 1
  fi
  # NOTE: if libpam-passwdqc is installed, it is already configured by pam-auth-update

  # Debian based
  if [ -d /usr/share/pam-configs ]
  then
    for file in "tally2" "access" "faildelay" "polyinstation" "lastlog" "umask" "pwhistory"
    do
      echo "[+] creating ${file} pam-config"
      make -f "${CWD}/Makefile" "/usr/share/pam-configs/${file}"
    done

    echo '[+] updating /etc/pam.d/common-*'
    pam-auth-update --package
  # Red Hat / CentOS
  elif [ -x /sbin/authconfig ]
  then
    # faillock instead of tally2
    # defaults: deny=4 unlock_time=1200
    echo '[+] enabling faillock via authconfig'
    authconfig --enablefaillock --update
    # access.conf
    # authconfig --enablepamaccess --update
  fi

  # pam_namespace
  if sha512sum -c 0<<<"b782eec0d414dc460b85ffe86601d84d86f9439c4ac95bc965f6e7a245c01dc40ed648c15cfdaccd0402452b2b6397ffdf0e1524d5e431d9a0b6861f832b0c31  ${ROOTDIR:-/}etc/security/namespace.conf" &>/dev/null
  then
    # WARNING: this is not completely tested with CentOS!
    echo '[+] configuring /etc/security/namespace.conf'
    sed_with_diff '26,27s/^#//' "${ROOTDIR:-/}etc/security/namespace.conf"
  fi

  # access.conf
  # the checksum is the same both for Debian & CentOS
  if sha512sum -c 0<<<"a32865fc0d8700ebb63e01fa998c3c92dca7bda2f6a34c5cca0a8a59a5406eef439167add8a15424b82812674312fc225fd26331579d5625a6d1c4cf833a921f  ${ROOTDIR:-/}etc/security/access.conf" &>/dev/null
  then
    echo '[+] configuring /etc/security/access.conf'
    for regex in \
      '/^# All other users should be denied to get access from all sources./i+ : root : LOCAL\n+ : daemon : cron\n- : ALL : cron crond\n+ : Debian-gdm : LOCAL\n+ : (users) : ALL' \
      '/- : ALL : ALL$/s/^#\s*//'
    do
      sed_with_diff "${regex}" "${ROOTDIR:-/}etc/security/access.conf"
    done
    echo '[*] NOTE: be sure to add regular users to the "users" group!'
    for NAME in $( awk -F: -v uid_min=${UID_MIN:-1000} '$3>=uid_min{print$1}' /etc/passwd )
    do
      if ! id "${NAME}" | fgrep -q "(users)"
      then
	echo "[-] WARNING: user \`${NAME}' does not belong to group \"users\"!" 1>&2
      fi
    done
  fi

  # limit password reuse
  # red hat
  # NOTE: this should be done in different way, as these configs are wiped by authconfig
  if [ -f ${ROOTDIR:-/}etc/pam.d/password-auth -a -f ${ROOTDIR:-/}etc/pam.d/system-auth ] && \
    ! grep -q "^password.*pam_unix\.so.*remember" ${ROOTDIR:-/}etc/pam.d/password-auth && ! grep -q "^password.*pam_unix\.so.*remember" ${ROOTDIR:-/}etc/pam.d/system-auth
  then
    for file in "${ROOTDIR:-/}etc/pam.d/password-auth" "${ROOTDIR:-/}etc/pam.d/system-auth"
    do
      echo "[+] limiting password reuse in ${file}"
      sed_with_diff 's/^\(password.*pam_unix\.so.*\)$/\1 remember=5/' "${file}"
    done
  fi

  # disallow empty passwords
  # TODO: CentOS
  if [ -f ${ROOTDIR:-/}etc/pam.d/common-auth ] && grep -q 'nullok' ${ROOTDIR:-/}etc/pam.d/common-auth
  then
    echo '[+] removing nullok from /etc/pam.d/common-auth'
    sed_with_diff 's/\s\+nullok\(_secure\)\?//' "${ROOTDIR:-/}etc/pam.d/common-auth"
  fi

  # !su
  if [ -f ${ROOTDIR:-/}etc/pam.d/su ] && ! grep -q "^auth.*required.*pam_wheel\.so" ${ROOTDIR:-/}etc/pam.d/su
  then
    echo '[+] configuring pam_wheel.so'
    sed_with_diff '/auth\s\+required\s\+pam_wheel\.so\(\s\+use_uid\)\?$/s/^#\s*//' "${ROOTDIR:-/}etc/pam.d/su"
  fi

  # /etc/pam.d/other
  echo '[+] configuring default behaviour via /etc/pam.d/other'
  cat 0<<-EOF 1>${ROOTDIR:-/}etc/pam.d/other
	# deny all access by default and log to syslog
	auth      required   pam_deny.so
	auth      required   pam_warn.so
	account   required   pam_deny.so
	account   required   pam_warn.so
	password  required   pam_deny.so
	password  required   pam_warn.so
	session   required   pam_deny.so
	session   required   pam_warn.so
EOF

  #if [ -f ${ROOTDIR:-/}etc/passwdqc.conf ]
  #then
  #  # TODO
  #  true
  #fi
} # configure_pam()
