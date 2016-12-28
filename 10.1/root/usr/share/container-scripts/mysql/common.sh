#!/bin/bash

source ${CONTAINER_SCRIPTS_PATH}/helpers.sh

# Data directory where MySQL database files live. The data subdirectory is here
# because .bashrc and my.cnf both live in /var/lib/mysql/ and we don't want a
# volume to override it.
export MYSQL_DATADIR=/var/lib/mysql/data

# Configuration settings.
export MYSQL_DEFAULTS_FILE=${MYSQL_DEFAULTS_FILE:-/etc/my.cnf}
export MYSQL_BINLOG_FORMAT=${MYSQL_BINLOG_FORMAT:-STATEMENT}
export MYSQL_LOWER_CASE_TABLE_NAMES=${MYSQL_LOWER_CASE_TABLE_NAMES:-0}
export MYSQL_MAX_CONNECTIONS=${MYSQL_MAX_CONNECTIONS:-151}
export MYSQL_FT_MIN_WORD_LEN=${MYSQL_FT_MIN_WORD_LEN:-4}
export MYSQL_FT_MAX_WORD_LEN=${MYSQL_FT_MAX_WORD_LEN:-20}
export MYSQL_AIO=${MYSQL_AIO:-1}
export MYSQL_MAX_ALLOWED_PACKET=${MYSQL_MAX_ALLOWED_PACKET:-200M}
export MYSQL_TABLE_OPEN_CACHE=${MYSQL_TABLE_OPEN_CACHE:-400}
export MYSQL_SORT_BUFFER_SIZE=${MYSQL_SORT_BUFFER_SIZE:-256K}

if [ -n "${NO_MEMORY_LIMIT:-}" -o -z "${MEMORY_LIMIT_IN_BYTES:-}" ]; then
  key_buffer_size='32M'
  read_buffer_size='8M'
  innodb_buffer_pool_size='32M'
  innodb_log_file_size='8M'
  innodb_log_buffer_size='8M'
else
  key_buffer_size="$(python -c "print(int((${MEMORY_LIMIT_IN_BYTES}/(1024*1024))*0.1))")M"
  read_buffer_size="$(python -c "print(int((${MEMORY_LIMIT_IN_BYTES}/(1024*1024))*0.05))")M"
  innodb_buffer_pool_size="$(python -c "print(int((${MEMORY_LIMIT_IN_BYTES}/(1024*1024))*0.5))")M"
  innodb_log_file_size="$(python -c "print(int((${MEMORY_LIMIT_IN_BYTES}/(1024*1024))*0.15))")M"
  innodb_log_buffer_size="$(python -c "print(int((${MEMORY_LIMIT_IN_BYTES}/(1024*1024))*0.15))")M"
fi
export MYSQL_KEY_BUFFER_SIZE=${MYSQL_KEY_BUFFER_SIZE:-$key_buffer_size}
export MYSQL_READ_BUFFER_SIZE=${MYSQL_READ_BUFFER_SIZE:-$read_buffer_size}
export MYSQL_INNODB_BUFFER_POOL_SIZE=${MYSQL_INNODB_BUFFER_POOL_SIZE:-$innodb_buffer_pool_size}
export MYSQL_INNODB_LOG_FILE_SIZE=${MYSQL_INNODB_LOG_FILE_SIZE:-$innodb_log_file_size}
export MYSQL_INNODB_LOG_BUFFER_SIZE=${MYSQL_INNODB_LOG_BUFFER_SIZE:-$innodb_log_buffer_size}

# Be paranoid and stricter than we should be.
# https://dev.mysql.com/doc/refman/en/identifiers.html
mysql_identifier_regex='^[a-zA-Z0-9_]+$'
mysql_password_regex='^[a-zA-Z0-9_~!@#$%^&*()-=<>,.?;:|]+$'

# Variables that are used to connect to local mysql during initialization
mysql_flags="-u root --socket=/tmp/mysql.sock"
admin_flags="--defaults-file=$MYSQL_DEFAULTS_FILE $mysql_flags"

# Make sure env variables don't propagate to mysqld process.
function unset_env_vars() {
  log_info 'Cleaning up environment variables MYSQL_USER, MYSQL_PASSWORD, MYSQL_DATABASE and MYSQL_ROOT_PASSWORD ...'
  unset MYSQL_USER MYSQL_PASSWORD MYSQL_DATABASE MYSQL_ROOT_PASSWORD
}

# Poll until MySQL responds to our ping.
function wait_for_mysql() {
  pid=$1 ; shift

  while [ true ]; do
    if [ -d "/proc/$pid" ]; then
      mysqladmin --socket=/tmp/mysql.sock ping &>/dev/null && log_info "MySQL started successfully" && return 0
    else
      return 1
    fi
    log_info "Waiting for MySQL to start ..."
    sleep 1
  done
}

# Start local MySQL server with a defaults file
function start_local_mysql() {
  log_info 'Starting MySQL server with disabled networking ...'
  ${MYSQL_PREFIX}/libexec/mysqld \
    --defaults-file=$MYSQL_DEFAULTS_FILE \
    --skip-networking --socket=/tmp/mysql.sock "$@" &
  mysql_pid=$!
  wait_for_mysql $mysql_pid
}

# Shutdown mysql flushing privileges
function shutdown_local_mysql() {
  log_info 'Shutting down MySQL ...'
  mysqladmin $admin_flags flush-privileges shutdown
}

# Initialize the MySQL database (create user accounts and the initial database)
function initialize_database() {
  log_info 'Initializing database ...'
  log_info 'Running mysql_install_db ...'
  # Using --rpm since we need mysql_install_db behaves as in RPM
  mysql_install_db --rpm --datadir=$MYSQL_DATADIR --basedir=''
  start_local_mysql "$@"

  if [ -v MYSQL_RUNNING_AS_SLAVE ]; then
    log_info 'Initialization finished'
    return 0
  fi

  if [ -v MYSQL_RUNNING_AS_MASTER ]; then
    # Save master status into a separate database.
    STATUS_INFO=$(mysql $admin_flags -e 'SHOW MASTER STATUS\G')
    BINLOG_POSITION=$(echo "$STATUS_INFO" | grep 'Position:' | head -n 1 | sed -e 's/^\s*Position: //')
    BINLOG_FILE=$(echo "$STATUS_INFO" | grep 'File:' | head -n 1 | sed -e 's/^\s*File: //')
    GTID_INFO=$(mysql $admin_flags -e "SELECT BINLOG_GTID_POS('$BINLOG_FILE', '$BINLOG_POSITION') AS gtid_value \G")
    GTID_VALUE=$(echo "$GTID_INFO" | grep 'gtid_value:' | head -n 1 | sed -e 's/^\s*gtid_value: //')

    mysqladmin $admin_flags create replication
    mysql $admin_flags <<EOSQL
    use replication
    CREATE TABLE replication (gtid VARCHAR(256));
    INSERT INTO replication (gtid) VALUES ('$GTID_VALUE');
EOSQL
  fi

  # Do not care what option is compulsory here, just create what is specified
  if [ -v MYSQL_USER ]; then
    log_info "Creating user specified by MYSQL_USER (${MYSQL_USER}) ..."
mysql $mysql_flags <<EOSQL
    CREATE USER '${MYSQL_USER}'@'%' IDENTIFIED BY '${MYSQL_PASSWORD}';
EOSQL
  fi

  if [ -v MYSQL_DATABASE ]; then
    log_info "Creating database ${MYSQL_DATABASE} ..."
    mysqladmin $admin_flags create "${MYSQL_DATABASE}"
    if [ -v MYSQL_USER ]; then
      log_info "Granting privileges to user ${MYSQL_USER} for ${MYSQL_DATABASE} ..."
mysql $mysql_flags <<EOSQL
      GRANT ALL ON \`${MYSQL_DATABASE}\`.* TO '${MYSQL_USER}'@'%' ;
      FLUSH PRIVILEGES ;
EOSQL
    fi
  fi

  if [ -v MYSQL_ROOT_PASSWORD ]; then
    log_info "Setting password for MySQL root user ..."
mysql $mysql_flags <<EOSQL
    CREATE USER IF NOT EXISTS 'root'@'%';
    GRANT ALL PRIVILEGES ON *.* TO 'root'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}' WITH GRANT OPTION;
EOSQL
  fi
  log_info 'Initialization finished'
}

# The 'server_id' number for slave needs to be within 1-4294967295 range.
# This function will take the 'hostname' if the container, hash it and turn it
# into the number.
# See: https://dev.mysql.com/doc/refman/en/replication-options.html#option_mysqld_server-id
function server_id() {
  checksum=$(sha256sum <<< $(hostname -i))
  checksum=${checksum:0:14}
  echo -n $((0x${checksum}%4294967295))
}

function wait_for_mysql_master() {
  while true; do
    log_info "Waiting for MySQL master (${MYSQL_MASTER_SERVICE_NAME}) to accept connections ..."
    mysqladmin --host=${MYSQL_MASTER_SERVICE_NAME} --user="${MYSQL_MASTER_USER}" \
      --password="${MYSQL_MASTER_PASSWORD}" ping &>/dev/null && log_info "MySQL master is ready" && return 0
    sleep 1
  done
}

# checks whether the server given as argument is running mysqld
# accepts options in format addr[:port], port is optional
function remote_mysql_server_on() {
  local host=$(echo "${1}" | cut -d':' -f1)
  local port=$(echo "${1}:" | cut -d':' -f2)
  port=${port:-3306}
  SECONDS=0
  while /bin/true; do
    RESPONSE=`mysqladmin --no-defaults --user=UNKNOWN_MYSQL_USER -h $host -P $port ping 2>&1`
    mret=$?
    if [ $mret -eq 0 ] ; then
      return 0
    fi
    # exit codes 1, 11 (EXIT_CANNOT_CONNECT_TO_SERVICE) are expected,
    # anything else suggests a configuration error
    if [ $mret -ne 1 -a $mret -ne 11 ]; then
      echo "Cannot check for MariaDB Daemon startup because of mysqladmin failure." >&2
        return $mret
    fi
    # "Access denied" also means the server is alive
    if echo "$RESPONSE" | grep -q "Access denied for user" ; then
      return 0
    fi
    if [ $SECONDS -gt 5 ] ; then
      return 1
    fi
    sleep 1
  done
}

# checks whether any of the nodes from MYSQL_CLUSTER_NODES are already on and running mysqld
function any_cluster_node_on() {
  MYSQL_NODE_PING_TIMEOUT=5
  for node in `echo "${MYSQL_CLUSTER_NODES:-}" | sed -e 's/,/ /g'` ; do
    if ping -q -W ${MYSQL_NODE_PING_TIMEOUT} -c 1 "${node}" &>/dev/null ; then
      remote_mysql_server_on "${node}" || break
      log_info "Existing node found: ${node}"
      return 0
    fi
  done
  return 1
}

# returns IP of current container
function get_current_ip() {
  ip route | awk '/default/ { print $3 }'
}

# returns value for wsrep_cluster_address option
# adds IP of the current container if missing and prefixes with gcomm://
function get_cluster_nodes_list_opt() {
  res='gcomm://'
  current_ip=$(get_current_ip)
  current_ip_included=false
  for node in `echo "${MYSQL_CLUSTER_NODES:-}" | sed -e 's/,/ /g'` ; do
    if [ "$current_ip" == "$node" ] ; then
      current_ip_included=true
    fi
    res="${res}${node},"
  done
  if [ "$current_ip_included" == true ] ; then
    res="${res%,}"
  else
    res="${res}${current_ip}"
  fi
  echo "${res}"
}

# removes --wsrep-new-cluster option from list of options for mysqld
function filter_cluster_init_opt() {
  res=""
  while [ $# -gt 0 ] ; do
    if [ "${1}" != '--wsrep-new-cluster' ] ; then
      res="${res} \"${1}\""
    fi
    shift
  done
  echo "${res}"
}

